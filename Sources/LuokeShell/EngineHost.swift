import Foundation

/// ~/.luoke/ime 下的文件布局（docs/设计.md#文件布局）。
public struct Paths {
    public var root: URL
    /// 螺壳的记忆（luoke-mem）：只对声明了 permissions.memory 的个人化组件放行。缺省是 root 旁边的 mem.db（~/.luoke/mem.db）。
    public var memory: URL

    /// 引擎的临时目录都在这下面。装好的输入法用系统临时目录里的 luoke-ime；别的根目录（命令行版的试用、测试）各用
    /// 自己旁边的一份（<根目录>-tmp），不和装好的输入法共用同一个引擎的临时目录。不能放在根目录里：沙盒不让写壳的目录。
    public var tmpRoot: URL

    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".luoke/ime")

    public init(root: URL = Paths.defaultRoot, memory: URL? = nil) {
        self.root = root
        self.memory = memory ?? root.deletingLastPathComponent().appendingPathComponent("mem.db")
        tmpRoot = root.standardizedFileURL == Paths.defaultRoot.standardizedFileURL
            ? FileManager.default.temporaryDirectory.appendingPathComponent("luoke-ime")
            : root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-tmp")
    }

    public var engines: URL { root.appendingPathComponent("engines") }
    public var settings: URL { root.appendingPathComponent("settings.json") }
    /// 本机的使用计数（Usage），只有次数。
    public var usage: URL { root.appendingPathComponent("usage.json") }
    public var dataRoot: URL { root.appendingPathComponent("data") }
    public var recordsRoot: URL { root.appendingPathComponent("records") }
    public func data(_ id: String) -> URL { dataRoot.appendingPathComponent(id) }
    public func records(_ id: String) -> URL { recordsRoot.appendingPathComponent(id) }
    public func tmp(_ id: String) -> URL {
        tmpRoot.appendingPathComponent(id)
    }

    /// 建好壳的目录，只有自己能进（700）：里面有开发模式的输入记录（原始按键），旁边是螺壳的记忆。
    /// 上一级（~/.luoke）还不存在时也用 700 建出来（luoke-mem 的需求：沙盒里的个人化组件改不了它的权限）；
    /// 已经存在的上一级不动，它不归壳管。壳自己的目录权限松了就收紧。
    public func prepare() {
        let fm = FileManager.default
        let parent = root.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if !fm.fileExists(atPath: root.path) {
            try? fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else if let mode = (try? fm.attributesOfItem(atPath: root.path))?[.posixPermissions] as? Int, mode & 0o077 != 0, !isSymlink(root) {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        }
    }
}

/// 一个引擎：负责启动、通信、崩溃重启和停用，并把消息分发给各个会话的通道。
///
/// 线程：启动、退出处理和往引擎写消息都在自己的串行队列上做，调用方（壳的主线程）从不因引擎读得慢而阻塞；
/// 状态和收件箱由 `cond` 保护。`onEvent` / `onMessage` 在后台线程回调，宿主自己切回主线程。
/// 引擎在独立的进程组里运行，强制结束时整组 SIGKILL，引擎再派生的进程也一起结束。
public final class EngineConnection {
    public enum State: Equatable {
        case stopped
        case running
        case disabled(String)
    }

    public enum Event {
        case started
        case exited(status: Int32, stderr: [String])
        case disabled(reason: String)
        case protocolError(String)
        case stderr(String)
    }

