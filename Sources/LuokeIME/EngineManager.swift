import AVFoundation
import AppKit
import LuokeShell
import os

/// 壳里唯一的引擎管理者（主线程）：读设置、扫描引擎目录、启动和切换引擎、监视文件改动、
/// 认领沙盒拦截，并把引擎的消息和状态变化转给各个输入框的会话。
final class EngineManager {
    static let shared = EngineManager()

    typealias Entry = EngineCatalog.Entry

    /// 自带的引擎：LuokeIME.app/Contents/Resources/engines（docs/发布打包.md）。
    static var bundledEngines: URL? { Bundle.main.resourceURL?.appendingPathComponent("engines") }

    let paths = Paths()
    /// 本机的使用计数：所有输入框共用一份，设置窗口「高级」里显示。
    private(set) lazy var usage = Usage(url: paths.usage)
    let log = Logger(subsystem: "ai.luoke.inputmethod", category: "engine")
    private(set) var config = ShellConfig()
    private(set) var entries: [Entry] = []
    private(set) var typing: EngineConnection?
    private(set) var hotkeys: [EngineConnection] = []
    /// 个人化组件（同一时间一个）：收所有上屏、回答转问（docs/引擎协议.md#个人化组件）。
    private(set) var personal: EngineConnection?
    /// 转问的中转：在后台线程上走，不经过主线程。
    let broker = AskBroker()
    /// 每个应用最后一次的中英状态（这个进程里的）。"记住上次模式"开着时另外存进设置（ShellConfig.appModes），重启后也记得。
    private var englishByApp: [String: Bool] = [:]
    /// 上一个进入的应用：没开"记住上次模式"时，同一个应用里换输入框不重置中英文。
    private var lastApp: String?
    /// 第 1 版的设置换成第 2 版时没能另存原文件：不写回设置（原文件不动），菜单里标出来。
    private(set) var migrationError: String?
    /// 引擎被沙盒拦下的操作（每种只记一次），菜单里显示。
    private(set) var denials: [String: [SandboxDenial]] = [:]
    private let controllers = NSHashTable<LuokeInputController>.weakObjects()
    private let monitor = SandboxMonitor()
    private var watcher: FolderWatcher?
    private var personalWatcher: FolderWatcher?
    private var engineList: [String] = []
    private var configDate: Date?
    /// 各引擎数据目录里 options.json 的修改时间：值变了就重启引擎（设计文档「引擎选项」）。
    private var typingOptionsDate: Date?
    private var hotkeyOptionsDates: [Date?] = []
    private var personalOptionsDate: Date?
    /// 等用户确认的第三方引擎（包括和自带的同名、还没确认、所以先用着自带那份的），菜单里列出来（luokelabs/luoke-ime#6）。
    private(set) var pending: [Entry] = []
    /// 自带引擎的标识（同名的第三方引擎换个数据目录）。
    private var bundledIDs: Set<String> = []
    /// 正在用的个人化组件在记忆同意里的键（consentKey）。
    private var personalKey: String?
    /// 个人化组件报来的记忆状态（ping 的 memory：ok、too_new、broken……），菜单里标出打不开的情况。
    private(set) var memoryStatus: String?
    private var memoryCheckedAt = Date.distantPast
    private var timer: Timer?
    private var sweepTimer: Timer?
    /// 第三方引擎第一次要起时才解析（会跑一遍用户的登录 shell，最多 3 秒）；自带的引擎用固定的 PATH，不跑（luokelabs/luoke-ime#12）。
    private lazy var loginPath = Self.resolveLoginPath()

    // MARK: - 启动

    /// 请求头里的配件标识：luoke-ime/<版本>（luoke-core V1 §2）。
    static var accessory: String {
        "luoke-ime/" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
    }

