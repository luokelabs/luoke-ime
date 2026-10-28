import Foundation
import LuokeShell

struct TryOptions {
    var engineDir = URL(fileURLWithPath: ".")
    var keys: String?
    var context = ""
    var app: String?
    var hotkeyDir: URL?
    var personalDir: URL?
    /// 引擎的数据目录放在哪（--data）。缺省是临时目录里固定的一份，不碰日常在用的 ~/.luoke/ime。
    var dataRoot: URL?
    /// 主控的 socket（--hub）。不给就不接主控，不退回装好的那个（不碰日常在用的实例）。
    var hubSocket: String?
    var autoSpace = false
    var sandboxed = true
    var record = false
}

/// 命令行版扮演的"应用输入框"：一段文字，光标在末尾。
final class TerminalClient: SessionClient {
    var document: String
    var view = SessionView()
    var appID: String?
    var isSecureInput = false
    var onChange: () -> Void = {}

    init(document: String, app: String?) {
        self.document = document
        appID = app
    }

    func textBeforeCursor(limit: Int) -> String? { String(document.suffix(limit)) }
    func insert(_ text: String) { document += text; onChange() }
    func render(_ view: SessionView) { self.view = view; onChange() }

    /// 壳放行的键，由"应用"自己处理。
    func passThrough(_ e: KeyEvent) {
        guard e.flags.isDisjoint(with: [.command, .control, .option]) else { return }
        switch e.key {
        case let .character(c): document.append(c)
        case .space: document.append(" ")
        case .enter: document.append("\n")
        case .tab: document.append("\t")
        case .backspace: if !document.isEmpty { document.removeLast() }
        default: return
        }
        onChange()
    }
}

/// 转给个人化组件的消息逐条记进事件里，写个人化组件时看得到它收到了什么。
final class LoggedChannel: EngineChannel {
    let inner: EngineChannel
    let log: (String) -> Void
    init(_ inner: EngineChannel, log: @escaping (String) -> Void) {
        self.inner = inner
        self.log = log
    }
    var isAvailable: Bool { inner.isAvailable }
    func nextID() -> Int { inner.nextID() }
    func send(_ message: ShellMessage) {
        log(message.line)
        inner.send(message)
    }
    func drain() -> [EngineMessage] { inner.drain() }
    func wait(until deadline: TimeInterval) { inner.wait(until: deadline) }
    func reportHang() { inner.reportHang() }
}

/// 一次试用：引擎连接、会话和事件记录。交互模式和脚本模式共用。
final class Trial {
    let typing: EngineConnection
    var hotkey: EngineConnection?
    var personal: EngineConnection?
    let broker = AskBroker()
    /// 试用时引擎的数据目录：不碰日常在用的那份。沙盒照样保护真的 ~/.luoke/ime。
    let paths: Paths
    let session: Session
    let client: TerminalClient
    let channel: EngineChannel
    var recorder: Recorder?
    private let lock = NSLock()
    private var events: [String] = []
    private var restarted = false
    private var predictions: [(id: Int, items: [String])] = []
    private var disabledReason: String?
    private let monitor = SandboxMonitor()
    private var reportedDenials = Set<String>()
    private let wake: (read: Int32, write: Int32)