    public let id: String
    public let dir: URL
    public let manifest: Manifest
    public let paths: Paths
    /// 用 Seatbelt 沙盒运行（ADR 0006）。只有命令行版调试时才关。
    public var sandboxed = true
    /// 壳的设置里要交给引擎的选项（比如模糊音），叠在 currentOptions 上面。
    public var shellOptions: [String: JSONValue] = [:]
    /// 沙盒保护哪个壳目录（输入记录、设置、别的引擎的数据）。缺省就是 paths；命令行版的检查把数据放在临时目录，
    /// 但保护的仍是真的 ~/.luoke/ime，免得检查时的沙盒比正式运行宽。
    public var protectedPaths: Paths?
    /// 查找 `run[0]` 用的 PATH；壳用登录 shell 的 PATH，命令行版用当前环境的。
    public var searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    /// 沙盒日志里标识这个引擎的标签（LUOKE[<标签>]）。
    public let sandboxTag: String
    /// 加在所有标签前面。命令行版设成带进程号的前缀：它起的引擎被拦时，正在运行的输入法不会认成自己的引擎。
    public static var sandboxTagPrefix = ""
    /// 开着开发模式时记录往来。
    public var recorder: Recorder?
    /// 快捷键引擎第一次被用到时才启动。
    public var startsLazily = false
    /// 第一次用到时才启动的引擎，崩溃以后也马上重启，不等下一次按键（按下就要录的引擎：等按键时才起，开头的话就丢了）。
    public var restartsAfterCrash = false
    /// 用户同意了这个组件读写记忆（声明了 permissions.memory 还不够，ARCHITECTURE §4）。没同意时沙盒不放行记忆文件、也不给它路径；
    /// 壳把同意记在自己的设置里，引擎读不到也改不了。
    public var memoryGranted = false
    /// 不是随输入法发布的引擎（ADR 0012）：沙盒里不给系统共用的 TemporaryItems（Foundation 原子写的临时副本放在那里，
    /// 别的应用、壳自己正在保存的文件都可能被它抢先改掉）。
    public var thirdParty = false
    /// 数据目录、临时目录、开发模式记录用的名字，缺省是引擎标识。和自带引擎同名的第三方引擎另起一个，
    /// 免得它读写自带那份的数据（审查第 6 条）。
    public var storageID: String?
    public var storage: String { storageID ?? id }
    public var onEvent: ((Event) -> Void)?
    /// 有消息到达或引擎状态变了，宿主应尽快让会话 pump。
    public var onMessage: (() -> Void)?
    /// 引擎发来的转问和（个人化组件的）转问答复：不属于任何会话，交给转问的中转（AskBroker）。
    /// 在读引擎输出的后台线程上回调，带着发出它的那一代进程的编号。
    public var onAsk: ((Ask, Int) -> Void)?
    public var onReply: ((Reply, Int) -> Void)?
    /// 某一代进程退出了（不论是崩溃还是被停止），在引擎自己的队列上回调。
    public var onExit: ((Int) -> Void)?

    public var crashLimit = 3
    public var crashWindow: TimeInterval = 60
    public var exitGrace: TimeInterval = 1

    public var state: State { locked { _state } }
    /// 现在这一代进程的编号：每次（重新）启动加一。转问的答复只发给发问的那一代。
    public var generation: Int { locked { liveGeneration } }
    public var stderrTail: [String] { locked { _stderrTail } }

    private let queue: DispatchQueue
    private let cond = NSCondition()
    // 以下由 cond 保护
    private var _state: State = .stopped
    private var _stderrTail: [String] = []
    private var liveGeneration = 0
    private var pids: [Int: pid_t] = [:] // 代 → 进程（也是进程组号），退出后移除
    private var epoch = 0                 // 引擎退出或停止时加一，叫醒等待中的会话
    private var counter = 0
    private var routes: [Int: ObjectIdentifier] = [:]
    private var channels: [ObjectIdentifier: WeakChannel] = [:]
    // 以下只在 queue 上访问
    private var startedGeneration = 0
    private var stopping: Set<Int> = []
    private var crashes: [TimeInterval] = []
    private var stdinHandle: FileHandle?
    private var readers: [FileHandle] = []

    public init(id: String, dir: URL, manifest: Manifest, paths: Paths = Paths()) {
        self.id = id
        self.dir = dir.standardizedFileURL
        self.manifest = manifest
        self.paths = paths
        sandboxTag = SandboxProfile.tag(for: Self.sandboxTagPrefix + id)
        queue = DispatchQueue(label: "luoke-ime.engine.\(id)")
        signal(SIGPIPE, SIG_IGN)
    }

    /// 从引擎文件夹建立（读 engine.json）。
    public convenience init(dir: URL, paths: Paths = Paths()) throws {
        let manifest = try Manifest.load(from: dir)
        self.init(id: dir.standardizedFileURL.lastPathComponent, dir: dir, manifest: manifest, paths: paths)
    }

    deinit {
        for p in pids.values { Darwin.kill(-p, SIGKILL) }
    }