    func start() {
        paths.prepare()
        try? FileManager.default.createDirectory(at: paths.engines, withIntermediateDirectories: true)
        config = ShellConfig.load(paths.settings)
        migrateIfNeeded()
        configDate = modificationDate(paths.settings)
        broker.hub = HubClient(accessory: Self.accessory, socketPath: config.hubSocket)
        scan()
        startTyping()
        startHotkeys()
        startPersonal()
        monitor.onDenial = { [weak self] d in DispatchQueue.main.async { self?.denied(d) } }
        // 订阅要等 log 打出第一行，不放在主线程上等（luokelabs/luoke-ime#12）
        let monitor = monitor, log = log
        DispatchQueue.global(qos: .utility).async {
            if !monitor.start(timeout: 1) { log.error("读不了系统日志，看不到沙盒拦截") }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        // 开发模式的记录只留 7 天：启动时和每小时清一次（关了开发模式、删掉的引擎留下的也清）
        let records = paths.recordsRoot
        DispatchQueue.global(qos: .utility).async { Recorder.sweepAll(records) }
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async { Recorder.sweepAll(records) }
        }
    }

    /// 进程要退出了（收到 SIGTERM 等、或应用正常结束）：结束系统日志的订阅，告诉主控我们正常退出，
    /// 主控据此停掉只给输入法用的打分进程（luoke-core V1 §2 `POST /accessory/exiting`，luokelabs/luoke-ime#9）。
    /// 引擎子进程读到标准输入到头自己退出，不用在这里等。被强制结束时走不到这里，主控那边另有空闲停（luoke-core#11）。
    func shutdown() {
        usage.flush()
        monitor.stop()
        _ = broker.hub?.request("POST", "/accessory/exiting", body: .object([:]), timeout: 1)
    }

