import Foundation

/// 壳的设置：~/.luoke/ime/settings.json。普通 JSON，agent 可以直接改；壳监视它，改了就生效。
///
/// 第 2 版（luokelabs/luoke-ime#1）：全局默认值加按应用覆盖。应用设置里没写的项跟随全局，
/// 按项继承（覆盖一项不冻结别的项）。第 1 版（没有 `version`）的 `app_exceptions` 读进来时一次换成第 2 版，
/// 原文件另存一份 settings.v1.json（EngineManager 做）。
public struct ShellConfig: Equatable {
    public static let version = 2

    /// 某个应用的设置：nil 表示跟随全局。
    public struct AppSettings: Equatable {
        /// 进入这个应用时默认是英文（true）还是中文（false）。
        public var english: Bool?
        /// 拼音显示在输入框里（true）还是候选窗里（false）。
        public var inline: Bool?
        /// 联想开（true）还是关（false）。
        public var predict: Bool?
        /// 禁止记录：这个应用里的上屏不转给个人化组件。只能进一步禁止，不能绕过全局的未同意或暂停。
        public var noRecord = false

        public init(english: Bool? = nil, inline: Bool? = nil, predict: Bool? = nil, noRecord: Bool = false) {
            self.english = english
            self.inline = inline
            self.predict = predict
            self.noRecord = noRecord
        }

        public var isEmpty: Bool { english == nil && inline == nil && predict == nil && !noRecord }
    }

    public var currentEngine: String?
    /// 候选窗、键位、中英文之间加空格、联想（`predict` 是全局默认，应用可以覆盖）。
    public var settings = ShellSettings()
    public var fontSize: Double = 16
    /// 全局默认：进入应用时是英文还是中文。
    public var defaultEnglish = false
    /// 记住各应用上次的中英文模式（重启输入法后也记得）。关着时每次切回应用用它的默认值，同一应用里换输入框不变。
    public var rememberMode = true
    /// 全局默认：拼音显示在输入框里（true）还是候选窗里（false）。
    public var inline = true
    public var apps: [String: AppSettings] = [:]
    /// 记住的各应用上次的模式（true 是英文）。只存和这个应用的默认值不一样的；只有 bundle id，没有打的字。
    public var appModes: [String: Bool] = [:]
    /// 打开了开发模式的引擎。
    public var devMode: Set<String> = []
    /// 用户暂停了所有记录：上屏一律不转给个人化组件。存在设置里，重启后照样暂停。暂停不删已有的数据。
    public var recordingPaused = false
    /// 第三方个人化组件里用户同意了读写记忆的（键是"标识@指纹"）。自带的不看这个，看 memoryOff。
    public var memoryConsent: Set<String> = []
    /// 自带的个人化组件里用户关掉了记忆记录的（顶层 ADR 0013：自带的默认开，用户能关）。
    public var memoryOff: Set<String> = []
    /// 已经提示过一次"要不要从你打的字里学"的组件，不再提示。
    public var memoryAsked: Set<String> = []
    /// 用户确认启用过的第三方引擎：引擎标识 → 确认时引擎说明的指纹（ThirdParty.fingerprint）。指纹变了要重新确认。
    public var approvedEngines: [String: String] = [:]
    /// 模糊音：总开关默认关，打开后默认六组全勾。关着时勾选留着，再打开还是原样。
    public var fuzzyOn = false
    public var fuzzyPairs: Set<String> = Set(ShellConfig.fuzzyChoices)
    /// 这一版能选的组（"z_zh" 里两边是互通的拼法），也是界面上的顺序。
    public static let fuzzyChoices = ["z_zh", "s_sh", "c_ch", "an_ang", "en_eng", "in_ing"]
    /// 交给打字引擎的组：总开关关着时是空的。
    public var fuzzyActive: [String] { fuzzyOn ? Self.fuzzyChoices.filter(fuzzyPairs.contains) : [] }
    /// 语音输入：声明了麦克风的快捷键引擎（自带的语音）只在打开时启动、向系统要麦克风。默认关。
    public var voiceOn = false
    /// 说完后整理（去口头禅、理顺改口）：nil 时按这台 Mac 的内存定（voiceTidyDefault：24 GB 以上才默认整理）。
    public var voiceTidy: Bool?
    /// 16 GB 内存的 Mac 默认不整理：底座和转写模型二选一，每次整理要重新加载 9B，实测 8–10 秒（ADR 0016）。
    public static var voiceTidyDefault: Bool { ProcessInfo.processInfo.physicalMemory > 24 << 30 }
    /// 交给语音引擎的 tidy 选项。
    public var voiceTidyActive: Bool { voiceTidy ?? Self.voiceTidyDefault }
    /// 按住哪个键说话：nil 时照语音引擎说明里的（右 ⌥）。外接 Windows 键盘、对调过修饰键的，右 Alt 发出来的可能是右 ⌘，在这里换。
    public var voiceKey: Manifest.Hotkey.Key?
    /// 主控的 socket（开发时指向开发版螺壳）；nil 时用装好的主控的位置（或环境变量 LUOKE_HUB_SOCKET）。
    public var hubSocket: String?
    /// 这一版不认识的键（比如回滚到旧版时，新版写下的）：原样留着、存盘时写回去，再换回新版时不丢（luokelabs/luoke-core#12 配件回滚）。
    public var unknown: [String: JSONValue] = [:]
    public var unknownRecording: [String: JSONValue] = [:]
    static let knownKeys: Set<String> = ["version", "defaults", "candidate_window", "keys", "apps", "app_modes", "dev_mode", "recording",
                                         "auto_space", "approved_engines", "current_engine", "hub", "fuzzy", "voice"]
    static let knownRecordingKeys: Set<String> = ["paused", "memory_consent", "memory_asked", "memory_off"]
    /// 这份是从第 1 版的文件换过来的（调用方据此另存原文件、写回第 2 版）。
    public var migratedFromV1 = false