    private func locked<T>(_ f: () -> T) -> T {
        cond.lock()
        defer { cond.unlock() }
        return f()
    }

    // MARK: - 会话通道

    public func makeChannel() -> EngineChannel {
        let ch = Channel(connection: self)
        locked { channels[ObjectIdentifier(ch)] = WeakChannel(ch) }
        return ch
    }

    private struct WeakChannel {
        weak var channel: Channel?
        init(_ c: Channel) { channel = c }
    }

    /// 这个通道是不是这个连接给出的。
    public func owns(_ channel: EngineChannel?) -> Bool {
        (channel as? Channel)?.connection === self
    }

    final class Channel: EngineChannel {
        let connection: EngineConnection
        var inbox: [EngineMessage] = [] // 由 connection.cond 保护

        init(connection: EngineConnection) { self.connection = connection }

        deinit {
            let id = ObjectIdentifier(self)
            connection.locked { connection.channels[id] = nil }
        }

        var isAvailable: Bool {
            switch connection.state {
            case .running: return true
            case .stopped: return connection.startsLazily
            case .disabled: return false
            }
        }

        func nextID() -> Int { connection.locked { connection.counter += 1; return connection.counter } }

        func send(_ message: ShellMessage) {
            connection.route(message, to: self)
            if connection.startsLazily, connection.state == .stopped {
                if case .start = message { connection.startLazily() }
                if case .arm = message { connection.startLazily() }
            }
            connection.write(message)
        }

        func drain() -> [EngineMessage] {
            connection.locked {
                let out = inbox
                inbox = []
                return out
            }
        }

        func wait(until deadline: TimeInterval) {
            let c = connection.cond
            c.lock()
            defer { c.unlock() }
            let startEpoch = connection.epoch
            while inbox.isEmpty, connection.epoch == startEpoch {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 || !c.wait(until: Date(timeIntervalSinceNow: remaining)) { break }
            }
        }

        func reportHang() { connection.hang() }
    }

    private func route(_ message: ShellMessage, to channel: Channel) {
        let id: Int
        switch message {
        case let .query(i, _, _, _), let .start(i, _, _): id = i
        default: return
        }
        locked {
            routes[id] = ObjectIdentifier(channel)
            if routes.count > 4096 { routes = routes.filter { $0.key > id - 1024 } }
        }
    }

    // MARK: - 启停

    /// 启动引擎。不能在引擎自己的队列上调用。
    public func start() throws {
        try queue.sync { try _start() }
    }

    private func startLazily() {
        queue.sync {
            guard case .stopped = locked({ _state }) else { return }
            do { try _start() } catch { disable("无法启动：\(error)") }
        }
    }

    /// 停用后用户手动重新启用。
    public func enable() throws {
        try queue.sync {
            crashes = []
            locked { if case .disabled = _state { _state = .stopped } }
            try _start()
        }
    }

    /// 正常停止：关闭标准输入，宽限期后整组强制结束。
    public func stop() {
        queue.sync { _stop() }
    }

    /// 停止并等待退出：返回引擎是否在宽限期内自己退出了（没有就整组强制结束）。
    @discardableResult
    public func stopAndWait(timeout: TimeInterval) -> Bool {
        let gen: Int? = queue.sync {
            guard locked({ pids[startedGeneration] }) != nil else { return nil }
            let g = startedGeneration
            _stop()
            return g
        }
        guard let gen else { return true }
        func alive() -> pid_t? { locked { pids[gen] } }
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while alive() != nil, ProcessInfo.processInfo.systemUptime < end { usleep(2000) }
        guard let p = alive() else { return true }
        Darwin.kill(-p, SIGKILL)
        let hard = ProcessInfo.processInfo.systemUptime + 0.5
        while alive() != nil, ProcessInfo.processInfo.systemUptime < hard { usleep(2000) }
        return false
    }

    /// 卡死：整组强制结束，按崩溃处理（会自动重启，计入停用次数）。
    func hang() {
        locked {
            if let p = pids[liveGeneration] { Darwin.kill(-p, SIGKILL) }
        }
    }

    private func _start() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        if case .running = locked({ _state }) { return }
        startedGeneration += 1
        let gen = startedGeneration
        locked { liveGeneration = gen }

