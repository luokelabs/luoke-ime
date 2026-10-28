import Foundation
import Testing
@testable import LuokeShell

/// 个人化组件和转问（docs/引擎协议.md#个人化组件、#转问）。
@Suite struct 个人化组件的引擎说明 {
    static func parse(_ json: String) throws -> Manifest { try Manifest.parse(Data(json.utf8)) }
    static let personal = #"{"protocol":1,"name":"个人化","kind":"personal","run":["x"]"#
    static let typing = #"{"protocol":1,"name":"x","kind":"typing","run":["x"],"input_keys":"ab""#

    @Test func 个人化组件不用输入键_可以声明记忆() throws {
        let m = try Self.parse(Self.personal + #","context":200,"app":true,"asks":["hub"],"permissions":{"memory":true,"gpu":true}}"#)
        #expect(m.kind == .personal)
        #expect(m.permissions.memory)
        #expect(m.asks == [.hub])
    }

    static let invalid: [String] = [
        personal + #","permissions":{"network":"local","local_ports":[8080]}}"#,   // 个人化组件不能联网
        personal + #","permissions":{"microphone":true}}"#,
        personal + #","asks":["personal"]}"#,                                       // 不能转问自己
        typing + #","permissions":{"memory":true}}"#,                               // 只有个人化组件能碰记忆
        typing + #","asks":["personal"],"permissions":{"network":"any"}}"#,         // 能联网出去的不能转问个人化组件
        typing + #","asks":["personal"],"permissions":{"network":"local"}}"#,       // 本机所有端口里可能有代理
        typing + #","asks":["someone"]}"#,
        typing + #","asks":"personal"}"#,
    ]

    @Test(arguments: invalid)
    func 不合法(_ json: String) {
        #expect(throws: ManifestError.self) { try Self.parse(json) }
    }

    @Test func 限定了本机端口的引擎可以转问个人化组件() throws {
        let m = try Self.parse(Self.typing + #","asks":["personal","hub"],"permissions":{"network":"local","local_ports":[8000]}}"#)
        #expect(m.asks == [.personal, .hub])
    }
}

@Suite struct 转问的消息 {
    @Test func 解析ask和reply() throws {
        #expect(try EngineMessage.parse(#"{"type":"ask","id":3,"to":"personal","method":"score","params":{"context":"今天"}}"#)
            == .ask(Ask(id: 3, to: "personal", method: "score", params: .object(["context": .string("今天")]))))
        #expect(try EngineMessage.parse(#"{"type":"ask","id":4,"to":"hub","method":"x"}"#) == .ask(Ask(id: 4, to: "hub", method: "x")))
        #expect(try EngineMessage.parse(#"{"type":"reply","id":5,"result":[1,2]}"#)
            == .reply(Reply(id: 5, result: .array([.number(1), .number(2)]))))
        #expect(try EngineMessage.parse(#"{"type":"reply","id":6,"result":null}"#) == .reply(Reply(id: 6, result: .null)))
        let e = try EngineMessage.parse(#"{"type":"reply","id":7,"error":{"code":"busy","message":"x"}}"#)
        guard case let .reply(r) = e else { Issue.record("不是 reply"); return }
        #expect(r.errorCode == "busy")
    }

    @Test(arguments: [#"{"type":"ask","id":1,"to":"personal","method":"x","params":[1]}"#,
                      #"{"type":"ask","id":1,"method":"x"}"#,
                      #"{"type":"reply","id":1}"#,
                      #"{"type":"reply","id":1,"result":1,"error":{"code":"x"}}"#,
                      #"{"type":"reply","id":1,"error":"x"}"#])
    func 格式不对(_ line: String) {
        #expect(throws: ProtocolError.self) { try EngineMessage.parse(line) }
    }

    @Test func 发给个人化组件的上屏带来源和类别_标点和语音不带pieces() {
        let c = ShellMessage.committed(.init(id: 1, text: "，", auto: false, context: nil, pieces: [], source: "xiaohe", kind: .punctuation, app: "a"))
        #expect(c.line == #"{"app":"a","auto":false,"id":1,"kind":"punctuation","source":"xiaohe","text":"，","type":"committed"}"#)
        let t = ShellMessage.committed(.init(id: 2, text: "我", auto: false, context: nil, pieces: [Piece(input: "wo", text: "我", index: 0, top: "我")]))
        #expect(t.line.contains(#""pieces":"#) && !t.line.contains("source"))
    }
}

@Suite struct 上屏转给个人化组件 {
    static func personalManifest(context: Int = 10, app: Bool = true) -> Manifest {
        Manifest(protocolVersion: 1, name: "个人化", kind: .personal, run: ["x"], inputKeys: [], punctuation: .default,
                 context: context, app: app, feedback: false, hotkey: nil, permissions: .init(), options: nil)
    }

    static func rig(typingContext: Int = 0, personalContext: Int = 10) -> (Rig, FakeChannel) {
        let r = Rig(manifest: typingManifest(context: typingContext))
        r.session.typing?.id = "xiaohe"
        let p = FakeChannel(clock: r.clock)
        r.session.personal = PersonalEngine(manifest: personalManifest(context: personalContext), channel: p)
        return (r, p)
    }

    static func commits(_ ch: FakeChannel) -> [ShellMessage.Committed] {
        ch.sent.compactMap { if case let .committed(c) = $0 { return c } else { return nil } }
    }

    @Test func 打字上屏和标点都转_带来源类别应用和前文() {
        let (r, p) = Self.rig()
        r.client.document = "这是很长的一段前文：今天"
        r.type("wo")
        r.elapse(0.01)
        r.press(.space)
        r.type(",")
        let cs = Self.commits(p)
        #expect(cs.count == 2)
        #expect(cs.first?.text == "我")
        #expect(cs.first?.kind == .typing)
        #expect(cs.first?.source == "xiaohe")
        #expect(cs.first?.app == "com.example.app")
        #expect(cs.first?.context == "很长的一段前文：今天") // 打字引擎不要前文，个人化组件要 10 字
        #expect(cs.first?.pieces == [Piece(input: "wo", text: "我", index: 0, top: "我")])
        #expect(cs.last?.text == "，")
        #expect(cs.last?.kind == .punctuation)
        // 打字引擎声明了 context 0：询问里照样没有前文
        #expect(r.channel.queries.allSatisfy { $0.context == nil })
    }

    @Test func 打字引擎和个人化组件各取自己声明的前文() {
        let (r, p) = Self.rig(typingContext: 3, personalContext: 6)
        r.client.document = "一二三四五六七八"
        r.type("wo")
        r.elapse(0.01)
        #expect(r.channel.queries.first?.context == "六七八")
        r.press(.space)
        #expect(Self.commits(p).first?.context == "三四五六七八")
        let typingCommit = r.channel.sent.compactMap { if case let .committed(c) = $0 { return c } else { return nil } }.first
        #expect(typingCommit?.context == "六七八")
        #expect(typingCommit?.source == nil)
    }

    @Test func 安全输入_暂停或不记录的应用里什么都不转_打字引擎也收不到反馈() {
        for setup in [{ (c: FakeClient) in c.isSecureInput = true }, { (c: FakeClient) in c.mayRecord = false }] {
            let (r, p) = Self.rig()
            setup(r.client)
            r.type("wo")
            r.elapse(0.01)
            r.press(.space)
            r.type(",")
            r.press(.backspace)
            r.press(.other)
            r.type("wo")
            r.elapse(0.01)
            r.press(.right)
            r.press(.backspace, [.shift]) // 忘掉候选
            #expect(p.sent.isEmpty)
            #expect(r.client.document == "我，")
            // 打字引擎自己的学习数据也不记：不发上屏、退格、忘掉（询问照常，出候选要用）
            #expect(!r.channel.sent.contains { switch $0 { case .committed, .deleted, .forget: return true; default: return false } })
            #expect(!r.channel.queries.isEmpty)
        }
    }

    /// luokelabs/luoke-ime#6：没允许保存到本机记忆时，上屏、删改、忘掉一律不转给个人化组件；
    /// 打字引擎自己的反馈照常（它学改选过的词不归这个开关管），联想照常问。
    @Test func 没允许保存到记忆时上屏删改忘掉都不转_联想照常问() {
        let (r, p) = Self.rig()
        r.client.memoryConsented = false
        var asked = 0
        r.session.predictor = { _, _, _ in asked += 1 }
        r.type("wo")
        r.elapse(0.01)
        r.press(.space)
        r.elapse(0.3) // 上屏后停够了才问联想
        r.press(.backspace)
        r.press(.other)
        r.type("wo")
        r.elapse(0.01)
        r.press(.right)
        r.press(.backspace, [.shift])
        #expect(!p.sent.contains { switch $0 { case .committed, .deleted, .forget: return true; default: return false } })
        #expect(r.channel.sent.contains { if case .committed = $0 { return true } else { return false } })
        #expect(asked > 0)
    }

    /// 组字时碰到安全输入，上屏时安全输入已经关了也不学。
    @Test func 组字时碰到过安全输入_上屏时关了也不学() {
        let (r, p) = Self.rig()
        r.client.isSecureInput = true
        r.type("w")
        r.client.isSecureInput = false
        r.type("o")
        r.elapse(0.01)
        r.press(.space)
        #expect(Self.commits(p).isEmpty)
        #expect(!r.channel.sent.contains { if case .committed = $0 { return true } else { return false } })
        r.type("wo")                      // 下一段正常学
        r.elapse(0.01)
        r.press(.space)
        #expect(Self.commits(p).count == 1)
    }

    @Test func 退格和忘掉也转_退格指向个人化组件自己的序号() {
        let (r, p) = Self.rig()
        r.type("wo")
        r.elapse(0.01)
        r.press(.space)
        r.press(.backspace)
        r.press(.backspace)
        r.press(.other)
        guard let c = Self.commits(p).first else { Issue.record("没有转上屏"); return }
        #expect(p.sent.contains(.deleted(after: c.id, count: 2, followedBy: "")))
        r.type("wo")
        r.elapse(0.01)
        r.press(.right)
        r.press(.backspace, [.shift])
        #expect(p.sent.contains(.forget(input: "wo", text: "窝", context: "我", source: "xiaohe"))) // 假输入框不执行放行的退格，前文里还有"我"
    }

    @Test func 快捷键引擎的上屏也转() {
        let (r, p) = Self.rig()
        let ch = FakeChannel(clock: r.clock)
        let m = Manifest(protocolVersion: 1, name: "语音", kind: .hotkey, run: ["x"], inputKeys: [], punctuation: .default,
                         context: 0, app: false, feedback: false, hotkey: .init(key: .rightCommand, mode: .press),
                         permissions: .init(), options: nil)
        r.session.hotkeys = [HotkeyEngine(manifest: m, channel: ch, id: "voice")]
        r.client.document = "会议："
        r.press(.modifierDown(.rightCommand))
        r.press(.modifierUp(.rightCommand))
        guard case let .start(id, ctx, _)? = ch.sent.first else { Issue.record("没有发 start"); return }
        #expect(ctx == nil) // 快捷键引擎没声明前文
        ch.push(.commit(id: id, text: "今天开会。"))
        r.elapse(0.01)
        let c = Self.commits(p).last
        #expect(c?.text == "今天开会。")
        #expect(c?.kind == .hotkey)
        #expect(c?.source == "voice")
        #expect(c?.context == "会议：")
    }

    @Test func 个人化组件不在运行时不转() {
        let (r, p) = Self.rig()
        p.available = false
        r.type("wo")
        r.elapse(0.01)
        r.press(.space)
        #expect(p.sent.isEmpty)
        #expect(r.client.document == "我")
    }
}

/// 真实子进程：打字引擎经壳转问个人化组件，答复转回来。
@Suite(.serialized) struct 转问的中转 {
    /// 发问的打字引擎：每次询问都转问一次（方法由参数给），把答复（或错误码）当作首选。
    static let asker = #"""
    import json, sys
    method, forge = sys.argv[1], len(sys.argv) > 2
    pending, n = {}, 0
    def send(m): print(json.dumps(m, ensure_ascii=False), flush=True)
    for line in sys.stdin:
        m = json.loads(line)
        if m.get("type") == "query":
            n += 1
            pending[n] = m["id"]
            send({"type": "ask", "id": n, "to": "personal", "method": method, "params": {"input": m["input"]}})
            if forge:  # 冒充个人化组件答复：壳不该认
                send({"type": "reply", "id": 1, "result": {"text": "forged"}})
        elif m.get("type") == "reply":
            q = pending.pop(m["id"], None)
            if q is None: continue
            text = m["result"]["text"] if "result" in m else "error:" + m["error"]["code"]
            send({"type": "answer", "id": q, "candidates": [{"text": text, "consume": 1}]})
    """#

    static let personal = #"""
    import json, sys, time
    for line in sys.stdin:
        m = json.loads(line)
        if m.get("type") == "ask":
            if m["params"]["input"] == "b": sys.exit(3)  # 问的是 b：中途退出
            time.sleep(0.1)
            print(json.dumps({"type": "reply", "id": m["id"], "result": {"text": "P:%s:%s" % (m["params"]["input"], m["from"])}}), flush=True)
    """#

    final class Setup {
        let broker = AskBroker()
        let typing: EngineConnection
        var personal: EngineConnection?
        let session: Session
        let client = FakeClient()
        let channel: EngineChannel

        init(asks: Bool = true, method: String = "score", forge: Bool = false, withPersonal: Bool = true) throws {
            let extra = asks ? #","asks":["personal"]"# : ""
            let run = #"["/usr/bin/python3","engine.py","\#(method)""# + (forge ? #","forge"]"# : "]")
            let dir = try 引擎宿主.engine("asker", manifest: #"{"protocol":1,"name":"问","kind":"typing","run":\#(run),"input_keys":"ab"\#(extra)}"#,
                                       files: ["engine.py": 转问的中转.asker])
            typing = try EngineConnection(dir: dir, paths: 引擎宿主.tempPaths())
            broker.attach(typing)
            if withPersonal {
                let pdir = try 引擎宿主.engine("personal", manifest: #"{"protocol":1,"name":"个人化","kind":"personal","run":["/usr/bin/python3","p.py"]}"#,
                                            files: ["p.py": 转问的中转.personal])
                let p = try EngineConnection(dir: pdir, paths: 引擎宿主.tempPaths())
                broker.attach(p)
                broker.personal = p
                try p.start()
                personal = p
            }
            try typing.start()
            session = Session(client: client)
            channel = typing.makeChannel()
            session.typing = TypingEngine(manifest: typing.manifest, channel: channel, id: typing.id)
        }

        func top(after keys: String) -> String? {
            for c in keys { session.handle(.char(c)) }
            _ = 引擎宿主.run(session, channel, timeout: 5) { client.view.candidates.first != nil }
            return client.view.candidates.first?.text
        }

        deinit {
            typing.stop()
            personal?.stop()
        }
    }

    @Test func 打字引擎转问个人化组件_答复转回来() throws {
        let s = try Setup()
        let top = s.top(after: "a")
        #expect(top == "P:a:\(s.typing.id)")
        #expect(s.broker.pendingCount == 0)
    }

    /// predict 用的是用户写过的历史，只有壳能问。
    @Test func 引擎只能问个人化组件score和ping() throws {
        let s = try Setup(method: "predict")
        #expect(s.top(after: "a") == "error:not_allowed")
    }

    /// 壳说现在不能交给个人化组件（安全输入，或第三方组件在不能记的时候），转问答 unavailable。
    @Test func 隐私开关不让时不转给个人化组件() throws {
        let s = try Setup()
        s.broker.personalAllowed = false
        #expect(s.top(after: "a") == "error:unavailable")
    }

    @Test func 没声明就不转() throws {
        let s = try Setup(asks: false)
        #expect(s.top(after: "a") == "error:not_allowed")
    }

    @Test func 没有个人化组件时答不可用() throws {
        let s = try Setup(withPersonal: false)
        #expect(s.top(after: "a") == "error:unavailable")
    }

    @Test func 个人化组件中途退出_等着的转问答不可用() throws {
        let s = try Setup()
        #expect(s.top(after: "b") == "error:unavailable")
    }

    @Test func 壳自己问个人化组件_答复交给回调_没有组件时立刻答不可用() throws {
        let broker = AskBroker()
        let none = DispatchSemaphore(value: 0)
        var first: Reply?
        broker.askFromShell(method: "predict", params: .object([:])) { first = $0; none.signal() }
        #expect(none.wait(timeout: .now() + 1) == .success)
        #expect(first?.errorCode == "unavailable")

        let script = #"""
        import json, sys
        for line in sys.stdin:
            m = json.loads(line)
            if m.get("type") == "ask":
                print(json.dumps({"type": "reply", "id": m["id"], "result": {"from": m["from"], "candidates": ["下午"]}}), flush=True)
        """#
        let dir = try 引擎宿主.engine("personal", manifest: #"{"protocol":1,"name":"个人化","kind":"personal","run":["/usr/bin/python3","p.py"]}"#,
                                   files: ["p.py": script])
        let p = try EngineConnection(dir: dir, paths: 引擎宿主.tempPaths())
        broker.attach(p)
        broker.personal = p
        try p.start()
        defer { p.stop() }
        let done = DispatchSemaphore(value: 0)
        var got: Reply?
        broker.askFromShell(method: "predict", params: .object(["context": .string("明天")])) { got = $0; done.signal() }
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(got?.result == .object(["from": .string("shell"), "candidates": .array([.string("下午")])]))
    }

    @Test func 读写记忆要用户同意_没同意时拿不到记忆的路径() throws {
        let script = #"""
        import json, os, sys
        for line in sys.stdin:
            m = json.loads(line)
            if m.get("type") == "ask":
                print(json.dumps({"type": "reply", "id": m["id"], "result": os.environ.get("LUOKE_IME_MEMORY", "none")}), flush=True)
        """#
        let dir = try 引擎宿主.engine("personal", manifest: #"{"protocol":1,"name":"个人化","kind":"personal","run":["/usr/bin/python3","p.py"],"permissions":{"memory":true}}"#,
                                   files: ["p.py": script])
        func memoryPath(granted: Bool) throws -> JSONValue? {
            let broker = AskBroker()
            let p = try EngineConnection(dir: dir, paths: 引擎宿主.tempPaths())
            p.memoryGranted = granted
            broker.attach(p)
            broker.personal = p
            try p.start()
            defer { p.stop() }
            let done = DispatchSemaphore(value: 0)
            var got: Reply?
            broker.askFromShell(method: "ping", params: .object([:])) { got = $0; done.signal() }
            _ = done.wait(timeout: .now() + 5)
            return got?.result
        }
        #expect(try memoryPath(granted: false) == .string("none"))
        guard case let .string(path)? = try memoryPath(granted: true) else { Issue.record("同意了也没拿到路径"); return }
        #expect(path.hasSuffix("mem.db"))
    }

    @Test func 别的引擎冒充的答复不算数() throws {
        let s = try Setup(forge: true)
        #expect(s.top(after: "a") == "P:a:\(s.typing.id)")
    }
}

@Suite(.serialized) struct 沙盒放行记忆 {
    static func run(_ args: [String], _ command: [String]) throws -> (Int32, String) {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = args + command
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    static let sqlite = """
    import sqlite3, sys
    c = sqlite3.connect(sys.argv[1], timeout=2)
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("CREATE TABLE IF NOT EXISTS t(x)")
    c.execute("INSERT INTO t VALUES (1)")
    c.commit()
    print(c.execute("SELECT count(*) FROM t").fetchone()[0], end="")
    """

    @Test func 不让读的螺壳目录缺省就是真的_luoke() throws {
        // 只有测试换成自己的临时目录；壳起引擎时不传，沙盒挡的必须是用户真的 ~/.luoke（记忆在那里）
        let manifest = try Manifest.parse(Data(#"{"protocol":1,"name":"x","kind":"typing","run":["x"],"input_keys":"a"}"#.utf8))
        let paths = 引擎宿主.tempPaths()
        let args = SandboxProfile.arguments(manifest: manifest, tag: "t", engineDir: 引擎宿主.minimal, dataDir: paths.data("t"),
                                            tmpDir: paths.tmp("t"), paths: paths)
        let home = SandboxProfile.realPath(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".luoke").path)
        #expect(args.contains("LUOKE_HOME=" + home))
        // 测试和命令行版的根目录有自己的临时目录，不和装好的输入法共用 $TMPDIR/luoke-ime/<引擎>
        #expect(!paths.tmp("t").path.hasPrefix(FileManager.default.temporaryDirectory.appendingPathComponent("luoke-ime").path + "/"))
        #expect(Paths().tmp("t").path.hasSuffix("/luoke-ime/t"))
    }

    @Test func SQLite_同步记忆所在目录被拦时不报告() throws {
        // SQLite 新建 -wal 以后要打开所在目录同步一下；那个目录（~/.luoke）照样不让读，但不报告：
        // 失败了 SQLite 会忽略，报出来菜单里就多一条吓人的"被沙盒拦下"（开发机上出现过）
        let luoke = FileManager.default.temporaryDirectory.appendingPathComponent("luoke-ime-tests-\(UUID().uuidString)/.luoke")
        try FileManager.default.createDirectory(at: luoke, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: luoke.deletingLastPathComponent()) }
        let db = luoke.appendingPathComponent("mem.db")
        let paths = 引擎宿主.tempPaths()
        let data = paths.data("p")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let tag = "memdir-" + UUID().uuidString.prefix(8)
        let args = SandboxProfile.arguments(manifest: try Manifest.parse(Data(#"{"protocol":1,"name":"个人化","kind":"personal","run":["x"],"permissions":{"memory":true}}"#.utf8)),
                                            tag: String(tag), engineDir: 引擎宿主.minimal, dataDir: data, tmpDir: paths.tmp("p"),
                                            paths: Paths(), memory: db, luokeHome: luoke)
        let (status, out) = try Self.run(args, ["/usr/bin/python3", "-c", Self.sqlite, db.path])
        #expect(status == 0)
        #expect(out == "1")
        // 写进去了，而且系统日志里没有这个引擎的拦截报告
        let log = Process(), pipe = Pipe()
        log.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        log.arguments = ["show", "--last", "30s", "--style", "compact", "--predicate", "eventMessage CONTAINS \"LUOKE[\(tag)]\""]
        log.standardOutput = pipe
        try log.run()
        log.waitUntilExit()
        let lines = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").filter { $0.contains("Sandbox:") }
        #expect(lines.isEmpty, "\(lines)")
    }

    @Test func 声明了记忆的个人化组件能读写记忆_其余照样读不到() throws {
        // 用自己的临时目录当"螺壳目录"（沙盒照样整个不让读），里面的测试文件代替 mem.db：不碰用户真的 ~/.luoke
        let luoke = FileManager.default.temporaryDirectory.appendingPathComponent("luoke-ime-tests-\(UUID().uuidString)/.luoke")
        try FileManager.default.createDirectory(at: luoke, withIntermediateDirectories: true)
        let tag = UUID().uuidString
        let db = luoke.appendingPathComponent(".sbx-test-\(tag).db")
        let other = luoke.appendingPathComponent(".sbx-test-\(tag)-other")
        let target = luoke.appendingPathComponent(".sbx-test-\(tag)-target")
        try "secret".write(to: other, atomically: true, encoding: .utf8)
        try "keep".write(to: target, atomically: true, encoding: .utf8)
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: db.path + suffix) }
            try? FileManager.default.removeItem(at: other)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: luoke.deletingLastPathComponent())
        }
        let paths = 引擎宿主.tempPaths()
        let data = paths.data("p")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        func args(_ manifest: String) throws -> [String] {
            SandboxProfile.arguments(manifest: try Manifest.parse(Data(manifest.utf8)), tag: "p", engineDir: 引擎宿主.minimal,
                                     dataDir: data, tmpDir: paths.tmp("p"), paths: Paths(), memory: db, luokeHome: luoke)
        }
        let personal = try args(#"{"protocol":1,"name":"个人化","kind":"personal","run":["x"],"permissions":{"memory":true}}"#)
        let undeclared = try args(#"{"protocol":1,"name":"个人化","kind":"personal","run":["x"]}"#)
        let python = ["/usr/bin/python3", "-c", Self.sqlite, db.path]

        #expect(try Self.run(undeclared, python).0 != 0)
        let (status, out) = try Self.run(personal, python)
        #expect(status == 0)
        #expect(out == "1")
        #expect(try Self.run(personal, python).1 == "2") // WAL 模式下再开一次，读写都行
        let (s2, text) = try Self.run(personal, ["/bin/cat", other.path])
        #expect(s2 != 0)
        #expect(!text.contains("secret"))

        // 个人化组件把 mem.db 换成指向别处的链接：沙盒不跟随，经链接写不出去
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + suffix) }
        try FileManager.default.createSymbolicLink(at: db, withDestinationURL: target)
        let linked = try args(#"{"protocol":1,"name":"个人化","kind":"personal","run":["x"],"permissions":{"memory":true}}"#)
        #expect(try Self.run(linked, python).0 != 0)
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
    }
}

/// 主控的客户端（luoke-core V1 §2 线上格式）：对着一个假的主控（Unix socket 上的小 HTTP 服务）测。
@Suite(.serialized) struct 主控的客户端 {
    static let fakeHub = #"""
    import json, os, socketserver, sys
    from http.server import BaseHTTPRequestHandler
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def answer(self, status, obj):
            body = json.dumps(obj).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def do_GET(self):
            self.answer(200, {"contract": 1, "who": self.headers.get("X-Luoke-Accessory"),
                              "tasks": {"luoke-ime.rerank": {"kind": "score", "params": {"batch": 2, "max_chars": 3}}}})
        def do_POST(self):
            req = json.loads(self.rfile.read(int(self.headers["Content-Length"])) or b"{}")
            if self.path == "/tasks/luoke-ime.rerank/v1/score":
                if req["context"] == "加载中":
                    return self.answer(503, {"code": "not_ready", "message": "loading", "retry_after": 2})
                if len(req["candidates"]) > 2 or len(req["context"]) > 3:  # 任务参数：batch 2、max_chars 3
                    return self.answer(400, {"code": "invalid_request", "message": "too many", "retry_after": None})
                self.answer(200, {"logprobs": [-1.0 * len(c) for c in req["candidates"]], "model": "fake", "cache_hit": True, "ms": 1})
            else:
                self.answer(403, {"code": "unknown_accessory", "message": "no", "retry_after": None})
    class S(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
        pass
    path = sys.argv[1]
    S(path, H).serve_forever()
    """#

    final class Hub {
        let dir: URL
        let socket: String
        let process = Process()
        init() throws {
            dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("hub-\(UUID().uuidString.prefix(8))") // socket 路径不能太长
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            socket = dir.appendingPathComponent("s").path
            let script = dir.appendingPathComponent("hub.py")
            try 主控的客户端.fakeHub.write(to: script, atomically: true, encoding: .utf8)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path, socket]
            try process.run()
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: socket) { usleep(20_000) }
        }
        deinit {
            process.terminate()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test func 打分_带配件标识_拒绝时给原因码和重试时间() throws {
        let hub = try Hub()
        let c = HubClient(accessory: "luoke-ime/test", socketPath: hub.socket)
        guard case let .success(r) = c.request("POST", "/tasks/luoke-ime.rerank/v1/score",
                                               body: .object(["context": .string("今天"), "candidates": .array([.string("天气"), .string("天")])])) else {
            Issue.record("请求失败"); return
        }
        #expect(r.status == 200)
        #expect(r.json?["logprobs"] == .array([.number(-2), .number(-1)]))
        guard case let .success(t) = c.request("GET", "/tasks") else { Issue.record("请求失败"); return }
        #expect(t.json?["who"] == .string("luoke-ime/test"))

        let notReady = AskBroker.hubReply(5, c.request("POST", "/tasks/luoke-ime.rerank/v1/score",
                                                        body: .object(["context": .string("加载中"), "candidates": .array([])])))
        #expect(notReady.id == 5)
        #expect(notReady.errorCode == "not_ready")
        #expect(notReady.error?["retry_after"] == .number(2))
    }

    @Test func 主控没在运行时答不可用() {
        let c = HubClient(accessory: "luoke-ime/test", socketPath: "/tmp/no-such-hub-\(UUID().uuidString.prefix(6))")
        let r = AskBroker.hubReply(1, c.request("GET", "/tasks"))
        #expect(r.errorCode == "unavailable")
    }

    @Test func 只转输入法自己的任务() {
        #expect(AskBroker.hubRequest(Ask(id: 1, to: "hub", method: "score", params: .object([
            "task": .string("luoke-ime.rerank"), "context": .string(""), "candidates": .array([])])))?.path == "/tasks/luoke-ime.rerank/v1/score")
        #expect(AskBroker.hubRequest(Ask(id: 1, to: "hub", method: "score", params: .object([
            "task": .string("luoke-mail.triage"), "context": .string(""), "candidates": .array([])]))) == nil)
        #expect(AskBroker.hubRequest(Ask(id: 1, to: "hub", method: "score", params: .object([
            "task": .string("luoke-ime.x/../y"), "context": .string(""), "candidates": .array([])]))) == nil)
        #expect(AskBroker.hubRequest(Ask(id: 1, to: "hub", method: "chat"))  == nil)
        let p = AskBroker.hubRequest(Ask(id: 1, to: "hub", method: "predict", params: .object([
            "task": .string("luoke-ime.predict"), "context": .string("今天天气"), "k": .number(4)])))
        #expect(p?.path == "/tasks/luoke-ime.predict/v1/predict")
        #expect(p?.body == .object(["context": .string("今天天气"), "k": .number(4)]))
    }

    @Test func 解析chunked的答复() {
        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3\r\n:1}\r\n0\r\n\r\n".utf8)
        guard case let .success(r) = HubClient.parse(raw) else { Issue.record("没解析出来"); return }
        #expect(r.json == .object(["a": .number(1)]))
    }

    @Test func 个人化组件转问主控_壳转过去再转回来() throws {
        let hub = try Hub()
        let script = #"""
        import json, sys
        asked = False
        for line in sys.stdin:
            m = json.loads(line)
            if m.get("type") == "ask" and not asked:   # 壳来问：先转问主控
                asked = True
                outer = m["id"]
                print(json.dumps({"type": "ask", "id": 9, "to": "hub", "method": "score",
                                  "params": {"task": "luoke-ime.rerank", "context": "今天天气很好", "candidates": ["甲", "乙乙", "丙丙丙", "丁", "戊戊"]}}), flush=True)
            elif m.get("type") == "reply" and m["id"] == 9:
                print(json.dumps({"type": "reply", "id": outer, "result": m.get("result") or m.get("error")}), flush=True)
        """#
        let dir = try 引擎宿主.engine("personal", manifest: #"{"protocol":1,"name":"个人化","kind":"personal","run":["/usr/bin/python3","p.py"],"asks":["hub"]}"#,
                                   files: ["p.py": script])
        let broker = AskBroker()
        broker.hub = HubClient(accessory: "luoke-ime/test", socketPath: hub.socket)
        let p = try EngineConnection(dir: dir, paths: 引擎宿主.tempPaths())
        broker.attach(p)
        broker.personal = p
        try p.start()
        defer { p.stop() }
        let done = DispatchSemaphore(value: 0)
        var got: Reply?
        broker.askFromShell(method: "ping", params: .object([:])) { got = $0; done.signal() }
        #expect(done.wait(timeout: .now() + 5) == .success)
        // 壳照主控的任务参数分了三批（每批 2 个）、前文截到 3 个字，结果按原来的顺序拼起来
        #expect(got?.result?["logprobs"] == .array([.number(-1), .number(-2), .number(-3), .number(-1), .number(-2)]))
        #expect(got?.result?["cache_hit"] == .bool(true))
    }
}