    /// 扫描引擎：包里自带的，加上引擎目录里装的（EngineCatalog，命令行的 mcp 用同一份规则）。
    private func scan() {
        let c = EngineCatalog.scan(bundled: Self.bundledEngines, user: paths.engines, approved: config.approvedEngines)
        entries = c.entries
        pending = c.pending
        bundledIDs = c.bundledIDs
        engineList = ((try? FileManager.default.contentsOfDirectory(atPath: paths.engines.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    var typingEntries: [Entry] { entries.filter { $0.manifest?.kind == .typing } }

    /// 个人化组件：用户确认过的第三方个人化组件，否则自带的。
    private var personalEntry: Entry? { catalog.personal(approved: config.approvedEngines) }

    /// 当前引擎：设置里指定的（能用的话），否则第一个自带的打字引擎。第三方引擎不会被自动选中。
    private var currentEntry: Entry? { catalog.current(config) }

    private var catalog: EngineCatalog { EngineCatalog(entries: entries) }

    // MARK: - 第三方引擎（luokelabs/luoke-ime#6）

    /// 第三方引擎不能有的声明（联网、GPU、额外的写入位置）；自带的为 nil。
    func refusal(_ e: Entry) -> String? { EngineCatalog.refusal(e) }

    /// 用户确认过（自带的不用确认）：确认时记下的指纹和现在的一样。
    func approved(_ e: Entry) -> Bool { EngineCatalog.isApproved(e, approved: config.approvedEngines) }

    /// 能启动：引擎说明读得懂、没有第三方不能有的声明、确认过。
    func usable(_ e: Entry) -> Bool { EngineCatalog.usable(e, approved: config.approvedEngines) }

    /// 数据目录等用的名字：和自带引擎同名的第三方引擎用"<标识>.third-party"，读写不到自带那份的数据。
    func storage(_ e: Entry) -> String { !e.bundled && bundledIDs.contains(e.id) ? e.id + ".third-party" : e.id }

    /// 记忆同意的键：自带的是标识；第三方的带上指纹，同名的不继承自带的同意，确认的内容变了也要重新同意。
    func consentKey(_ e: Entry) -> String { EngineCatalog.consentKey(e) }

    /// 用户在确认框里同意启用：记下指纹，重新扫描、重启引擎；打字引擎顺带换成它。
    func approve(_ e: Entry) {
        guard let fp = e.fingerprint, e.manifest != nil, refusal(e) == nil else { return }
        config.approvedEngines[e.id] = fp
        if e.manifest?.kind == .typing { config.currentEngine = e.id }
        save()
        scan()
        startTyping()
        startHotkeys()
        startPersonal()
        onConfigChange?()
    }

    private func makeConnection(_ e: Entry) -> EngineConnection? {
        guard var m = e.manifest else { return nil }
        if Self.isVoice(m), let k = config.voiceKey { m.hotkey?.key = k } // 设置里换了说话的键
        let c = EngineConnection(id: e.id, dir: e.dir, manifest: m, paths: paths)
        c.searchPath = e.bundled ? Self.fixedPath : loginPath
        c.memoryGranted = config.memoryEnabled(key: consentKey(e), bundled: e.bundled)
        c.thirdParty = !e.bundled
        c.storageID = storage(e)
        if m.kind == .typing { c.shellOptions["fuzzy"] = .array(config.fuzzyActive.map { .string($0) }) }
        if Self.isVoice(m) { c.shellOptions["tidy"] = .bool(config.voiceTidyActive) }
        broker.attach(c)
        if config.devMode.contains(e.id) { c.recorder = try? Recorder(directory: paths.records(storage(e))) }
        c.onMessage = { [weak self] in DispatchQueue.main.async { self?.pumpAll() } }
        c.onEvent = { [weak self, weak c] event in
            DispatchQueue.main.async {
                guard let self, let c else { return }
                self.handle(event, from: c)
            }
        }
        return c
    }

    /// 旧引擎在后台线程里停：等它退出最多 1.5 秒，不能卡住主线程（所有应用里的打字都在主线程上）。
    private func stopInBackground(_ c: EngineConnection?) {
        guard let c else { return }
        DispatchQueue.global(qos: .utility).async { c.stopAndWait(timeout: 1) }
    }

    private func startTyping() {
        stopInBackground(typing)
        typing = nil
        watcher = nil
        if let e = currentEntry, let c = makeConnection(e) {
            typing = c
            watcher = e.bundled ? nil : FolderWatcher(dir: e.dir)
            typingOptionsDate = optionsDate(e.id)
            do { try c.start() } catch { log.error("启动 \(e.id, privacy: .public) 失败：\(String(describing: error), privacy: .public)") }
        }
        rebind()
    }

    /// 声明了麦克风的快捷键引擎（自带的语音）：设置里的「语音输入」管它开不开、整理不整理。
    static func isVoice(_ m: Manifest) -> Bool { EngineCatalog.isVoice(m) }

    private func startHotkeys() {
        hotkeys.forEach(stopInBackground)
        hotkeys = entries.filter { e in
            guard let m = e.manifest, m.kind == .hotkey, usable(e) else { return false }
            return config.voiceOn || !Self.isVoice(m) // 语音默认关：关着时不起、不要麦克风
        }.compactMap { e in
            let c = makeConnection(e)
            c?.startsLazily = true // 停了的，下一次按键时再起
            if e.manifest?.hotkey?.arm == true { // 按下就要录的引擎先起好，崩溃了也马上重启，不然第一下要等它启动、开头的话丢了
                c?.restartsAfterCrash = true
                do { try c?.start() } catch { log.error("启动 \(e.id, privacy: .public) 失败：\(String(describing: error), privacy: .public)") }
            }
            return c
        }
        hotkeyOptionsDates = hotkeys.map { optionsDate($0.id) }
        rebind()
        requestMicrophoneIfNeeded()
    }

    /// 启用了声明麦克风的快捷键引擎、系统还没问过时，向系统申请（ADR 0005）：弹窗显示的是壳的名字，
    /// 授权记在壳头上。用户拒了不再问，引擎录音时自己会拿不到声音。
    private func requestMicrophoneIfNeeded() {
        guard hotkeys.contains(where: { Self.isVoice($0.manifest) }),
              AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [log] ok in log.info("麦克风授权：\(ok ? "允许" : "拒绝", privacy: .public)") }
    }

    /// 起个人化组件时主控的 Python 是哪一个（只对 run 写 luoke-python 的组件有意义）。
    private var personalPython: Int?
    private var pythonCheckedAt = Date.distantPast

    private func startPersonal() {
        personalPython = EngineConnection.hubPythonIdentity()
        stopInBackground(personal)
        personal = nil
        personalWatcher = nil
        personalKey = nil
        if let e = personalEntry, let c = makeConnection(e) {
            personal = c
            personalKey = consentKey(e)
            personalWatcher = e.bundled ? nil : FolderWatcher(dir: e.dir)
            personalOptionsDate = optionsDate(e.id)
            do { try c.start() } catch { log.error("启动 \(e.id, privacy: .public) 失败：\(String(describing: error), privacy: .public)") }
        }
        broker.personal = personal
        rebind()
    }

    /// options.json 的修改时间（不跟随符号链接：数据目录归引擎管）。
    private func optionsDate(_ id: String) -> Date? {
        let e = entries.first { $0.id == id }
        return modificationDate(paths.data(e.map(storage) ?? id).appendingPathComponent("options.json"))
    }

    /// 让所有输入框改用当前的引擎。
    private func rebind() {
        for c in controllers.allObjects { bind(c) }
    }

    /// 引擎没换时继续用原来的通道：换新通道会丢掉还没到的答复，被状态机误判为卡死。
    private func bind(_ controller: LuokeInputController) {
        guard let s = controller.session else { return }
        var settings = config.settings
        settings.predict = true // 联想开不开按应用算（全局默认加应用覆盖），交给输入控制器的 mayPredict
        s.settings = settings
        s.usage = usage
        if !(typing?.owns(s.typing?.channel) ?? (s.typing == nil)) {
            s.typing = typing.map { TypingEngine(manifest: $0.manifest, channel: $0.makeChannel(), id: $0.id) }
        }
        if s.hotkeys.count != hotkeys.count || zip(s.hotkeys, hotkeys).contains(where: { !$0.1.owns($0.0.channel) }) {
            s.hotkeys = hotkeys.map { HotkeyEngine(manifest: $0.manifest, channel: $0.makeChannel(), id: $0.id) }
        }
        if !(personal?.owns(s.personal?.channel) ?? (s.personal == nil)) {
            s.personal = personal.map { PersonalEngine(manifest: $0.manifest, channel: $0.makeChannel(), id: $0.id) }
        }
        // 联想：经转问的中转去问个人化组件，答复在后台线程上到，切回主线程交给这个输入框的状态机
        s.predictor = { [weak self, weak controller] id, context, app in
            guard let self else { return } // 能不能问由会话照 PersonalPolicy 定好了
            var params: [String: JSONValue] = ["context": .string(context)]
            if let app { params["app"] = .string(app) }
            self.broker.askFromShell(method: "predict", params: .object(params)) { reply in
                let items = Self.predictions(reply)
                DispatchQueue.main.async {
                    controller?.session.receivePredictions(id: id, items: items)
                    controller?.reschedule()
                }
            }
        }
    }

    /// 联想的答复：{"candidates": ["…", …]}；错误或看不懂的当作没有。
    static func predictions(_ r: Reply) -> [String] {
        guard case let .object(o)? = r.result, case let .array(a)? = o["candidates"] else { return [] }
        return a.compactMap { if case let .string(s) = $0 { return s } else { return nil } }
    }

    func register(_ controller: LuokeInputController) {
        controllers.add(controller)
        bind(controller)
    }

    /// 所有输入框都空闲（Session.isIdle）：这会儿退出不丢正在打的字。
    var allIdle: Bool { controllers.allObjects.allSatisfy { $0.session.isIdle } }

    private func pumpAll() {
        for c in controllers.allObjects { c.pump() }
    }

    // MARK: - 引擎事件

    private func handle(_ event: EngineConnection.Event, from c: EngineConnection) {
        let name = c.manifest.name
        switch event {
        case .started:
            guard c === typing else { return }
            for ctl in controllers.allObjects { ctl.session.engineDidStart(); ctl.reschedule() }
        case let .exited(status, _):
            log.notice("\(c.id, privacy: .public) 退出了（状态 \(status)）")
        case let .disabled(reason):
            // 停用的原因带着引擎标准错误的最后几行，可能有用户打的字：系统日志里只公开第一行（崩溃了几次），其余不公开
            let headline = reason.components(separatedBy: "\n").first ?? reason
            log.error("\(c.id, privacy: .public) 已停用：\(headline, privacy: .public)\(reason.dropFirst(headline.count), privacy: .private)")
            for ctl in controllers.allObjects { ctl.session.setNotice("「\(name)」已停用，原因见输入法菜单") }
        case let .protocolError(msg):
            log.error("\(c.id, privacy: .public) 协议错误：\(msg, privacy: .private)") // 里面有那一行的开头，可能有用户打的字
        case let .stderr(line):
            // 引擎的错误输出可能含用户打的字：不写进系统日志；开发模式下它在输入记录里
            _ = line
        }
    }

    private func denied(_ d: SandboxDenial) {
        guard d.severity == .hard,
              let c = ([typing, personal].compactMap { $0 } + hotkeys).first(where: { $0.sandboxTag == d.engine }) else { return }
        var list = denials[c.id] ?? []
        guard !list.contains(where: { $0.category == d.category && $0.operation == d.operation && $0.detail == d.detail }) else { return }
        list.append(d)
        denials[c.id] = Array(list.suffix(20))
        log.notice("\(c.id, privacy: .public) 被沙盒拦下：\(d.suggestion, privacy: .public)")
        for ctl in controllers.allObjects { ctl.session.setNotice("「\(c.manifest.name)」被沙盒拦下一项操作，见输入法菜单") }
    }

    // MARK: - 监视改动

    /// 设置文件在外面改过（螺壳主窗口经 `luoke-ime mcp` 改的、agent 或用户直接改的）就读进来、照着重启引擎。
    /// 每秒查一次；自己存盘前也先查，免得用手里旧的那份盖掉外面刚改的。读不懂（可能正写到一半）时返回 false，下一秒再读。
    @discardableResult
    private func reloadSettingsIfChanged() -> Bool {
        let date = modificationDate(paths.settings)
        guard date != configDate else { return true }
        configDate = date
        let old = config
        guard let loaded = ShellConfig.loadIfValid(paths.settings) else {
            log.error("设置文件读不懂（可能正写到一半），先用原来的设置")
            configDate = nil // 下一秒再读一次
            return false
        }
        config = loaded
        migrateIfNeeded()
        if config.hubSocket != old.hubSocket { broker.hub = HubClient(accessory: Self.accessory, socketPath: config.hubSocket) }
        if config.currentEngine != old.currentEngine || config.devMode != old.devMode || config.fuzzyActive != old.fuzzyActive { startTyping() } else { rebind() }
        if config.approvedEngines != old.approvedEngines { // 外面改了确认过的引擎：重新扫描
            scan()
            startTyping()
            startHotkeys()
            startPersonal()
        } else if config.memoryConsent != old.memoryConsent || config.memoryOff != old.memoryOff { // 开关变了：沙盒跟着变，记忆状态重新问
            memoryStatus = nil
            memoryCheckedAt = .distantPast
            startPersonal()
        }
        if config.approvedEngines == old.approvedEngines, voiceChanged(old) { startHotkeys() }
        onConfigChange?()
        return true
    }

    private func poll() {
        for r in ShellRequests.take(paths) { ShellRequests.answer(paths, r.id, handle(r)) }
        guard reloadSettingsIfChanged() else { return }
        // 引擎目录里增删了引擎
        let now = ((try? FileManager.default.contentsOfDirectory(atPath: paths.engines.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        if now != engineList {
            let oldCurrent = currentEntry?.id, oldPersonal = personalEntry?.id, oldPending = Set(pending.map(\.id))
            scan()
            // 新装了第三方引擎：在候选窗里提示一次去菜单里确认（不自动启用）
            if let fresh = pending.first(where: { !oldPending.contains($0.id) }) {
                for ctl in controllers.allObjects { ctl.session.setNotice("发现第三方引擎「\(fresh.manifest?.name ?? fresh.id)」：在输入法菜单里确认后才能用") }
            }
            if currentEntry?.id != oldCurrent || typing == nil { startTyping() }
            startHotkeys()
            if personalEntry?.id != oldPersonal { startPersonal() }
        }
        // 当前引擎的文件改了：重读引擎说明并重启，下一个键就用新版本
        if let w = watcher, w.changed(), let id = typing?.id {
            log.notice("\(id, privacy: .public) 的文件改了，重启")
            scan()
            startTyping()
        }
        // 引擎选项改了：重启引擎，新的值经 hello 交给它
        if let id = typing?.id, optionsDate(id) != typingOptionsDate {
            log.notice("\(id, privacy: .public) 的选项改了，重启")
            startTyping()
        }
        if hotkeys.map({ optionsDate($0.id) }) != hotkeyOptionsDates { startHotkeys() }
        checkMemory()
        // 主控换了版本（整个 .app 换掉了）：跑在旧主控 Python 上的个人化组件重启，用上新的（开发机上遇到过）
        if Date().timeIntervalSince(pythonCheckedAt) > 10, personal?.manifest.run.first == EngineConnection.luokePython {
            pythonCheckedAt = Date()
            if let now = EngineConnection.hubPythonIdentity(), now != personalPython {
                log.notice("主控的 Python 换了，重启个人化组件")
                startPersonal()
            }
        }
        if let w = personalWatcher, w.changed() {
            log.notice("个人化组件的文件改了，重启")
            scan()
            startPersonal()
        } else if let id = personal?.id, optionsDate(id) != personalOptionsDate {
            startPersonal()
        }
    }

    // MARK: - 菜单用到的操作

    func select(engine id: String) {
        guard let e = typingEntries.first(where: { $0.id == id }), usable(e) else { return }
        update { $0.currentEngine = id }
    }

    /// 进入这个应用的输入框时该不该是英文（规则在 ShellConfig.englishOnEnter）。
    func enter(app: String?) -> Bool {
        let english = config.englishOnEnter(app: app, lastApp: lastApp, inMemory: app.flatMap { englishByApp[$0] })
        lastApp = app
        if let app { englishByApp[app] = english }
        return english
    }

    /// 用户切了中英文（单按 Shift、菜单）：记在这个进程里；"记住上次模式"开着时也存进设置。
    func remember(english: Bool, for app: String?) {
        guard let app else { return }
        englishByApp[app] = english
        reloadSettingsIfChanged()
        let before = config.appModes
        config.noteMode(english: english, for: app)
        if config.appModes != before { save() }
    }

    /// 设置变了（菜单、设置窗口改的，或者外面改了文件）：设置窗口据此刷新。
    var onConfigChange: (() -> Void)?

    /// 改设置（菜单、设置窗口都走这里）：存盘，按变了什么重启引擎或重新绑定会话。
    func update(_ change: (inout ShellConfig) -> Void) {
        reloadSettingsIfChanged()
        let old = config
        change(&config)
        guard config != old else { return }
        defer { onConfigChange?() }
        save()
        // 改了某个应用（或全局）的默认中英文：记着的被清掉了，这个进程里的也跟着清，下次进去用新的默认值
        for app in englishByApp.keys where config.appModes[app] == nil && old.appModes[app] != nil
            || config.defaultEnglish(for: app) != old.defaultEnglish(for: app) {
            englishByApp[app] = nil
        }
        if config.currentEngine != old.currentEngine || config.devMode != old.devMode || config.fuzzyActive != old.fuzzyActive { startTyping() } else { rebind() }
        if config.memoryConsent != old.memoryConsent || config.memoryOff != old.memoryOff { startPersonal() }
        if voiceChanged(old) { startHotkeys() }
    }

    /// 语音开关、整理或说话的键变了：快捷键引擎重启（整理经 hello 的选项交给引擎）。
    private func voiceChanged(_ old: ShellConfig) -> Bool { config.voiceOn != old.voiceOn || config.voiceTidyActive != old.voiceTidyActive || config.voiceKey != old.voiceKey }

    /// 第 1 版的设置：先把原文件另存为 settings.v1.json（已经有了就不覆盖），存成了再写回第 2 版；另存不成就不写，原文件不动。
    private func migrateIfNeeded() {
        guard config.migratedFromV1 else { return }
        config.migratedFromV1 = false
        let backup = paths.settings.deletingLastPathComponent().appendingPathComponent("settings.v1.json")
        do {
            if !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: paths.settings, to: backup)
            }
            migrationError = nil
            save()
            log.notice("设置从第 1 版换成了第 2 版，原文件另存为 settings.v1.json")
        } catch {
            migrationError = String(describing: error)
            log.error("设置从第 1 版换成第 2 版时另存原文件失败，不写回：\(String(describing: error), privacy: .public)")
        }
    }

    func toggleDevMode(_ id: String) {
        update { if $0.devMode.contains(id) { $0.devMode.remove(id) } else { $0.devMode.insert(id) } }
    }

    /// 清掉引擎学到的东西（菜单里确认过以后）：只发给在运行、声明了 forget_all 的引擎，怎么清由引擎定。
    @discardableResult
    func forgetAll(_ c: EngineConnection) -> Bool {
        guard c.manifest.forgetAll, c.state == .running else { return false }
        c.send(.forgetAll)
        log.info("清掉「\(c.id, privacy: .public)」学到的东西")
        return true
    }

    /// 打字引擎忘掉过的词（它写在数据目录的 forgotten.json 里，引擎协议「forget_all」）：(按键, 词)，和只存了哈希、列不出来的个数。
    struct ForgottenWord: Hashable { var input: String; var text: String }
    struct ForgottenList: Equatable { var items: [ForgottenWord] = []; var older = 0 }

    func forgottenWords() -> ForgottenList {
        guard let t = typing, t.manifest.forgetAll else { return ForgottenList() }
        let url = paths.data(t.storage).appendingPathComponent("forgotten.json")
        guard let d = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return ForgottenList() }
        let items = (o["forgotten"] as? [[String: Any]] ?? []).compactMap { e -> ForgottenWord? in
            guard let i = e["input"] as? String, let t = e["text"] as? String else { return nil }
            return ForgottenWord(input: i, text: t)
        }
        return ForgottenList(items: items, older: o["older"] as? Int ?? 0)
    }

    /// 主窗口设置页经 `luoke-ime mcp` 交来的请求（ShellRequests）：页上已经确认过、带了用户操作，这里照做，
    /// 答复只有代号和数字。打字引擎换了的话，清的是现在这个（答复里带上它的标识）。
    private func handle(_ r: ShellRequests.Request) -> [String: Any] {
        var out: [String: Any] = ["op": r.op]
        func fail(_ code: String) -> [String: Any] { out["ok"] = false; out["code"] = code; return out }
        switch r.op {
        case "clear_learned":
            guard let t = typing, r.args["engine"] == nil || r.args["engine"] == t.id else { return fail("engine_changed") }
            guard forgetAll(t) else { return fail("engine_not_running") }
            out["engine"] = t.id
        case "restore":
            guard let input = r.args["input"], let text = r.args["text"] else { return fail("invalid") }
            guard forgottenWords().items.contains(ForgottenWord(input: input, text: text)) else { return fail("not_found") }
            guard unforget(input: input, text: text) else { return fail("engine_not_running") }
        case "reset_usage":
            usage.reset()
        default:
            return fail("unknown_op")
        }
        out["ok"] = true
        return out
    }

    /// 撤销忘掉一个词：告诉打字引擎（它在运行、声明了 forget_all 时）。
    @discardableResult
    func unforget(input: String, text: String) -> Bool {
        guard let t = typing, t.manifest.forgetAll, t.state == .running else { return false }
        t.send(.unforget(input: input, text: text))
        return true
    }

    func reenable(_ c: EngineConnection?) {
        guard let c else { return }
        denials[c.id] = nil
        do { try c.enable() } catch { log.error("重新启用失败：\(String(describing: error), privacy: .public)") }
    }

    /// 每 15 秒问一次个人化组件记忆打不打得开（只在用户同意了读写记忆时）。
    private func checkMemory() {
        guard memoryConsented, personal?.state == .running, Date().timeIntervalSince(memoryCheckedAt) > 15 else { return }
        memoryCheckedAt = Date()
        broker.askFromShell(method: "ping", params: .object([:])) { [weak self] reply in
            var status: String?
            if case let .object(o)? = reply.result, case let .string(s)? = o["memory"] { status = s }
            DispatchQueue.main.async { self?.memoryStatus = status }
        }
    }

    /// 打开或关掉记忆记录（"记录输入内容到记忆"）：沙盒在启动时定，所以重启个人化组件。
    func setMemoryConsent(_ on: Bool) {
        guard let key = personalKey else { return }
        let bundled = !personalIsThirdParty
        memoryStatus = nil
        memoryCheckedAt = .distantPast
        update { $0.setMemory(key: key, bundled: bundled, on: on) }
    }

    /// 记忆记录开着：自带的默认开、用户关了才算关；第三方的要用户同意过（顶层 ADR 0013）。
    var memoryConsented: Bool { personalKey.map { config.memoryEnabled(key: $0, bundled: !personalIsThirdParty) } ?? false }

    /// 第一次用时提示一句：自带的组件默认在记，说一声、告诉用户在哪关；第三方的要用户去开。
    /// 用户带着提示打完一段（memoryPromptSeen）才算提示过，之前每次进输入框都再给。
    func memoryPrompt() -> String? {
        guard let p = personal, let key = personalKey, p.manifest.permissions.memory, !config.memoryAsked.contains(key) else { return nil }
        if personalIsThirdParty {
            return "第三方的个人化组件「\(p.manifest.name)」要用记忆：在输入法设置的「通用」里打开记忆记录才给它"
        }
        return memoryConsented ? "螺壳会从你打的字里学，记在本机的螺壳记忆里；不想要的话在输入法设置的「通用」里关" : nil
    }

    /// 用户带着第一次用时的提示打完了一段：记成提示过，以后不再给。
    func memoryPromptSeen() {
        guard let key = personalKey, !config.memoryAsked.contains(key) else { return }
        config.memoryAsked.insert(key)
        save()
    }


    func clearDenials(_ id: String) {
        denials[id] = nil
    }

    /// 暂停或恢复记录：暂停时上屏一律不转给个人化组件。
    func setRecordingPaused(_ paused: Bool) {
        update { $0.recordingPaused = paused }
    }

    /// 这个输入框里的上屏能不能转给个人化组件（同意读写记忆另由沙盒把关）。
    func mayRecord(in app: String?) -> Bool {
        !config.recordingPaused && !config.noRecord(for: app)
    }

    /// 记忆记录现在实际的状态，菜单和设置窗口照这个写。
    enum RecordingState: Equatable { case unavailable, notConsented, paused, appForbidden, recording }

    /// 螺壳（主控）现在连不连得上：连不上时没有重排、联想和语音转写，打字照常（菜单里提示一行）。
    var hubReachable: Bool { broker.hub?.reachable ?? false }

    func recordingState(in app: String?) -> RecordingState {
        guard let p = personal, p.manifest.permissions.memory else { return .unavailable }
        if case .disabled = p.state { return .unavailable }
        if !memoryConsented { return .notConsented }
        if config.recordingPaused { return .paused }
        if config.noRecord(for: app) { return .appForbidden }
        if let s = memoryStatus, s != "ok", s != "pending" { return .unavailable }
        return .recording
    }

    /// 开发模式的记录这会儿要不要停（壳在每次按键前设，对打字引擎和个人化组件都管）。
    /// 按这个输入框的隐私状态定：开发模式的记录停不停（打字引擎、快捷键引擎、个人化组件都管），引擎的转问交不交给个人化组件。
    /// 壳在每次按键前、换输入框时调。
    func applyPrivacy(secureInput: Bool, mayRecord: Bool) {
        let d = PersonalPolicy.decide(.init(thirdParty: personalIsThirdParty, secureInput: secureInput, userStopped: !mayRecord,
                                            enabled: memoryConsented))
        typing?.recorder?.muted = !d.devRecording
        personal?.recorder?.muted = !d.devRecording
        for h in hotkeys { h.recorder?.muted = !d.devRecording }
        broker.personalAllowed = d.relayAsks
    }

    /// 正在用的个人化组件不是随输入法发布的。
    var personalIsThirdParty: Bool { personalEntry.map { !$0.bundled } ?? false }

    private func save() {
        guard migrationError == nil else { return } // 原文件没另存成：不覆盖它
        do {
            try config.save(paths.settings)
            configDate = modificationDate(paths.settings)
        } catch {
            log.error("保存设置失败：\(String(describing: error), privacy: .public)")
        }
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// 用户登录 shell 里的 PATH：引擎说明里写 `python3`，找到的和在终端里一样。
    static let fixedPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func resolveLoginPath() -> String {
        let fallback = fixedPath
        let shell = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return fallback }
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning, Date() < deadline { usleep(10_000) }
        if p.isRunning { p.terminate(); return fallback }
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return path.contains("/usr/bin") ? path : fallback
    }
}