        let exe = try resolveExecutable()
        paths.prepare()
        let data = paths.data(storage), tmp = paths.tmp(storage)
        for d in [data, tmp] {
            // 引擎能把自己的数据目录、临时目录换成符号链接；沙盒不跟随它（见 SandboxProfile.realParent），这里直接拒绝启动并说明
            if isSymlink(d) { throw EngineError("\(d.path) 被换成了符号链接，为安全起见不启动；删掉这个链接后重新启用") }
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }

        var argv: [String]
        if sandboxed {
            argv = ["/usr/bin/sandbox-exec"]
                + SandboxProfile.arguments(manifest: manifest, tag: sandboxTag, engineDir: dir, dataDir: data, tmpDir: tmp,
                                           paths: protectedPaths ?? paths, memory: memoryGranted ? paths.memory : nil,
                                           sharedTemporaryItems: !thirdParty)
                + [exe.path]
        } else {
            argv = [exe.path]
        }
        if manifest.run[0] == Self.luokePython { argv += Self.luokePythonFlags }
        argv += manifest.run.dropFirst()
        var env: [String: String] = [
            "PATH": searchPath,
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": tmp.path + "/",
            "LANG": "en_US.UTF-8",
            "PYTHONUNBUFFERED": "1",
            "PYTHONPYCACHEPREFIX": data.appendingPathComponent("pycache").path, // 字节码缓存落在自己的数据目录
            "LUOKE_IME_DATA": data.path,
            "LUOKE_IME_PROTOCOL": String(protocolVersion),
        ]
        if let user = ProcessInfo.processInfo.environment["USER"] { env["USER"] = user }
        if manifest.permissions.memory, memoryGranted { env["LUOKE_IME_MEMORY"] = paths.memory.path }

        let child = try Spawn.run(argv: argv, env: env, cwd: dir.path)
        let stdinHandle = FileHandle(fileDescriptor: child.stdin, closeOnDealloc: true)
        let out = FileHandle(fileDescriptor: child.stdout, closeOnDealloc: true)
        let err = FileHandle(fileDescriptor: child.stderr, closeOnDealloc: true)
        out.readabilityHandler = lineReader { [weak self] line in self?.received(line, generation: gen) }
        err.readabilityHandler = lineReader { [weak self] line in self?.receivedStderr(line) }
        self.stdinHandle = stdinHandle
        readers = [out, err]