    init(_ o: TryOptions) throws {
        var fds: [Int32] = [0, 0]
        pipe(&fds)
        wake = (fds[0], fds[1])
        _ = fcntl(wake.read, F_SETFL, O_NONBLOCK)

        let root = o.dataRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("luoke-ime-try/ime")
        paths = Paths(root: root, memory: root.deletingLastPathComponent().appendingPathComponent("mem.db"))
        broker.hub = o.hubSocket.map { HubClient(accessory: "luoke-ime/dev", socketPath: $0) }
        typing = try EngineConnection(dir: o.engineDir, paths: paths)
        typing.protectedPaths = Paths()
        switch typing.manifest.kind {
        case .typing: break
        case .hotkey: throw EngineError("\(o.engineDir.path) 是快捷键引擎；try 的第一个参数要是打字引擎，快捷键引擎用 --hotkey")
        case .personal: throw EngineError("\(o.engineDir.path) 是个人化组件；try 的第一个参数要是打字引擎，个人化组件用 --personal")
        }
        client = TerminalClient(document: o.context, app: o.app)
        var settings = ShellSettings()
        settings.autoSpace = o.autoSpace
        session = Session(client: client, settings: settings)
        channel = typing.makeChannel()
        session.typing = TypingEngine(manifest: typing.manifest, channel: channel, id: typing.id)
        broker.attach(typing)
        if o.record {
            paths.prepare() // 输入记录里有按键：目录只有自己能进
            let r = try Recorder(directory: paths.records(typing.id))
            r.record(.context, ["document": o.context, "app": o.app as Any? ?? NSNull(), "engine": o.engineDir.path])
            recorder = r
        }
        configure(typing, sandboxed: o.sandboxed)

        if let dir = o.hotkeyDir {
            let h = try EngineConnection(dir: dir, paths: paths)
            h.protectedPaths = Paths()
            guard h.manifest.kind == .hotkey else { throw EngineError("\(dir.path) 不是快捷键引擎") }
            h.startsLazily = true
            configure(h, sandboxed: o.sandboxed)
            broker.attach(h)
            session.hotkeys = [HotkeyEngine(manifest: h.manifest, channel: h.makeChannel(), id: h.id)]
            hotkey = h
        }
        if let dir = o.personalDir {
            // 试用时的上屏不写进真的记忆：记忆是试用数据目录旁边的一份
            let manifest = try Manifest.load(from: dir)
            guard manifest.kind == .personal else { throw EngineError("\(dir.path) 不是个人化组件（kind 要是 personal）") }
            let p = EngineConnection(id: dir.standardizedFileURL.lastPathComponent, dir: dir, manifest: manifest, paths: paths)
            // 个人化组件默认只经主控打分；没写 --hub 时，试用的数据目录里还没有它的选项，就用本机的打分进程
            let opts = paths.data(p.id).appendingPathComponent("options.json")
            if o.hubSocket == nil, !FileManager.default.fileExists(atPath: opts.path) {
                try FileManager.default.createDirectory(at: opts.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(#"{"scorer": "local"}"#.utf8).write(to: opts)
            }
            p.protectedPaths = Paths()
            p.memoryGranted = true // 试用时的记忆是临时的一份
            configure(p, sandboxed: o.sandboxed)
            broker.attach(p)
            broker.personal = p
            let name = p.manifest.name
            session.personal = PersonalEngine(manifest: p.manifest,
                                              channel: LoggedChannel(p.makeChannel()) { [weak self] in self?.log("→ \(name) \($0)") }, id: p.id)
            // 联想：经中转问个人化组件，答复到了交给主循环
            session.predictor = { [weak self] id, context, app in
                var params: [String: JSONValue] = ["context": .string(context)]
                if let app { params["app"] = .string(app) }
                self?.broker.askFromShell(method: "predict", params: .object(params)) { reply in
                    guard let self else { return }
                    var items: [String] = []
                    if case let .object(o)? = reply.result, case let .array(a)? = o["candidates"] {
                        items = a.compactMap { if case let .string(s) = $0 { return s } else { return nil } }
                    }
                    self.lock.lock(); self.predictions.append((id, items)); self.lock.unlock()
                    self.poke()
                }
            }
            personal = p
            try p.start()
        }
        if o.sandboxed {
            var tags = [typing.sandboxTag: typing.manifest.name]
            if let h = hotkey { tags[h.sandboxTag] = h.manifest.name }
            if let p = personal { tags[p.sandboxTag] = p.manifest.name }
            monitor.onDenial = { [weak self] d in
                guard let self, d.severity == .hard, let name = tags[d.engine] else { return }
                let key = "\(d.engine) \(d.category) \(d.operation) \(d.detail)"
                self.lock.lock()
                let fresh = self.reportedDenials.insert(key).inserted
                self.lock.unlock()
                if fresh { self.log("\(name) 被沙盒拦下：\(d.suggestion)") } // 每种只报一次
                self.poke()
            }
            if !monitor.start() { log("读不了系统日志，看不到沙盒拦截（可能需要管理员账户）") }
        }
        try typing.start()
    }

    private func configure(_ c: EngineConnection, sandboxed: Bool) {
        c.sandboxed = sandboxed
        c.recorder = recorder
        let name = c.manifest.name
        c.onMessage = { [weak self] in self?.poke() }
        c.onEvent = { [weak self] e in
            guard let self else { return }
            switch e {
            case .started:
                self.lock.lock(); self.restarted = true; self.lock.unlock()
            case let .stderr(line): self.log("\(name) ⟩ \(line)")
            case let .protocolError(msg): self.log("\(name) 协议错误：\(msg)")
            case let .exited(status, _): self.log("\(name) 退出了（状态 \(status)），正在重启")
            case let .disabled(reason):
                self.log("\(name) 已停用：\(reason)")
                self.lock.lock(); self.disabledReason = reason; self.lock.unlock()
            }
            self.poke()
        }
    }

    func log(_ s: String) {
        lock.lock()
        events.append(s)
        if events.count > 200 { events.removeFirst(events.count - 200) }
        lock.unlock()
    }

    func takeEvents() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    private func poke() {
        var b: UInt8 = 1
        _ = write(wake.write, &b, 1)
    }

    var wakeFD: Int32 { wake.read }

    /// 在主循环里调用：清掉唤醒字节、处理重启、pump、tick。
    func service() {
        var buf = [UInt8](repeating: 0, count: 64)
        while read(wake.read, &buf, 64) > 0 {}
        lock.lock()
        let r = restarted
        restarted = false
        let disabled = disabledReason
        disabledReason = nil
        let predicted = predictions
        predictions = []
        lock.unlock()
        for p in predicted { session.receivePredictions(id: p.id, items: p.items) }
        if r { session.engineDidStart() }
        if disabled != nil { session.setNotice("引擎已停用（详情见下方）") }
        session.tick()
    }

    func feed(_ e: KeyEvent) {
        recorder?.record(.key, e.json)
        if !session.handle(e) { client.passThrough(e) }
    }

    /// 等到会话不再等引擎（脚本模式每个键之后用）。
    func settle(timeout: TimeInterval = 3) {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            let now = ProcessInfo.processInfo.systemUptime
            channel.wait(until: min(session.nextDeadline ?? now + 0.05, now + 0.05))
            service()
        } while session.isWaitingForEngine && ProcessInfo.processInfo.systemUptime < end
    }

    /// 引擎文件改了：重新读引擎说明并重启引擎，下一个键就用新版本。
    func reload() {
        typing.stopAndWait(timeout: 1)
        do {
            let m = try Manifest.load(from: typing.dir)
            if m != typing.manifest { log("引擎说明改了；输入键、标点表等要重新运行 try 才生效") }
            try typing.start()
            log("引擎文件改了，已重启")
        } catch {
            log("引擎文件改了，但重启失败：\(error)")
        }
    }

    func shutdown() {
        monitor.stop()
        typing.stopAndWait(timeout: 1)
        hotkey?.stopAndWait(timeout: 1)
        personal?.stopAndWait(timeout: 1)
    }
}

func describe(_ e: KeyEvent) -> String {
    var mods = ""
    if e.flags.contains(.control) { mods += "ctrl+" }
    if e.flags.contains(.option) { mods += "opt+" }
    if e.flags.contains(.command) { mods += "cmd+" }
    switch e.key {
    case let .character(c): return mods + String(c)
    case let .modifierDown(m): return "↓" + m.rawValue
    case let .modifierUp(m): return "↑" + m.rawValue
    default: return mods + "{\(e.key)}"
    }
}

// MARK: - 按键脚本

enum ScriptStep {
    case key(KeyEvent)
    case shiftTap
    case forget
    case hotkey
    case wait(TimeInterval)
}

func parseScript(_ s: String) throws -> [(label: String, step: ScriptStep)] {
    var out: [(String, ScriptStep)] = []
    var i = s.startIndex
    while i < s.endIndex {
        let c = s[i]
        if c == "{" {
            let next = s.index(after: i)
            if next < s.endIndex, s[next] == "{" {
                out.append(("{", .key(.char("{"))))
                i = s.index(after: next)
                continue
            }
            guard let close = s[next...].firstIndex(of: "}") else { throw EngineError("按键脚本里的 { 没有闭合") }
            let name = String(s[next..<close])
            i = s.index(after: close)
            let label = "{\(name)}"
            switch name {
            case "space": out.append((label, .key(KeyEvent(.space))))
            case "enter": out.append((label, .key(KeyEvent(.enter))))
            case "bs": out.append((label, .key(KeyEvent(.backspace))))
            case "esc": out.append((label, .key(KeyEvent(.escape))))
            case "tab": out.append((label, .key(KeyEvent(.tab))))
            case "left": out.append((label, .key(KeyEvent(.left))))
            case "right": out.append((label, .key(KeyEvent(.right))))
            case "up": out.append((label, .key(KeyEvent(.up))))
            case "down": out.append((label, .key(KeyEvent(.down))))
            case "pgup": out.append((label, .key(KeyEvent(.pageUp))))
            case "pgdn": out.append((label, .key(KeyEvent(.pageDown))))
            case "shift": out.append((label, .shiftTap))
            case "forget": out.append((label, .forget))
            case "hotkey": out.append((label, .hotkey))
            default:
                if name.hasPrefix("wait:"), let ms = Double(name.dropFirst(5)) {
                    out.append((label, .wait(ms / 1000)))
                } else if name.hasPrefix("cmd+"), name.count == 5, let ch = name.last {
                    out.append((label, .key(.char(ch, flags: .command))))
                } else {
                    throw EngineError("按键脚本里不认识 \(label)")
                }
            }
        } else {
            let flags: KeyEvent.Flags = c.isUppercase && c.isASCII ? .shift : []
            out.append((String(c), c == " " ? .key(KeyEvent(.space)) : .key(.char(c, flags: flags))))
            i = s.index(after: i)
        }
    }
    return out
}

// MARK: - 运行

func runTry(_ o: TryOptions) -> Int32 {
    let trial: Trial
    do {
        trial = try Trial(o)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        return 2
    }
    defer { trial.shutdown() }
    if let keys = o.keys { return runScript(trial, keys) }
    guard isatty(STDIN_FILENO) != 0 else {
        FileHandle.standardError.write(Data("标准输入不是终端；非交互使用请加 --keys\n".utf8))
        return 2
    }
    return runInteractive(trial)
}

private var holdingHotkey = false

private func apply(_ step: ScriptStep, _ t: Trial) {
    switch step {
    case let .key(e): t.feed(e)
    case .shiftTap:
        t.feed(KeyEvent(.modifierDown(.leftShift)))
        t.feed(KeyEvent(.modifierUp(.leftShift)))
    case .forget: t.feed(KeyEvent(.backspace, flags: .shift))
    case .hotkey:
        guard let key = t.session.hotkeys.first?.manifest.hotkey else {
            t.log("没有装快捷键引擎（用 --hotkey 装一个）")
            return
        }
        let m: KeyEvent.Modifier = key.key == .rightCommand ? .rightCommand : key.key == .rightOption ? .rightOption : .rightControl
        if key.mode == .press {
            t.feed(KeyEvent(.modifierDown(m)))
            t.feed(KeyEvent(.modifierUp(m)))
        } else if holdingHotkey {
            holdingHotkey = false
            t.feed(KeyEvent(.modifierUp(m)))
        } else {
            holdingHotkey = true
            t.feed(KeyEvent(.modifierDown(m)))
        }
    case let .wait(dt):
        let end = ProcessInfo.processInfo.systemUptime + dt
        while ProcessInfo.processInfo.systemUptime < end {
            let now = ProcessInfo.processInfo.systemUptime
            t.channel.wait(until: min(t.session.nextDeadline ?? end, end, now + 0.05))
            t.service()
        }
    }
}

func summarizeView(_ v: SessionView) -> String {
    var parts: [String] = []
    if v.english { parts.append("[英]") }
    parts.append("光标处：" + (v.marked.isEmpty ? "—" : v.marked))
    if !v.candidates.isEmpty {
        let items = v.candidates.enumerated().map { i, c -> String in
            let mark = i == v.highlighted ? "*" : ""
            return "\(mark)\(i + 1).\(c.text)" + (c.note.map { "(\($0))" } ?? "")
        }
        parts.append((v.predicting ? "联想：" : "候选：") + items.joined(separator: " ") + (v.pageCount > 1 ? " ‹\(v.page + 1)/\(v.pageCount)›" : "") + (v.pending ? " ⋯" : ""))
    }
    if v.predictHint { parts.append("⇥ 联想") }
    if let n = v.notice { parts.append("提示：" + n) }
    return parts.joined(separator: "  ")
}

private func runScript(_ t: Trial, _ keys: String) -> Int32 {
    let steps: [(label: String, step: ScriptStep)]
    do { steps = try parseScript(keys) } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        return 2
    }
    t.settle()
    print("引擎：\(t.typing.manifest.name)（\(t.typing.dir.path)）")
    for (label, step) in steps {
        apply(step, t)
        t.settle()
        let doc = t.client.document.replacingOccurrences(of: "\n", with: "⏎")
        print("\(label.padding(toLength: max(8, label.count), withPad: " ", startingAt: 0)) \(summarizeView(t.client.view))  输入框：「\(doc)」")
    }
    let events = t.takeEvents()
    if !events.isEmpty {
        print("\n引擎的输出与事件：")
        events.forEach { print("  " + $0) }
    }
    if let r = t.recorder { print("\n输入记录：\(r.url.path)") }
    return 0
}

