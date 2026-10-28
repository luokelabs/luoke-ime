import Foundation
import Testing
@testable import LuokeShell

/// 用真实子进程跑仓库里的最小示例引擎。
@Suite(.serialized) struct 引擎宿主 {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let minimal = repo.appendingPathComponent("examples/minimal")

    static func tempPaths() -> Paths {
        Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("luoke-ime-tests-\(UUID().uuidString)"))
    }

    /// 真实时间里推进：等消息、处理计时，直到条件满足或超时。
    static func run(_ session: Session, _ channel: EngineChannel, timeout: TimeInterval = 5, until done: () -> Bool) -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while !done() {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= end { return false }
            channel.wait(until: min(session.nextDeadline ?? now + 0.02, now + 0.02, end))
            session.tick()
        }
        return true
    }

    @Test(arguments: [true, false])
    func 最小示例引擎能打字(sandboxed: Bool) throws {
        let conn = try EngineConnection(dir: Self.minimal, paths: Self.tempPaths())
        conn.sandboxed = sandboxed
        try conn.start()
        defer { conn.stop() }
        let client = FakeClient()
        let session = Session(client: client)
        let channel = conn.makeChannel()
        session.typing = TypingEngine(manifest: conn.manifest, channel: channel)
        for c in "nihaowo" { session.handle(.char(c)) }
        #expect(Self.run(session, channel) { client.view.candidates.first?.text == "你好" })
        session.handle(.char("1"))
        #expect(Self.run(session, channel) { client.view.candidates.first?.text == "我" })
        session.handle(KeyEvent(.space))
        #expect(client.document == "你好我")
    }

    @Test func 崩溃后自动重启_反复崩溃就停用() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crashy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"protocol":1,"name":"会崩","kind":"typing","run":["/bin/sh","-c","exit 3"],"input_keys":"a"}"#
            .write(to: dir.appendingPathComponent("engine.json"), atomically: true, encoding: .utf8)
        let conn = try EngineConnection(dir: dir, paths: Self.tempPaths())
        conn.sandboxed = false
        let disabled = DispatchSemaphore(value: 0)
        var starts = 0
        conn.onEvent = { e in
            switch e {
            case .started: starts += 1
            case .disabled: disabled.signal()
            default: break
            }
        }
        try conn.start()
        #expect(disabled.wait(timeout: .now() + 5) == .success)
        #expect(starts == 3)
        guard case let .disabled(reason) = conn.state else { Issue.record("没有停用"); return }
        #expect(reason.contains("崩溃了 3 次"))
    }

    @Test func 卡死时强制结束并重启() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"protocol":1,"name":"不答","kind":"typing","run":["/bin/cat"],"input_keys":"a"}"#
            .write(to: dir.appendingPathComponent("engine.json"), atomically: true, encoding: .utf8)
        let conn = try EngineConnection(dir: dir, paths: Self.tempPaths())
        conn.sandboxed = false
        let restarted = DispatchSemaphore(value: 0)
        var starts = 0
        conn.onEvent = { if case .started = $0 { starts += 1; if starts == 2 { restarted.signal() } } }
        try conn.start()
        defer { conn.stop() }
        let channel = conn.makeChannel()
        channel.reportHang()
        #expect(restarted.wait(timeout: .now() + 5) == .success)
        #expect(conn.state == .running)
    }

    @Test func 沙盒里引擎文件夹只读_数据目录可写_不能联网() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = #"""
        import json, os, socket, sys
        def can(f):
            try: f(); return True
            except Exception: return False
        def write(path):
            with open(path, "w") as fh: fh.write("x")
        def net():
            socket.create_connection(("1.1.1.1", 443), timeout=2).close()
        r = {"engine_dir": can(lambda: write("probe.txt")),
             "data_dir": can(lambda: write(os.path.join(os.environ["LUOKE_IME_DATA"], "probe.txt"))),
             "tmp": can(lambda: write(os.path.join(os.environ["TMPDIR"], "probe.txt"))),
             "network": can(net)}
        for line in sys.stdin:
            m = json.loads(line)
            if m.get("type") == "query":
                print(json.dumps({"type": "answer", "id": m["id"], "candidates": [{"text": json.dumps(r, sort_keys=True), "consume": 1}]}), flush=True)
        """#
        try script.write(to: dir.appendingPathComponent("engine.py"), atomically: true, encoding: .utf8)
        try #"{"protocol":1,"name":"探针","kind":"typing","run":["/usr/bin/python3","engine.py"],"input_keys":"a"}"#
            .write(to: dir.appendingPathComponent("engine.json"), atomically: true, encoding: .utf8)
        let conn = try EngineConnection(dir: dir, paths: Self.tempPaths())
        try conn.start()
        defer { conn.stop() }
        let client = FakeClient()
        let session = Session(client: client)
        let channel = conn.makeChannel()
        session.typing = TypingEngine(manifest: conn.manifest, channel: channel)
        session.handle(.char("a"))
        #expect(Self.run(session, channel, timeout: 10) { !client.view.candidates.isEmpty })
        let result = client.view.candidates.first?.text ?? ""
        #expect(result == #"{"data_dir": true, "engine_dir": false, "network": false, "tmp": true}"#)
    }

    static func engine(_ name: String, manifest: String, files: [String: String] = [:]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifest.write(to: dir.appendingPathComponent("engine.json"), atomically: true, encoding: .utf8)
        for (f, content) in files {
            let url = dir.appendingPathComponent(f)
            try content.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return dir
    }

    @Test func 引擎读得慢也不会卡住打字_卡死检测照常触发() throws {
        let dir = try Self.engine("slow", manifest: #"{"protocol":1,"name":"慢","kind":"typing","run":["/bin/sh","-c","sleep 5; cat >/dev/null"],"input_keys":"ab","context":2000}"#)
        let conn = try EngineConnection(dir: dir, paths: Self.tempPaths())
        conn.sandboxed = false
        var starts = 0
        conn.onEvent = { if case .started = $0 { starts += 1 } }
        try conn.start()
        defer { conn.stopAndWait(timeout: 1) }
        let client = FakeClient()
        client.document = String(repeating: "长", count: 2000)
        let session = Session(client: client)
        let channel = conn.makeChannel()
        session.typing = TypingEngine(manifest: conn.manifest, channel: channel)
        var worst: TimeInterval = 0
        for _ in 0..<40 {
            let t = ProcessInfo.processInfo.systemUptime
            session.handle(.char("a"))
            worst = max(worst, ProcessInfo.processInfo.systemUptime - t)
        }
        #expect(worst < 0.05)
        // 1 秒没答复：报告卡死，引擎被整组结束并重启
        #expect(Self.run(session, channel, timeout: 3) { starts >= 2 })
    }

    @Test func 停止时引擎派生的子进程也一起结束() throws {
        let marker = "luoke-test-\(UUID().uuidString.prefix(8))"
        let dir = try Self.engine("tree", manifest: #"{"protocol":1,"name":"树","kind":"typing","run":["./run.sh"],"input_keys":"ab"}"#,
                                  files: ["run.sh": "#!/bin/sh\ntrap '' TERM\n/bin/sh -c 'sleep 600; : \(marker)' &\nwhile true; do sleep 1; done\n"])
        let conn = try EngineConnection(dir: dir, paths: Self.tempPaths())
        conn.sandboxed = false
        try conn.start()
        func count() -> Int {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-f", marker]
            let out = Pipe()
            p.standardOutput = out
            try? p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").count
        }
        let end = ProcessInfo.processInfo.systemUptime + 3
        while count() == 0, ProcessInfo.processInfo.systemUptime < end { usleep(50_000) }
        #expect(count() >= 1)
        let clean = conn.stopAndWait(timeout: 0.5) // 引擎不理会输入结束，也忽略 SIGTERM
        #expect(!clean)
        usleep(200_000)
        #expect(count() == 0)
    }

    @Test func 引擎退出时等待中的会话立刻被叫醒() throws {
        let dir = try Self.engine("dies", manifest: #"{"protocol":1,"name":"会退","kind":"typing","run":["/bin/sh","-c","sleep 0.3"],"input_keys":"ab"}"#)
        let conn = try EngineConnection(dir: dir, paths: Self.tempPaths())
        conn.sandboxed = false
        conn.crashLimit = 1
        try conn.start()
        let channel = conn.makeChannel()
        let t = ProcessInfo.processInfo.systemUptime
        channel.wait(until: t + 3)
        #expect(ProcessInfo.processInfo.systemUptime - t < 1)
        #expect(!channel.isAvailable)
    }

    /// luokelabs/luoke-ime#4：原来先叫醒等待的会话、后改状态，被叫醒的偶尔读到旧的 running。onExit 在叫醒之后、
    /// 原来改状态之前跑：让它慢 0.2 秒，把这段窗口撑大，原来的顺序每次都会读错。
    @Test func 引擎退出时叫醒之前状态已经改好() throws {
        let dir = try Self.engine("dies-slow", manifest: #"{"protocol":1,"name":"会退","kind":"typing","run":["/bin/sh","-c","sleep 0.2"],"input_keys":"ab"}"#)
        let conn = try EngineConnection(dir: dir, paths: Self.tempPaths())
        conn.sandboxed = false
        conn.crashLimit = 1
        conn.onExit = { _ in usleep(200_000) }
        try conn.start()
        let channel = conn.makeChannel()
        channel.wait(until: ProcessInfo.processInfo.systemUptime + 3)
        #expect(!channel.isAvailable)
        guard case .disabled = conn.state else { Issue.record("退出后应该是停用：\(conn.state)"); return }
    }

    @Test func 沙盒里读不到输入记录和别的引擎的数据_也写不了壳的目录() throws {
        let paths = Self.tempPaths()
        for d in [paths.records("other"), paths.data("other")] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try "秘密".write(to: d.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        }
        let script = #"""
        import json, os, sys
        root = sys.argv[1]
        def can(f):
            try: f(); return True
            except Exception: return False
        def read(p): open(p).read()
        def write(p):
            with open(p, "w") as fh: fh.write("x")
        r = {"records": can(lambda: read(os.path.join(root, "records/other/x.txt"))),
             "other_data": can(lambda: read(os.path.join(root, "data/other/x.txt"))),
             "own_data": can(lambda: write(os.path.join(os.environ["LUOKE_IME_DATA"], "y.txt"))) and can(lambda: read(os.path.join(os.environ["LUOKE_IME_DATA"], "y.txt"))),
             "settings": can(lambda: write(os.path.join(root, "settings.json")))}
        for line in sys.stdin:
            m = json.loads(line)
            if m.get("type") == "query":
                print(json.dumps({"type": "answer", "id": m["id"], "candidates": [{"text": json.dumps(r, sort_keys=True), "consume": 1}]}), flush=True)
        """#
        let manifest = #"{"protocol":1,"name":"探针","kind":"typing","run":["/usr/bin/python3","engine.py","\#(paths.root.path)"],"input_keys":"a"}"#
        let dir = try Self.engine("probe2", manifest: manifest, files: ["engine.py": script])
        let conn = EngineConnection(id: "probe2", dir: dir, manifest: try Manifest.load(from: dir), paths: paths)
        try conn.start()
        defer { conn.stopAndWait(timeout: 1) }
        let client = FakeClient()
        let session = Session(client: client)
        let channel = conn.makeChannel()
        session.typing = TypingEngine(manifest: conn.manifest, channel: channel)
        session.handle(.char("a"))
        #expect(Self.run(session, channel, timeout: 10) { !client.view.candidates.isEmpty })
        #expect(client.view.candidates.first?.text == #"{"other_data": false, "own_data": true, "records": false, "settings": false}"#)
    }
}


@Suite struct 沙盒挡住钥匙和凭据 {
    /// luokelabs/luoke-ime#6：读不限，但钥匙、凭据、浏览器数据、shell 历史不给读。用临时的家目录，不碰真的。
    @Test func 读不到家目录下的钥匙和历史_别的照常能读() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("luoke-ime-tests-home-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let files = [".ssh/id_ed25519", ".aws/credentials", ".zsh_history", "Library/Keychains/login.keychain-db",
                     "Library/Application Support/Google/Chrome/Default/Cookies", ".claude/.credentials.json",
                     "Library/Group Containers/x/data", ".python_history", "notes.txt"]
        for f in files {
            let u = home.appendingPathComponent(f)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "秘密".write(to: u, atomically: true, encoding: .utf8)
        }
        let paths = 引擎宿主.tempPaths()
        let data = paths.data("probe"), tmp = paths.tmp("probe")
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let manifest = try Manifest.parse(Data(#"{"protocol":1,"name":"x","kind":"typing","run":["x"],"input_keys":"a"}"#.utf8))
        let args = SandboxProfile.arguments(manifest: manifest, tag: "t", engineDir: 引擎宿主.minimal, dataDir: data, tmpDir: tmp,
                                            paths: paths, home: home)
        func readable(_ f: String) throws -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            p.arguments = args + ["/bin/cat", home.appendingPathComponent(f).path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
        for f in files.dropLast() { #expect(try !readable(f), "\(f) 不该读得到") }
        #expect(try readable("notes.txt"))
        // 文件系统不分大小写：换个大小写也读不到
        #expect(try !readable(".SSH/id_ed25519"))
        #expect(try !readable("Library/KEYCHAINS/login.keychain-db"))
    }
}

@Suite struct 沙盒不许建符号链接 {
    /// 在自己的数据目录里也建不了链接；普通文件照常能写。
    @Test func 数据目录里建不了链接_能写文件() throws {
        let fm = FileManager.default
        let paths = 引擎宿主.tempPaths()
        let data = paths.data("probe"), tmp = paths.tmp("probe")
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let manifest = try Manifest.parse(Data(#"{"protocol":1,"name":"x","kind":"typing","run":["x"],"input_keys":"a"}"#.utf8))
        let args = SandboxProfile.arguments(manifest: manifest, tag: "t", engineDir: 引擎宿主.minimal, dataDir: data, tmpDir: tmp, paths: paths)
        func run(_ cmd: String) throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            p.arguments = args + ["/bin/sh", "-c", cmd]
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        #expect(try run("echo x > '\(data.path)/f'") == 0)
        #expect(try run("ln -s /etc/hosts '\(data.path)/mem.db-wal'") != 0)
        #expect(!fm.fileExists(atPath: data.appendingPathComponent("mem.db-wal").path))
    }
}

@Suite struct 第三方引擎 {
    static func manifest(_ extra: String = "", kind: String = "typing") throws -> Manifest {
        let keys = kind == "typing" ? #","input_keys":"a""# : ""
        return try Manifest.parse(Data(#"{"protocol":1,"name":"x","kind":"\#(kind)","run":["x"]\#(keys)\#(extra)}"#.utf8))
    }

    @Test func 不许联网_不许GPU_不许额外的写入位置() throws {
        #expect(ThirdParty.refusal(try Self.manifest()) == nil)
        #expect(ThirdParty.refusal(try Self.manifest(#","permissions":{"network":"local","local_ports":[8080]}"#))?.contains("联网") == true)
        #expect(ThirdParty.refusal(try Self.manifest(#","permissions":{"network":"any"}"#))?.contains("联网") == true)
        #expect(ThirdParty.refusal(try Self.manifest(#","permissions":{"gpu":true}"#))?.contains("GPU") == true)
        #expect(ThirdParty.refusal(try Self.manifest(#","permissions":{"write":["~/Documents/notes"]}"#))?.contains("write") == true)
        #expect(ThirdParty.refusal(try Self.manifest(#","permissions":{"microphone":true}"#)) == nil) // 麦克风照常能声明，启用时列出来
    }

    @Test func 指纹只看和权限有关的内容() {
        func fp(_ s: String) -> String? { ThirdParty.fingerprint(engineJSON: Data(s.utf8)) }
        let base = #"{"protocol":1,"name":"x","kind":"typing","run":["./e"],"input_keys":"a","context":20}"#
        let optioned = #"{"protocol":1,"name":"x","kind":"typing","run":["./e"],"input_keys":"a","context":20,"options":{"data":{"k":1}},"punctuation":{}}"#
        let renamed = #"{"protocol":1,"name":"小鹤双拼","kind":"typing","run":["./e"],"input_keys":"a","context":20}"#
        let moreContext = #"{"protocol":1,"name":"x","kind":"typing","run":["./e"],"input_keys":"a","context":200}"#
        let mic = #"{"protocol":1,"name":"x","kind":"typing","run":["./e"],"input_keys":"a","context":20,"permissions":{"microphone":true}}"#
        let otherRun = #"{"protocol":1,"name":"x","kind":"typing","run":["./f"],"input_keys":"a","context":20}"#
        #expect(fp(base) != nil)
        #expect(fp(base) == fp(optioned))  // 改选项、标点表不用重新确认
        #expect(fp(base) != fp(renamed))   // 改名字要（免得冒充自带引擎）
        #expect(fp(base) != fp(moreContext))
        #expect(fp(base) != fp(mic))
        #expect(fp(base) != fp(otherRun))
        #expect(fp("不是 JSON") == nil)
    }

    @Test func 确认框写明能做什么_也写明不能联网() throws {
        let lines = ThirdParty.describe(try Self.manifest(#","context":50,"feedback":true,"permissions":{"microphone":true}"#))
        #expect(lines.contains { $0.contains("每一个键") })
        #expect(lines.contains { $0.contains("50 个字") })
        #expect(lines.contains { $0.contains("麦克风") })
        #expect(lines.last == "不能联网，只能写它自己的数据目录")
    }

    @Test func 确认过的引擎存在设置里() throws {
        var c = ShellConfig()
        c.approvedEngines["myime"] = "abc"
        let back = 设置.parse(String(data: try JSONSerialization.data(withJSONObject: c.json), encoding: .utf8)!)
        #expect(back.approvedEngines == ["myime": "abc"])
    }
}

@Suite(.serialized) struct 沙盒拦截报告 {
    @Test func 解析日志里的拒绝() {
        let d = SandboxDenial.parse(eventMessage: "Sandbox: Python(57698) deny(1) file-write-create /Users/me/x/y\nLUOKE[flypy] write")
        #expect(d?.engine == "flypy")
        #expect(d?.process == "Python")
        #expect(d?.pid == 57698)
        #expect(d?.operation == "file-write-create")
        #expect(d?.detail == "/Users/me/x/y")
        #expect(d?.category == "write")
        #expect(d?.severity == .hard)
        #expect(d?.suggestion.contains("permissions.write 里加入 /Users/me/x") == true)
        let dup = SandboxDenial.parse(eventMessage: "59 duplicate reports for Sandbox: curl(1) deny(1) network-outbound *:443\nLUOKE[a-1f] network")
        #expect(dup?.duplicates == 59)
        #expect(dup?.category == "network")
        #expect(SandboxDenial.parse(eventMessage: "Sandbox: x(1) deny(1) file-read-data /a") == nil) // 没有标签：不是我们的引擎
    }

    @Test func 菜单里的一行写短_完整说明留在suggestion() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let long = "/private/var/folders/v4/hr7l4mls063g1_m9tdn_w08h0000gn/T/luoke-ime-check-259946D1-FEAC-4C14-B072-2EAADFA8A667"
        let d = SandboxDenial.parse(eventMessage: "Sandbox: xiaohe(1) deny(1) file-write-create \(long)\nLUOKE[xiaohe] write")!
        #expect(d.summary.count <= 46)
        #expect(d.summary.hasPrefix("写 /private/var/"))
        #expect(d.summary.hasSuffix("2EAADFA8A667"))
        #expect(d.suggestion.contains(long))
        let r = SandboxDenial.parse(eventMessage: "Sandbox: x(1) deny(1) file-read-data \(home)/.luoke/mem.db\nLUOKE[x] read-protected")!
        #expect(r.summary == "读 ~/.luoke/mem.db")
    }

    @Test func 中文引擎名的标签只含允许的字符且不重名() {
        let a = SandboxProfile.tag(for: "小鹤双拼"), b = SandboxProfile.tag(for: "全拼双拼")
        #expect(a != b)
        #expect(a.allSatisfy { $0.isASCII })
        #expect(SandboxProfile.tag(for: "flypy-2") == "flypy-2")
    }

    @Test func 监视器停下时log_stream跟着结束() throws {
        // luokelabs/luoke-ime#12：直接起的 log stream 在父进程退出后成了孤儿
        let monitor = SandboxMonitor()
        guard monitor.start() else { Issue.record("log stream 起不来（非管理员账户？）"); return }
        guard let sh = monitor.shellPID else { Issue.record("没有 sh 的进程号"); return }
        func children(_ pid: Int32) -> [Int32] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-P", String(pid)]
            let out = Pipe()
            p.standardOutput = out
            try? p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
        }
        let logs = children(sh)
        #expect(logs.count == 1)
        monitor.stop()
        let end = ProcessInfo.processInfo.systemUptime + 3
        func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }
        while ProcessInfo.processInfo.systemUptime < end, (logs + [sh]).contains(where: alive) { usleep(20_000) }
        for pid in logs { #expect(!alive(pid)) }
    }

    @Test func 引擎被拦时监视器能认领到它() throws {
        let monitor = SandboxMonitor()
        let lock = NSLock()
        var got: [SandboxDenial] = []
        monitor.onDenial = { d in lock.lock(); got.append(d); lock.unlock() }
        guard monitor.start() else { Issue.record("log stream 起不来（非管理员账户？）"); return }
        defer { monitor.stop() }
        let script = #"""
        import json, socket, sys
        try: open("x.txt", "w")
        except Exception: pass
        try: socket.create_connection(("127.0.0.1", 9), timeout=1)
        except Exception: pass
        for line in sys.stdin:
            m = json.loads(line)
            if m.get("type") == "query":
                print(json.dumps({"type": "answer", "id": m["id"], "candidates": []}), flush=True)
        """#
        let dir = try 引擎宿主.engine("denied", manifest: #"{"protocol":1,"name":"会被拦","kind":"typing","run":["/usr/bin/python3","engine.py"],"input_keys":"a"}"#,
                                 files: ["engine.py": script])
        let conn = try EngineConnection(dir: dir, paths: 引擎宿主.tempPaths())
        try conn.start()
        defer { conn.stopAndWait(timeout: 1) }
        let end = ProcessInfo.processInfo.systemUptime + 5
        func mine() -> [SandboxDenial] { lock.lock(); defer { lock.unlock() }; return got.filter { $0.engine == conn.sandboxTag } }
        while ProcessInfo.processInfo.systemUptime < end, Set(mine().map(\.category)).isSuperset(of: ["write-protected", "network"]) == false { usleep(20_000) }
        let cats = Set(mine().map(\.category))
        #expect(cats.contains("write-protected")) // 写引擎文件夹
        #expect(cats.contains("network"))         // 联网
        #expect(mine().first { $0.category == "network" }?.severity == .hard)
    }
}

/// review 里发现的几处沙盒漏洞：引擎能改动的目录被换成符号链接、壳替引擎读文件、引擎留下的子进程、伪造的日志标签。
@Suite(.serialized) struct 沙盒的漏洞 {
    static func tempDir(_ name: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func 数据目录被换成符号链接就不启动() throws {
        let paths = 引擎宿主.tempPaths()
        let victim = try Self.tempDir("victim")
        try FileManager.default.createDirectory(at: paths.dataRoot, withIntermediateDirectories: true)
        let conn = try EngineConnection(dir: 引擎宿主.minimal, paths: paths)
        try FileManager.default.createSymbolicLink(at: paths.data(conn.id), withDestinationURL: victim)
        #expect(throws: EngineError.self) { try conn.start() }
    }

    @Test func 沙盒不跟随数据目录本身的链接_经链接写不出去() throws {
        let base = try Self.tempDir("sbx-link")
        let victim = try Self.tempDir("victim")
        let link = base.appendingPathComponent("data")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
        #expect(SandboxProfile.realParent(link.path) == SandboxProfile.realPath(base.path) + "/data")

        let manifest = try Manifest.parse(Data(#"{"protocol":1,"name":"x","kind":"typing","run":["x"],"input_keys":"a"}"#.utf8))
        let tmp = try Self.tempDir("sbx-tmp")
        let args = SandboxProfile.arguments(manifest: manifest, tag: "t", engineDir: 引擎宿主.minimal, dataDir: link, tmpDir: tmp,
                                            paths: 引擎宿主.tempPaths())
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = args + ["/bin/sh", "-c", #"echo x > "$0/escaped""#, link.path]
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus != 0)
        #expect(!FileManager.default.fileExists(atPath: victim.appendingPathComponent("escaped").path))
    }

    @Test func 读引擎的选项文件不跟随链接() throws {
        let paths = 引擎宿主.tempPaths()
        let conn = try EngineConnection(dir: 引擎宿主.minimal, paths: paths)
        let data = paths.data(conn.id)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let secret = try Self.tempDir("secret").appendingPathComponent("settings.json")
        try #"{"secret": 1}"#.write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: data.appendingPathComponent("options.json"), withDestinationURL: secret)
        guard case let .object(linked) = conn.currentOptions() else { Issue.record("选项不是对象"); return }
        #expect(linked["secret"] == nil)

        try FileManager.default.removeItem(at: data.appendingPathComponent("options.json"))
        try #"{"mine": 2}"#.write(to: data.appendingPathComponent("options.json"), atomically: true, encoding: .utf8)
        guard case let .object(own) = conn.currentOptions() else { Issue.record("选项不是对象"); return }
        #expect(own["mine"] != nil)
    }

    @Test func 引擎退出后它留下的子进程也被结束() throws {
        let dir = try Self.tempDir("leaver")
        try #"{"protocol":1,"name":"留子进程","kind":"typing","run":["/bin/sh","-c","sleep 30 & echo $! > \"$LUOKE_IME_DATA/pid\"; exec cat > /dev/null"],"input_keys":"a"}"#
            .write(to: dir.appendingPathComponent("engine.json"), atomically: true, encoding: .utf8)
        let paths = 引擎宿主.tempPaths()
        let conn = try EngineConnection(dir: dir, paths: paths)
        conn.sandboxed = false
        try conn.start()
        let pidFile = paths.data(conn.id).appendingPathComponent("pid")
        let end = Date().addingTimeInterval(3)
        var pid: pid_t?
        while pid == nil, Date() < end {
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            usleep(20_000)
        }
        guard let pid else { Issue.record("子进程没有写出进程号"); return }
        #expect(kill(pid, 0) == 0)
        #expect(conn.stopAndWait(timeout: 1)) // 关掉标准输入，cat 退出，引擎随之退出
        let gone = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0, Date() < gone { usleep(20_000) }
        #expect(kill(pid, 0) != 0)
    }

    @Test func 日志里伪造的标签不算数() {
        let d = SandboxDenial.parse(eventMessage: "Sandbox: x(1) deny(1) file-write-create /tmp/a\nLUOKE[victim] network\nLUOKE[real] write")
        #expect(d?.engine == "real")
        #expect(d?.category == "write")
        #expect(SandboxDenial.parse(eventMessage: "Sandbox: x(1) deny(1) file-write-create /tmp/a\nLUOKE[real] write; and more") == nil)
    }
}

@Suite(.serialized) struct 沙盒保护螺壳其他工具的数据 {
    @Test func 壳建的目录只有自己能进_已有的上一级不动() throws {
        let fm = FileManager.default
        func mode(_ u: URL) -> Int { (try? fm.attributesOfItem(atPath: u.path))?[.posixPermissions] as? Int ?? -1 }
        let base = fm.temporaryDirectory.appendingPathComponent("prep-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let fresh = Paths(root: base.appendingPathComponent(".luoke/ime"))
        fresh.prepare()
        #expect(mode(base.appendingPathComponent(".luoke")) == 0o700) // 新机器：~/.luoke 也是 700
        #expect(mode(fresh.root) == 0o700)
        // 已有的 ~/.luoke 是别人的，不动；壳自己的目录松了就收紧
        let other = base.appendingPathComponent("other")
        try fm.createDirectory(at: other.appendingPathComponent("ime"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: other.path)
        Paths(root: other.appendingPathComponent("ime")).prepare()
        #expect(mode(other) == 0o755)
        #expect(mode(other.appendingPathComponent("ime")) == 0o700)
    }

    @Test func 引擎读不到_luoke_下别的工具的数据_但读得到自己的数据目录() throws {
        // 自己的临时目录当"螺壳目录"（沙盒照样整个不让读），里面的文件代替 mem.db：不碰用户真的 ~/.luoke
        let luoke = FileManager.default.temporaryDirectory.appendingPathComponent("luoke-ime-tests-\(UUID().uuidString)/.luoke")
        try FileManager.default.createDirectory(at: luoke, withIntermediateDirectories: true)
        let marker = luoke.appendingPathComponent(".sbx-test")
        try "secret".write(to: marker, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: luoke.deletingLastPathComponent()) }
        let paths = 引擎宿主.tempPaths()
        let data = paths.data("t")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try "mine".write(to: data.appendingPathComponent("own"), atomically: true, encoding: .utf8)
        let manifest = try Manifest.parse(Data(#"{"protocol":1,"name":"x","kind":"typing","run":["x"],"input_keys":"a"}"#.utf8))
        let args = SandboxProfile.arguments(manifest: manifest, tag: "t", engineDir: 引擎宿主.minimal, dataDir: data,
                                            tmpDir: paths.tmp("t"), paths: Paths(), luokeHome: luoke)
        func run(_ path: String) throws -> (Int32, String) {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            p.arguments = args + ["/bin/cat", path]
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        let (status, text) = try run(marker.path)
        #expect(status != 0)
        #expect(!text.contains("secret"))
        #expect(try run(data.appendingPathComponent("own").path).1 == "mine")
    }
}

@Suite struct 开发模式的记录 {
    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("luoke-ime-tests-\(UUID().uuidString)/records/xiaohe")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func 不记的时候什么都不写() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        let r = try Recorder(directory: dir)
        r.record(.key, ["key": "a"])
        r.muted = true
        r.record(.key, ["key": "b"])
        r.record(.toEngine, #"{"type":"key","key":"b"}"#)
        r.muted = false
        r.record(.key, ["key": "c"])
        let keys = try Recorder.read(r.url).compactMap { ($0.data as? [String: Any])?["key"] as? String }
        #expect(keys == ["a", "c"])
    }

    @Test func 只留最近七天() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        let fm = FileManager.default
        let old = dir.appendingPathComponent("20261001-090000.jsonl"), recent = dir.appendingPathComponent("20261012-090000.jsonl")
        let other = dir.appendingPathComponent("说明.txt")
        for f in [old, recent, other] { fm.createFile(atPath: f.path, contents: Data("{}\n".utf8)) }
        let now = Date()
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86400)], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86400)], ofItemAtPath: other.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-6 * 86400)], ofItemAtPath: recent.path)
        let r = try Recorder(directory: dir, now: now)
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: recent.path))
        #expect(fm.fileExists(atPath: other.path)) // 只删记录文件
        #expect(fm.fileExists(atPath: r.url.path))
    }
}

@Suite struct 开发模式的记录_定时清 {
    /// 每个引擎的记录目录都清，删空了的目录也删。
    @Test func 所有引擎的旧记录都清_空目录删掉() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("luoke-ime-tests-\(UUID().uuidString)/records")
        defer { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        let gone = root.appendingPathComponent("removed-engine"), live = root.appendingPathComponent("xiaohe")
        for d in [gone, live] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let old1 = gone.appendingPathComponent("20261001-090000.jsonl"), old2 = live.appendingPathComponent("20261002-090000.jsonl")
        let fresh = live.appendingPathComponent("20261015-090000.jsonl")
        let now = Date()
        for (f, age) in [(old1, 9.0), (old2, 8.0), (fresh, 1.0)] {
            fm.createFile(atPath: f.path, contents: Data("{}\n".utf8))
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age * 86400)], ofItemAtPath: f.path)
        }
        Recorder.sweepAll(root, now: now)
        #expect(!fm.fileExists(atPath: gone.path))
        #expect(!fm.fileExists(atPath: old2.path))
        #expect(fm.fileExists(atPath: fresh.path))
    }
}

@Suite struct 清掉学到的 {
    @Test func 引擎声明了才有_消息只有类型() throws {
        let base = #"{"protocol":1,"name":"x","kind":"typing","run":["x"],"input_keys":"a""#
        #expect(try Manifest.parse(Data((base + "}").utf8)).forgetAll == false)
        #expect(try Manifest.parse(Data((base + #","forget_all":true}"#).utf8)).forgetAll)
        #expect(throws: ManifestError.self) { try Manifest.parse(Data((base + #","forget_all":"yes"}"#).utf8)) }
        #expect(ShellMessage.forgetAll.line == #"{"type":"forget_all"}"#)
        #expect(ShellMessage.unforget(input: "wo", text: "窝").line == #"{"input":"wo","text":"窝","type":"unforget"}"#)
    }
}