        // hello 必须是引擎收到的第一条：在发布"运行中"之前、在本队列上同步写。
        writeNow(.hello(options: currentOptions(), dataDir: data.path))
        locked {
            pids[gen] = child.pid
            _state = .running
        }
        Thread.detachNewThread { [weak self] in
            // 先等它退出但不回收（WNOWAIT），这样它的进程号还占着、不会被别的进程复用；
            // 结束整个进程组（引擎派生、自己没收拾的子进程），再回收
            var info = siginfo_t()
            while waitid(P_PID, id_t(child.pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
            Darwin.kill(-child.pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(child.pid, &status, 0) == -1, errno == EINTR {}
            self?.queue.async { self?.exited(generation: gen, status: status) }
        }
        onEvent?(.started)
        onMessage?()
    }

    private func _stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        let gen = startedGeneration
        guard locked({ pids[gen] }) != nil else { return }
        stopping.insert(gen)
        try? stdinHandle?.close()
        stdinHandle = nil
        locked {
            if case .running = _state { _state = .stopped }
            epoch += 1
            cond.broadcast()
        }
        queue.asyncAfter(deadline: .now() + exitGrace) { [weak self] in
            guard let self, let p = self.locked({ self.pids[gen] }) else { return }
            Darwin.kill(-p, SIGKILL)
        }
    }

    private func disable(_ reason: String) {
        locked {
            _state = .disabled(reason)
            epoch += 1
            cond.broadcast()
        }
        onEvent?(.disabled(reason: reason))
        onMessage?()
    }

    private func exited(generation gen: Int, status raw: Int32) {
        dispatchPrecondition(condition: .onQueue(queue))
        // waitpid 的状态：低 7 位是终止信号，否则高 8 位是退出码
        let status: Int32 = raw & 0x7F == 0 ? (raw >> 8) & 0xFF : 128 + (raw & 0x7F)
        let intentional = stopping.remove(gen) != nil
        let current = gen == startedGeneration
        let crashed = current && !intentional
        if crashed {
            let now = ProcessInfo.processInfo.systemUptime
            crashes = crashes.filter { now - $0 < crashWindow } + [now]
        }
        var tail: [String] = []
        var disabledReason: String?
        // 先改好状态再叫醒等待中的会话：被叫醒的读到的 isAvailable 已经是退出以后的（原来先叫醒、后改状态，
        // 偶尔读到旧的 running，luokelabs/luoke-ime#4）
        locked {
            pids[gen] = nil
            tail = _stderrTail
            if crashed {
                if crashes.count >= crashLimit {
                    let last = tail.suffix(5).joined(separator: "\n")
                    let reason = "\(Int(crashWindow)) 秒内崩溃了 \(crashes.count) 次" + (last.isEmpty ? "" : "，最后的错误输出：\n\(last)")
                    _state = .disabled(reason)
                    disabledReason = reason
                } else {
                    _state = .stopped
                }
            }
            if current { epoch += 1 }
            cond.broadcast()
        }
        onExit?(gen)
        guard crashed else { return }
        try? stdinHandle?.close()
        stdinHandle = nil
        onEvent?(.exited(status: status, stderr: tail))
        if let disabledReason {
            onEvent?(.disabled(reason: disabledReason))
            onMessage?()
            return
        }
        onMessage?()
        if !startsLazily || restartsAfterCrash {
            do { try _start() } catch { disable("重启失败：\(error)") }
        }
    }

    // MARK: - 读写

    /// 往引擎写一条消息。不阻塞调用方：排进引擎的队列，按顺序写。
    func write(_ message: ShellMessage) {
        let line = message.line
        queue.async { [weak self] in self?.writeLine(line) }
    }

    /// 只发给第 `generation` 代进程：它已经退出（重启了）就不发。转问的答复用它，免得发给不认识这个号的新进程。
    public func send(_ message: ShellMessage, toGeneration generation: Int) {
        let line = message.line
        queue.async { [weak self] in
            guard let self, self.startedGeneration == generation, self.locked({ self.pids[generation] }) != nil else { return }
            self.writeLine(line)
        }
    }

    /// 往引擎写一条消息（个人化组件收上屏、转问时用；会话通过自己的通道发）。
    public func send(_ message: ShellMessage) { write(message) }

    /// 发一行任意 JSON（命令行版的检查用它发不认识的消息类型）。
    public func sendRaw(_ json: [String: Any]) {
        let line = JSONLine.encode(json)
        queue.async { [weak self] in self?.writeLine(line) }
    }

    private func writeNow(_ message: ShellMessage) { writeLine(message.line) }

    private func writeLine(_ line: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let h = stdinHandle else { return }
        recorder?.record(.toEngine, line)
        try? h.write(contentsOf: Data((line + "\n").utf8))
    }

    private func received(_ line: String, generation gen: Int) {
        recorder?.record(.fromEngine, line)
        let message: EngineMessage
        do {
            message = try EngineMessage.parse(line)
        } catch {
            onEvent?(.protocolError(String(describing: error)))
            return
        }
        switch message {
        case let .ask(a): onAsk?(a, gen); return
        case let .reply(r): onReply?(r, gen); return
        default: break
        }
        guard let id = message.id else { return } // 不认识的类型按协议忽略
        let delivered: Bool = locked {
            guard gen == liveGeneration, let key = routes[id], let ch = channels[key]?.channel else { return false }
            ch.inbox.append(message)
            cond.broadcast()
            return true
        }
        if delivered { onMessage?() }
    }

    private func receivedStderr(_ line: String) {
        locked {
            _stderrTail.append(line)
            if _stderrTail.count > 200 { _stderrTail.removeFirst(_stderrTail.count - 200) }
        }
        recorder?.record(.stderr, line)
        onEvent?(.stderr(line))
    }

    private func lineReader(_ onLine: @escaping (String) -> Void) -> (FileHandle) -> Void {
        var buffer = Data()
        return { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                var line = String(decoding: lineData, as: UTF8.self)
                if line.hasSuffix("\r") { line.removeLast() }
                if !line.isEmpty { onLine(line) }
            }
        }
    }

    // MARK: - 辅助