// MARK: - 交互模式

private var savedTermios = termios()

private func enableRawMode() {
    tcgetattr(STDIN_FILENO, &savedTermios)
    var raw = savedTermios
    raw.c_iflag &= ~tcflag_t(ICRNL | IXON | BRKINT | INPCK | ISTRIP)
    raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    print("\u{1B}[?25l", terminator: "")
}

private func disableRawMode() {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTermios)
    print("\u{1B}[?25h\u{1B}[0m")
}

/// 把终端字节翻译成按键。终端区分不了单按 Shift 等，用 Ctrl 组合代替。
private enum Input { case key(KeyEvent), shiftTap, forget, hotkey, quit }

private func decode(_ bytes: [UInt8]) -> [Input] {
    var out: [Input] = []
    var i = 0
    while i < bytes.count {
        let b = bytes[i]
        switch b {
        case 0x03, 0x04: out.append(.quit)
        case 0x0D, 0x0A: out.append(.key(KeyEvent(.enter)))
        case 0x7F, 0x08: out.append(.key(KeyEvent(.backspace)))
        case 0x09: out.append(.key(KeyEvent(.tab)))
        case 0x14: out.append(.shiftTap)  // Ctrl-T
        case 0x18: out.append(.forget)    // Ctrl-X
        case 0x12: out.append(.hotkey)    // Ctrl-R
        case 0x20: out.append(.key(KeyEvent(.space)))
        case 0x1B:
            if i + 2 < bytes.count, bytes[i + 1] == 0x5B {
                let c = bytes[i + 2]
                switch c {
                case 0x41: out.append(.key(KeyEvent(.up))); i += 2
                case 0x42: out.append(.key(KeyEvent(.down))); i += 2
                case 0x43: out.append(.key(KeyEvent(.right))); i += 2
                case 0x44: out.append(.key(KeyEvent(.left))); i += 2
                case 0x35, 0x36, 0x33:
                    if i + 3 < bytes.count, bytes[i + 3] == 0x7E {
                        out.append(.key(KeyEvent(c == 0x35 ? .pageUp : c == 0x36 ? .pageDown : .other)))
                        i += 3
                    } else {
                        out.append(.key(KeyEvent(.other))); i += 2
                    }
                default:
                    out.append(.key(KeyEvent(.other))); i += 2
                }
            } else if i + 1 < bytes.count {
                out.append(.key(KeyEvent(.other))); i += 1 // Alt+键之类
            } else {
                out.append(.key(KeyEvent(.escape)))
            }
        case 0x21...0x7E:
            let c = Character(UnicodeScalar(b))
            out.append(.key(.char(c, flags: c.isUppercase ? .shift : [])))
        case 0xC0...0xFF:
            let len = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : 2
            let end = min(i + len, bytes.count)
            if let s = String(bytes: bytes[i..<end], encoding: .utf8), let c = s.first { out.append(.key(.char(c))) }
            i = end - 1
        default:
            out.append(.key(KeyEvent(.other)))
        }
        i += 1
    }
    return out
}