    public init() {}

    /// 壳自带的已知问题应用名单（随跨应用测试矩阵补充）。用户的设置优先。
    /// 终端不默认英文：vibe coder 常在终端里用中文给 agent 写提示。
    public static let builtinApps: [String: AppSettings] = [:]

    // MARK: - 按应用算出实际的值

    /// 这个应用自己的设置（用户的，没有就用自带名单里的）。
    public func app(_ app: String?) -> AppSettings {
        guard let app else { return AppSettings() }
        return apps[app] ?? Self.builtinApps[app] ?? AppSettings()
    }

    public func defaultEnglish(for app: String?) -> Bool { self.app(app).english ?? defaultEnglish }
    public func inline(for app: String?) -> Bool { self.app(app).inline ?? inline }
    public func predict(for app: String?) -> Bool {
        if let v = self.app(app).predict { return v }
        // 终端里默认不联想：Terminal 这类终端不把 Tab 交给输入法（光标处没有显示串时它自己处理 Tab、Esc、回车），
        // 联想提示亮了也选不上，按 Tab 反而触发 shell 的补全（测试机上实测后定）。应用设置里能打开
        if let app, Self.terminals.contains(app) { return false }
        return settings.predict
    }
    /// 默认不联想的终端应用。
    public static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "org.alacritty",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "co.zeit.hyper", "com.raphaelamorim.rio", "org.tabby", "com.tabby",
    ]
    public func noRecord(for app: String?) -> Bool { self.app(app).noRecord }

    /// 进入某个应用的输入框时该是英文吗。
    /// - 记住上次模式：记过的用记的，否则用这个应用的默认值。
    /// - 不记：还在同一个应用里（换了个输入框）用这个进程里记着的，换了应用就用默认值。
    public func englishOnEnter(app: String?, lastApp: String?, inMemory: Bool?) -> Bool {
        if rememberMode, let app, let m = appModes[app] { return m }
        if !rememberMode, app == lastApp, let inMemory { return inMemory }
        return defaultEnglish(for: app)
    }

    /// 用户在某个应用里切了中英文：记住上次模式时记下来（和默认值一样就不记）。
    public mutating func noteMode(english: Bool, for app: String?) {
        guard rememberMode, let app else { return }
        appModes[app] = english == defaultEnglish(for: app) ? nil : english
    }

    /// 改全局默认的中英文：跟随全局的应用记着的模式清掉（下次进去用新的默认值），自己设了的应用不动。
    public mutating func setDefaultEnglish(_ on: Bool) {
        defaultEnglish = on
        for app in appModes.keys where self.app(app).english == nil { appModes[app] = nil }
    }

    /// 改某个应用的设置；改了默认的中英文，这个应用记着的模式清掉。没有覆盖项了就整条删掉（恢复跟随全局）。
    public mutating func setApp(_ app: String, _ change: (inout AppSettings) -> Void) {
        var a = self.app(app)
        let before = a.english
        change(&a)
        if a.english != before { appModes[app] = nil }
        apps[app] = a.isEmpty ? nil : a
    }

    /// 菜单里「在此应用关闭联想」点一下：实际联想与否反过来；反过来正好是"跟随"的结果时去掉覆盖
    /// （终端里跟随是关，所以在终端里打开要写显式的 true）。
    public mutating func togglePredict(app: String) {
        let target = !predict(for: app)
        setApp(app) { $0.predict = nil }
        let follow = predict(for: app)
        setApp(app) { $0.predict = target == follow ? nil : target }
    }

    /// 关掉"记住上次模式"时清掉记着的，免得留着没用的应用名单。
    public mutating func setRememberMode(_ on: Bool) {
        rememberMode = on
        if !on { appModes = [:] }
    }

    /// 某个个人化组件的记忆记录开没开：自带的默认开、用户关了才算关；第三方的要用户同意过。
    public func memoryEnabled(key: String, bundled: Bool) -> Bool {
        bundled ? !memoryOff.contains(key) : memoryConsent.contains(key)
    }

    public mutating func setMemory(key: String, bundled: Bool, on: Bool) {
        if bundled {
            if on { memoryOff.remove(key) } else { memoryOff.insert(key) }
        } else {
            if on { memoryConsent.insert(key) } else { memoryConsent.remove(key) }
        }
        memoryAsked.insert(key)
    }

    // MARK: - 读写

    public static func load(_ url: URL) -> ShellConfig {
        loadIfValid(url) ?? ShellConfig()
    }

    /// 文件不存在时是全默认值；存在但读不懂（比如别的程序正写到一半）时返回 nil，调用方应保留原来的设置。
    public static func loadIfValid(_ url: URL) -> ShellConfig? {
        guard let data = try? Data(contentsOf: url) else { return FileManager.default.fileExists(atPath: url.path) ? nil : ShellConfig() }
        guard let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return parse(m)
    }

    public static func parse(_ m: [String: Any]) -> ShellConfig {
        var c = ShellConfig()
        c.currentEngine = m["current_engine"] as? String
        if let w = m["candidate_window"] as? [String: Any] {
            if let o = (w["orientation"] as? String).flatMap(ShellSettings.Orientation.init(rawValue:)) { c.settings.orientation = o }
            if let n = w["page_size"] as? Int { c.settings.pageSize = min(max(n, 1), 9) }
            if let f = w["font_size"] as? Double { c.fontSize = min(max(f, 10), 40) }
        }
        if let k = m["keys"] as? [String: Any] {
            if let p = (k["paging"] as? String).flatMap(ShellSettings.PagingKeys.init(rawValue:)) { c.settings.pagingKeys = p }
            if let s = k["shift_toggles"] as? Bool { c.settings.shiftToggles = s }
            if let b = k["corner_braces"] as? Bool { c.settings.cornerBraces = b }
        }
        if let d = m["dev_mode"] as? [String] { c.devMode = Set(d) }
        if let r = m["recording"] as? [String: Any] {
            c.recordingPaused = r["paused"] as? Bool ?? false
            c.memoryConsent = Set(r["memory_consent"] as? [String] ?? [])
            c.memoryAsked = Set(r["memory_asked"] as? [String] ?? [])
            if let off = r["memory_off"] as? [String] {
                c.memoryOff = Set(off)
            } else {
                // 旧版存的是"同意了谁"、默认关：问过却没开的自带组件，照旧算关着（已经选过关的不动）
                c.memoryOff = Set(c.memoryAsked.filter { !$0.contains("@") && !c.memoryConsent.contains($0) })
            }
        }
        if let a = m["auto_space"] as? Bool { c.settings.autoSpace = a }
        if let f = m["fuzzy"] as? [String: Any] {
            c.fuzzyOn = f["on"] as? Bool ?? false
            if let p = f["pairs"] as? [String] { c.fuzzyPairs = Set(p).intersection(fuzzyChoices) }
        }
        if let v = m["voice"] as? [String: Any] {
            c.voiceOn = v["on"] as? Bool ?? false
            c.voiceTidy = v["tidy"] as? Bool
            c.voiceKey = (v["key"] as? String).flatMap(Manifest.Hotkey.Key.init(rawValue:))
        }
        if let ap = m["approved_engines"] as? [String: String] { c.approvedEngines = ap }
        if let h = m["hub"] as? [String: Any], let s = h["socket"] as? String, !s.isEmpty {
            c.hubSocket = (s as NSString).expandingTildeInPath
        }

        if m["version"] == nil {
            // 第 1 版：全局只有联想；应用例外 no_inline / english / no_record / no_predict 换成按应用覆盖
            if let p = m["predict"] as? Bool { c.settings.predict = p }
            if let ex = m["app_exceptions"] as? [String: [String: Any]] {
                for (app, v) in ex {
                    let a = AppSettings(english: v["english"] as? Bool == true ? true : nil,
                                        inline: v["no_inline"] as? Bool == true ? false : nil,
                                        predict: v["no_predict"] as? Bool == true ? false : nil,
                                        noRecord: v["no_record"] as? Bool ?? false)
                    if !a.isEmpty { c.apps[app] = a }
                }
            }
            c.migratedFromV1 = true
            return c
        }

        for (k, v) in m where !knownKeys.contains(k) { c.unknown[k] = JSONValue(v) }
        if let r = m["recording"] as? [String: Any] {
            for (k, v) in r where !knownRecordingKeys.contains(k) { c.unknownRecording[k] = JSONValue(v) }
        }
        if let d = m["defaults"] as? [String: Any] {
            if let e = d["english"] as? Bool { c.defaultEnglish = e }
            if let r = d["remember_mode"] as? Bool { c.rememberMode = r }
            if let i = d["inline"] as? Bool { c.inline = i }
            if let p = d["predict"] as? Bool { c.settings.predict = p }
        }
        if let apps = m["apps"] as? [String: [String: Any]] {
            for (app, v) in apps {
                let a = AppSettings(english: v["english"] as? Bool, inline: v["inline"] as? Bool, predict: v["predict"] as? Bool,
                                    noRecord: v["no_record"] as? Bool ?? false)
                if !a.isEmpty { c.apps[app] = a }
            }
        }
        if c.rememberMode, let modes = m["app_modes"] as? [String: String] {
            for (app, v) in modes where v == "english" || v == "chinese" { c.appModes[app] = v == "english" }
        }
        return c
    }

    public var json: [String: Any] {
        var m: [String: Any] = [
            "version": Self.version,
            "defaults": ["english": defaultEnglish, "remember_mode": rememberMode, "inline": inline, "predict": settings.predict],
            "candidate_window": ["orientation": settings.orientation.rawValue, "page_size": settings.pageSize, "font_size": fontSize],
            "keys": ["paging": settings.pagingKeys.rawValue, "shift_toggles": settings.shiftToggles, "corner_braces": settings.cornerBraces],
            "apps": apps.mapValues { a -> [String: Any] in
                var v: [String: Any] = [:]
                v["english"] = a.english
                v["inline"] = a.inline
                v["predict"] = a.predict
                if a.noRecord { v["no_record"] = true }
                return v
            },
            "app_modes": appModes.mapValues { $0 ? "english" : "chinese" },
            "dev_mode": devMode.sorted(),
            "recording": ["paused": recordingPaused, "memory_consent": memoryConsent.sorted(), "memory_asked": memoryAsked.sorted(),
                          "memory_off": memoryOff.sorted()],
            "auto_space": settings.autoSpace,
            "fuzzy": ["on": fuzzyOn, "pairs": Self.fuzzyChoices.filter(fuzzyPairs.contains)],
            "approved_engines": approvedEngines,
        ]
        m["current_engine"] = currentEngine
        var voice: [String: Any] = ["on": voiceOn]
        voice["tidy"] = voiceTidy
        voice["key"] = voiceKey?.rawValue
        m["voice"] = voice
        if let hubSocket { m["hub"] = ["socket": hubSocket] }
        for (k, v) in unknown where m[k] == nil { m[k] = v.any }
        if !unknownRecording.isEmpty, var r = m["recording"] as? [String: Any] {
            for (k, v) in unknownRecording where r[k] == nil { r[k] = v.any }
            m["recording"] = r
        }
        return m
    }

    public func save(_ url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 不用 Data.write(.atomic)：它的临时副本放在系统共用的 TemporaryItems 里，引擎（沙盒放行了那里）能抢在改名前
        // 改掉它，给自己加上确认、记忆同意。临时文件建在设置文件旁边（引擎写不到这个目录），
        // O_EXCL | O_NOFOLLOW 新建，写完再改名。
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path]) }
        let ok = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return fsync(fd) == 0
        }
        close(fd)
        guard ok, rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    /// 比较时不看 migratedFromV1（只是读的时候的标记）。
    public static func == (a: ShellConfig, b: ShellConfig) -> Bool {
        var a = a, b = b
        a.migratedFromV1 = false
        b.migratedFromV1 = false
        return a.currentEngine == b.currentEngine && a.settings == b.settings && a.fontSize == b.fontSize
            && a.defaultEnglish == b.defaultEnglish && a.rememberMode == b.rememberMode && a.inline == b.inline && a.apps == b.apps
            && a.appModes == b.appModes && a.devMode == b.devMode && a.recordingPaused == b.recordingPaused
            && a.memoryConsent == b.memoryConsent && a.memoryAsked == b.memoryAsked && a.memoryOff == b.memoryOff && a.hubSocket == b.hubSocket
            && a.approvedEngines == b.approvedEngines && a.fuzzyOn == b.fuzzyOn && a.fuzzyPairs == b.fuzzyPairs
            && a.voiceOn == b.voiceOn && a.voiceTidy == b.voiceTidy && a.voiceKey == b.voiceKey
    }
}