    /// `run[0]` 写 luoke-python：用主控（螺壳.app，旧版叫螺壳主控.app；bundle id ai.luoke.core）带的 Python。luoke-core V1 §8 的约定：
    /// 路径和 bundle id 不变、3.12 的完整标准库、同一个 Team 签名；主控是装输入法的那一方，正式的装法里一定在。
    /// 开发机上找不到主控时用 PATH 里的 python3。参数前面加 -B -E -s -u：不写字节码（往主控包里写会弄坏签名）、
    /// 不读用户的 PYTHON* 环境变量和用户自己的 site-packages、输出不缓冲（-E 让 PYTHONUNBUFFERED 不起作用）。
    public static let luokePython = "luoke-python"
    static let luokePythonFlags = ["-B", "-E", "-s", "-u"]

    /// 主控带的 Python 现在是哪一个文件（inode）：主控换版本时整个 .app 被换掉，跑在旧 Python 上的组件要重启。
    public static func hubPythonIdentity() -> Int? {
        guard let py = hubPython() else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: py.path))?[.systemFileNumber] as? Int
    }

    static func hubPython() -> URL? {
        let fm = FileManager.default
        // 主控改过名（旧版装在 螺壳主控.app，现在是 螺壳.app，bundle id 不变）：新名字先找，旧名字也认。
        // 现在默认装在 /Applications：两处都有时用 /Applications 那份，和主控自己（Installer.installed）、邮件助手一致
        // （老用户把新包拖进 /Applications，~/Applications 里的旧主控还在）。
        // 不按 bundle id 问 LaunchServices：它可能认到主控回滚用的旧包、废纸篓里的旧包（luokelabs/luoke-ime#15）
        let roots = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for app in roots.flatMap({ r in ["螺壳.app", "螺壳主控.app"].map { r.appendingPathComponent($0) } }) {
            guard Bundle(url: app)?.bundleIdentifier == "ai.luoke.core" else { continue }
            // bin/python3 是指向同目录 python3.12 的符号链接：先解开再起
            let py = app.appendingPathComponent("Contents/Resources/python/bin/python3").resolvingSymlinksInPath()
            if fm.isExecutableFile(atPath: py.path) { return py }
        }
        return nil
    }

    private func resolveExecutable() throws -> URL {
        var name = manifest.run[0]
        if name == Self.luokePython {
            if let py = Self.hubPython() { return py }
            name = "python3"
        }
        if name.contains("/") {
            let url = name.hasPrefix("/") ? URL(fileURLWithPath: name) : dir.appendingPathComponent(name)
            guard FileManager.default.isExecutableFile(atPath: url.path) else { throw EngineError("\(url.path) 不存在或不可执行") }
            return url.standardizedFileURL
        }
        for d in searchPath.split(separator: ":") {
            let url = URL(fileURLWithPath: String(d)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw EngineError("在 PATH 里找不到 \(name)（PATH=\(searchPath)）")
    }

    /// 选项值：引擎说明里的默认值，叠上引擎数据目录里 options.json 的值。
    public func currentOptions() -> JSONValue {
        var merged: [String: JSONValue] = [:]
        if case let .object(d) = manifest.optionDefaults { merged = d }
        let file = paths.data(storage).appendingPathComponent("options.json")
        if let data = readRegularFile(file), let obj = try? JSONSerialization.jsonObject(with: data),
           case let .object(user) = JSONValue(obj) {
            merged.merge(user) { _, new in new }
        }
        merged.merge(shellOptions) { _, new in new }
        return .object(merged)
    }
}

/// 读一个普通文件，不跟随符号链接。引擎数据目录里的文件由引擎掌控，壳在沙盒外读它时，
/// 跟随链接就等于替引擎读了它读不到的文件（比如壳的设置、别的引擎的数据）。
func readRegularFile(_ url: URL, limit: Int = 1 << 20) -> Data? {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { return nil }
    let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= limit else { return nil }
    return try? h.readToEnd()
}

func isSymlink(_ url: URL) -> Bool {
    var st = stat()
    return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
}

/// 用 posix_spawn 启动子进程：放进新的进程组，只继承标准输入输出错误，SIGPIPE 恢复默认。
enum Spawn {
    struct Child {
        var pid: pid_t
        var stdin: Int32
        var stdout: Int32
        var stderr: Int32
    }

    static func run(argv: [String], env: [String: String], cwd: String) throws -> Child {
        var pin: [Int32] = [0, 0], pout: [Int32] = [0, 0], perr: [Int32] = [0, 0]
        guard pipe(&pin) == 0, pipe(&pout) == 0, pipe(&perr) == 0 else { throw EngineError("创建管道失败：\(String(cString: strerror(errno)))") }
        for fd in [pin[1], pout[0], perr[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_adddup2(&fa, pin[0], 0)
        posix_spawn_file_actions_adddup2(&fa, pout[1], 1)
        posix_spawn_file_actions_adddup2(&fa, perr[1], 2)
        posix_spawn_file_actions_addchdir_np(&fa, cwd)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)

        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &fa, &attr, cArgs, cEnv)
        for fd in [pin[0], pout[1], perr[1]] { close(fd) }
        guard rc == 0 else {
            for fd in [pin[1], pout[0], perr[0]] { close(fd) }
            throw EngineError("无法启动 \(argv[0])：\(String(cString: strerror(rc)))")
        }
        return Child(pid: pid, stdin: pin[1], stdout: pout[0], stderr: perr[0])
    }
}

public struct EngineError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// 开发模式的输入记录：每行一个 JSON。只留最近 keepDays 天的（每开一份新的时删掉更早的）；
/// muted 时（"不记录"的应用、暂停记录、安全输入）什么都不写，连引擎的收发。
public final class Recorder {
    public enum Kind: String { case toEngine = "to_engine", fromEngine = "from_engine", stderr, key, context }
    public static let keepDays = 7

    private var handle: FileHandle
    private let start = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var _muted = false
    private let directory: URL
    private var day: String
    /// 现在写的这一份。每天换一份新的（同一份不会一直追加，过了 7 天能整份删掉）。
    public private(set) var url: URL

    private static func names(_ date: Date) -> (day: String, file: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let s = f.string(from: date)
        return (String(s.prefix(8)), s + ".jsonl")
    }

    public var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _muted }
        set { lock.lock(); _muted = newValue; lock.unlock() }
    }

    public init(directory: URL, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.sweep(directory, before: now.addingTimeInterval(-Double(Self.keepDays) * 86400))
        self.directory = directory
        let n = Self.names(now)
        day = n.day
        url = directory.appendingPathComponent(n.file)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    /// 读回一份输入记录：每行 (时间, 种类, 数据)。
    public static func read(_ url: URL) throws -> [(t: TimeInterval, kind: Kind, data: Any)] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let t = obj["t"] as? Double, let k = (obj["kind"] as? String).flatMap(Kind.init(rawValue:)), let d = obj["data"]
            else { return nil }
            return (t, k, d)
        }
    }

    public func record(_ kind: Kind, _ payload: Any) {
        guard !muted else { return }
        let t = ProcessInfo.processInfo.systemUptime - start
        let line = JSONLine.encode(["t": (t * 1000).rounded() / 1000, "kind": kind.rawValue, "data": payload]) + "\n"
        lock.lock()
        let n = Self.names(Date())
        if n.day != day, FileManager.default.createFile(atPath: directory.appendingPathComponent(n.file).path, contents: nil),
           let h = try? FileHandle(forWritingTo: directory.appendingPathComponent(n.file)) {
            try? handle.close()
            handle = h
            day = n.day
            url = directory.appendingPathComponent(n.file)
        }
        try? handle.write(contentsOf: Data(line.utf8))
        lock.unlock()
    }

    /// 所有引擎的记录（records/<引擎>/）里早于 7 天的都删掉，空了的目录也删（引擎删掉了、开发模式关了以后留下的）。
    /// 壳启动时和每小时调一次。
    public static func sweepAll(_ root: URL, now: Date = Date()) {
        let fm = FileManager.default
        let before = now.addingTimeInterval(-Double(keepDays) * 86400)
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            sweep(dir, before: before)
            if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
        }
    }

    /// 删掉目录里早于 date 的记录（按文件的修改时间）。
    static func sweep(_ directory: URL, before date: Date) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for f in files where f.pathExtension == "jsonl" {
            if let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m < date {
                try? fm.removeItem(at: f)
            }
        }
    }
}