private func draw(_ t: Trial) {
    let v = t.client.view
    let width = 72
    var lines: [String] = []
    let mode = v.english ? "英" : "中"
    lines.append("\u{1B}[1m螺壳输入法 · 试用「\(t.typing.manifest.name)」\u{1B}[0m  [\(mode)]")
    lines.append("\u{1B}[2mCtrl-T 切中英（代替单按 Shift） · Ctrl-X 忘掉（代替 Shift+⌫） · Ctrl-R 快捷键引擎 · Ctrl-C 退出\u{1B}[0m")
    lines.append(String(repeating: "─", count: width))
    let docLines = t.client.document.components(separatedBy: "\n").suffix(6)
    var body = Array(docLines)
    if body.isEmpty { body = [""] }
    let marked = v.marked.isEmpty ? "" : "\u{1B}[4m" + v.marked + "\u{1B}[0m"
    body[body.count - 1] += marked + "\u{1B}[7m \u{1B}[0m"
    lines += body
    lines.append(String(repeating: "─", count: width))
    if !v.candidates.isEmpty {
        let items = v.candidates.enumerated().map { i, c -> String in
            let note = c.note.map { "\u{1B}[2m\($0)\u{1B}[22m" } ?? ""
            let item = "\(i + 1).\(c.text)\(note)"
            return i == v.highlighted ? "\u{1B}[7m\(item)\u{1B}[27m" : item
        }
        lines.append(items.joined(separator: "  ") + (v.pageCount > 1 ? "  \u{1B}[2m‹\(v.page + 1)/\(v.pageCount)›\u{1B}[0m" : "")
                     + (v.pending ? "  \u{1B}[2m⋯\u{1B}[0m" : ""))
    } else {
        lines.append("")
    }
    lines.append(v.notice.map { "\u{1B}[33m\($0)\u{1B}[0m" } ?? "")
    for e in t.takeEvents().suffix(4) { lines.append("\u{1B}[2m\(e.prefix(width * 2))\u{1B}[0m") }
    print("\u{1B}[H\u{1B}[2J" + lines.joined(separator: "\r\n"), terminator: "")
    fflush(stdout)
}

private func runInteractive(_ t: Trial) -> Int32 {
    enableRawMode()
    defer { disableRawMode() }
    let watcher = FolderWatcher(dir: t.typing.dir)
    var lastScan = ProcessInfo.processInfo.systemUptime
    var dirty = true
    t.client.onChange = { dirty = true }
    var lastEvents = 0
    while true {
        let now = ProcessInfo.processInfo.systemUptime
        let timeout = t.session.nextDeadline.map { max(0, $0 - now) } ?? 1
        var fds = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: t.wakeFD, events: Int16(POLLIN), revents: 0)]
        _ = poll(&fds, 2, Int32(min(timeout, 1) * 1000) + 1)
        if fds[0].revents & Int16(POLLIN) != 0 {
            var buf = [UInt8](repeating: 0, count: 256)
            let n = read(STDIN_FILENO, &buf, 256)
            if n <= 0 { return 0 }
            for input in decode(Array(buf[0..<n])) {
                switch input {
                case .quit: return 0
                case let .key(e): t.feed(e)
                case .shiftTap: apply(.shiftTap, t)
                case .forget: apply(.forget, t)
                case .hotkey: apply(.hotkey, t)
                }
            }
            dirty = true
        }
        if ProcessInfo.processInfo.systemUptime - lastScan > 0.5 {
            lastScan = ProcessInfo.processInfo.systemUptime
            if watcher.changed() { t.reload() }
        }
        t.service()
        let n = t.takeEvents().count
        if n != lastEvents { lastEvents = n; dirty = true }
        if dirty {
            draw(t)
            dirty = false
        }
    }
}
