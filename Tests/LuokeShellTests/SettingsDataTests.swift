import Foundation
import Testing
@testable import LuokeShell

/// 主窗口设置页的原始数据（`data/settings`）和数据操作（`ime_do`）：页由 luoke-agent 拼。
/// 场景样例（luoke-agent 工具协议 §11）也在这里录：`LUOKE_RECORD_FIXTURES=1 swift test --filter 设置页的数据` 重录进
/// `fixtures/agent/`，平常跑测试时重录一遍和仓库里的比，不一样就不过。
@Suite(.serialized) final class 设置页的数据 {
    private let root: URL
    private var service: SettingsService
    private var paths: Paths { service.paths }
    /// 录样例时的时钟：2026-11-19 12:00（本机时区），使用计数按它算最近 7 天。
    static let clock = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 12))!

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("luoke-ime-data-\(UUID().uuidString)")
        self.root = root
        let bundled = root.appendingPathComponent("bundle/engines")
        try Self.engine(bundled, "xiaohe", #"{"protocol":1,"name":"小鹤双拼","kind":"typing","run":["./x"],"input_keys":"abc","forget_all":true}"#)
        try Self.engine(bundled, "quanpin", #"{"protocol":1,"name":"全拼","kind":"typing","run":["./x"],"input_keys":"abc","forget_all":true}"#)
        try Self.engine(bundled, "personal", #"{"protocol":1,"name":"个人化","kind":"personal","run":["./x"],"permissions":{"memory":true}}"#)
        try Self.engine(bundled, "voice", #"{"protocol":1,"name":"语音","kind":"hotkey","hotkey":{"key":"right_option","mode":"hold"},"run":["./x"],"permissions":{"microphone":true}}"#)
        service = SettingsService(paths: Paths(root: root.appendingPathComponent("ime")), bundledEngines: bundled, version: "0.0.1",
                                  appName: { ["com.apple.Terminal": "终端", "com.apple.Notes": "备忘录", "com.apple.Safari": "Safari"][$0] ?? $0 })
        service.now = { Self.clock }
        service.requestTimeout = 0.3
        service.voiceTidyDefault = false // 16 GB 的 Mac：默认不整理
        var c = ShellConfig()
        c.currentEngine = "xiaohe"
        try c.save(service.paths.settings)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private static func engine(_ dir: URL, _ id: String, _ json: String) throws {
        let d = dir.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try json.write(to: d.appendingPathComponent("engine.json"), atomically: true, encoding: .utf8)
    }

    // MARK: - 假数据

    /// 平常的：忘掉过两个词、还有三个列不出原文的；七天里有两天没打字。
    private func fillNormal() throws {
        let data = paths.data("xiaohe")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Self.json(["forgotten": [["input": "wo", "text": "窝"], ["input": "ui", "text": "数"]], "older": 3])
            .write(to: data.appendingPathComponent("forgotten.json"))
        let counts: [String: [String: Int]] = [
            "2026-11-13": ["commit": 210, "pick_first": 230, "pick_other": 28, "backspace_after_commit": 15,
                           "predict_shown": 24, "predict_opened": 7, "predict_picked": 5, "predict_chars": 14],
            "2026-11-14": ["commit": 180, "pick_first": 196, "pick_other": 22, "backspace_after_commit": 12],
            "2026-11-16": ["commit": 95, "pick_first": 101, "pick_other": 13, "backspace_after_commit": 6,
                           "predict_shown": 11, "predict_opened": 2, "predict_picked": 2, "predict_chars": 6],
            "2026-11-17": ["commit": 260, "pick_first": 281, "pick_other": 35, "backspace_after_commit": 19],
            "2026-11-18": ["commit": 312, "pick_first": 330, "pick_other": 41, "backspace_after_commit": 22,
                           "predict_shown": 30, "predict_opened": 9, "predict_picked": 6, "predict_chars": 17],
            "2026-11-19": ["commit": 54, "pick_first": 60, "pick_other": 6, "backspace_after_commit": 3],
            "2026-10-01": ["commit": 999], // 七天以前的，不算
        ]
        try Self.json(["version": 1, "days": counts]).write(to: paths.usage)
        try FileManager.default.createDirectory(at: paths.recordsRoot, withIntermediateDirectories: true)
        var c = ShellConfig.load(paths.settings)
        c.devMode = ["xiaohe"]
        c.setApp("com.apple.Notes") { $0.english = true; $0.noRecord = true }
        c.setApp("com.apple.Terminal") { $0.inline = false }
        try c.save(paths.settings)
    }

    private static func json(_ v: Any) -> Data { try! JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) }

    // MARK: - 请求

    private let click: [String: Any] = ["ai.luoke/user-action": ["surfaceId": "settings", "componentId": "x", "at": "2026-11-19T12:00:00+08:00"]]

    private func request(_ method: String, _ params: [String: Any] = [:]) -> (request: [String: Any], reply: [String: Any]) {
        let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        let line = service.handle(line: SettingsService.serialize(req))!
        return (req, try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any])
    }

    private func data(_ which: String = "settings") -> [String: Any] {
        let r = request("resources/read", ["uri": "data/\(which)"]).reply["result"] as! [String: Any]
        let text = (r["contents"] as! [[String: Any]])[0]["text"] as! String
        return try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    private func act(_ args: [String: Any], clicked: Bool = true) -> [String: Any] {
        request("tools/call", ["name": "ime_do", "arguments": args, "_meta": clicked ? click : [:]]).reply["result"] as! [String: Any]
    }

    /// 假的输入法进程：取走请求、照做（恢复就从 forgotten.json 里拿掉那个词），答复成功。
    private final class FakeIME: @unchecked Sendable {
        private let paths: Paths
        private var running = true
        private let lock = NSLock()
        private(set) var seen: [ShellRequests.Request] = []
        init(_ paths: Paths) {
            self.paths = paths
            Thread.detachNewThread { [self] in
                while lock.withLock({ running }) {
                    for r in ShellRequests.take(paths) {
                        lock.withLock { seen.append(r) }
                        if r.op == "restore" { unforget(r.args["input"]!, r.args["text"]!) }
                        ShellRequests.answer(paths, r.id, ["op": r.op, "ok": true])
                    }
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
        }
        func stop() { lock.withLock { running = false } }
        var requests: [ShellRequests.Request] { lock.withLock { seen } }
        private func unforget(_ input: String, _ text: String) {
            let url = paths.data("xiaohe").appendingPathComponent("forgotten.json")
            guard let d = try? Data(contentsOf: url), var o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
            o["forgotten"] = (o["forgotten"] as? [[String: String]] ?? []).filter { !($0["input"] == input && $0["text"] == text) }
            try? JSONSerialization.data(withJSONObject: o).write(to: url)
        }
    }

    // MARK: - 数据

    @Test func 平常的数据_只有代号数字和路径() throws {
        try fillNormal()
        let d = data()
        #expect(d["state"] as? String == "ok")
        let items = d["settings"] as! [[String: Any]]
        let keys = items.map { $0["key"] as! String }
        for k in ["currentEngine", "fuzzyOn", "voiceOn", "voiceKey", "voiceTidy", "defaultEnglish", "fontSize", "pageSize",
                  "orientation", "pagingKeys", "inline", "predict", "memory", "recordingPaused"] {
            #expect(keys.contains(k), "缺 \(k)")
        }
        let engine = items.first { $0["key"] as? String == "currentEngine" }!
        #expect(engine["value"] as? String == "xiaohe")
        #expect((engine["options"] as! [[String: String]]).map { $0["value"]! } == ["quanpin", "xiaohe"])
        let font = items.first { $0["key"] as? String == "fontSize" }!
        #expect(font["min"] as? Int == 10 && font["max"] as? Int == 40 && font["step"] as? Int == 1)

        let learned = d["learned"] as! [String: Any]
        #expect((learned["engine"] as! [String: String]) == ["id": "xiaohe", "name": "小鹤双拼"])
        let f = d["forgotten"] as! [String: Any]
        #expect((f["recent"] as! [[String: String]]).map { $0["text"]! } == ["窝", "数"])
        #expect(f["older"] as? Int == 3)

        let usage = d["usage"] as! [String: Any]
        #expect(usage["personal"] as? Bool == true)
        let days = usage["days"] as! [[String: Any]]
        #expect(days.map { $0["date"] as! String } == ["2026-11-13", "2026-11-14", "2026-11-15", "2026-11-16", "2026-11-17", "2026-11-18", "2026-11-19"])
        #expect((days[2]["counts"] as! [String: Int]).isEmpty, "没打字的那天是空的")
        #expect((days[0]["counts"] as! [String: Int])["predict_chars"] == 14)

        let dev = d["dev"] as! [String: Any]
        #expect((dev["engines"] as! [[String: Any]]).map { "\($0["id"]!)=\($0["on"]!)" } == ["quanpin=0", "xiaohe=1"])
        #expect(dev["log_dir_exists"] as? Bool == true)
        #expect((d["paths"] as! [String: String])["settings"] == paths.settings.path)
        #expect(!SettingsService.serialize(d).contains("已"), "不带句子")
    }

    @Test func 新装没选过输入方案_默认全拼_不看引擎怎么排() throws {
        try FileManager.default.removeItem(at: paths.settings)
        // 排在全拼前面的自带引擎也不会被当成默认
        try Self.engine(root.appendingPathComponent("bundle/engines"), "aaa",
                        #"{"protocol":1,"name":"甲","kind":"typing","run":["./x"],"input_keys":"abc"}"#)
        let engine = (data()["settings"] as! [[String: Any]]).first { $0["key"] as? String == "currentEngine" }!
        #expect(engine["value"] as? String == "quanpin")
    }

    @Test func 各应用的数据_跟随全局时给出实际的值() throws {
        try fillNormal()
        let d = data("apps")
        #expect(d["state"] as? String == "ok" && d["personal"] as? Bool == true)
        let apps = d["apps"] as! [[String: Any]]
        #expect(apps.map { $0["name"] as! String } == ["备忘录", "终端"])
        let notes = Dictionary(uniqueKeysWithValues: (apps[0]["settings"] as! [[String: Any]]).map { ($0["key"] as! String, $0) })
        #expect(notes["apps.com.apple.Notes.english"]?["value"] as? String == "on")
        #expect(notes["apps.com.apple.Notes.inline"]?["value"] as? String == "follow")
        #expect(notes["apps.com.apple.Notes.noRecord"]?["value"] as? Bool == true)
        let term = Dictionary(uniqueKeysWithValues: (apps[1]["settings"] as! [[String: Any]]).map { ($0["key"] as! String, $0) })
        #expect(term["apps.com.apple.Terminal.inline"]?["value"] as? String == "off")
        #expect(term["apps.com.apple.Terminal.predict"]?["follow"] as? Bool == false, "终端里联想默认关")
        #expect(term["apps.com.apple.Terminal.predict"]?["terminal"] as? Bool == true)
        #expect((data("apps")["apps"] as! [Any]).count == 2)
    }

    @Test func 菜单点进来的应用还没设置过_多给一项_改了第一项才记下() throws {
        try fillNormal()
        let r = request("resources/read", ["uri": "data/apps?app=com.apple.Safari"]).reply["result"] as! [String: Any]
        let d = try JSONSerialization.jsonObject(with: Data(((r["contents"] as! [[String: Any]])[0]["text"] as! String).utf8)) as! [String: Any]
        let apps = d["apps"] as! [[String: Any]]
        #expect(apps.map { $0["id"] as! String } == ["com.apple.Safari", "com.apple.Notes", "com.apple.Terminal"])
        #expect(apps[0]["new"] as? Bool == true && apps[1]["new"] == nil)
        #expect((apps[0]["settings"] as! [[String: Any]]).compactMap { $0["value"] as? String }.allSatisfy { $0 == "follow" })
        #expect(ShellConfig.load(paths.settings).apps["com.apple.Safari"] == nil, "只读不记")
        let set = request("tools/call", ["name": "ime_set", "arguments": ["key": "apps.com.apple.Safari.english", "value": "on"], "_meta": click]).reply["result"] as! [String: Any]
        #expect(set["isError"] as? Bool == false)
        #expect(ShellConfig.load(paths.settings).apps["com.apple.Safari"]?.english == true)
        #expect((data("apps")["apps"] as! [[String: Any]]).filter { $0["new"] != nil }.isEmpty)
        // 已经在列表里的、写法不对的：答复和不带参数一样
        for uri in ["data/apps?app=com.apple.Notes", "data/apps?app=a/b"] {
            let r = request("resources/read", ["uri": uri]).reply["result"] as! [String: Any]
            let d = try JSONSerialization.jsonObject(with: Data(((r["contents"] as! [[String: Any]])[0]["text"] as! String).utf8)) as! [String: Any]
            #expect((d["apps"] as! [[String: Any]]).count == 3 && (d["apps"] as! [[String: Any]]).allSatisfy { $0["new"] == nil })
        }
    }

    @Test func 空的数据() {
        #expect((data("apps")["apps"] as! [Any]).isEmpty)
        let d = data()
        #expect((d["forgotten"] as! [String: Any])["older"] as? Int == 0)
        #expect(((d["forgotten"] as! [String: Any])["recent"] as! [Any]).isEmpty)
        let days = (d["usage"] as! [String: Any])["days"] as! [[String: Any]]
        #expect(days.count == 7 && days.allSatisfy { ($0["counts"] as! [String: Int]).isEmpty })
        #expect((d["dev"] as! [String: Any])["log_dir_exists"] as? Bool == false)
    }

    @Test func 设置文件读不懂时只说状态() throws {
        try "{".write(to: paths.settings, atomically: true, encoding: .utf8)
        let d = data()
        #expect(d["state"] as? String == "unreadable")
        #expect(d["settings"] == nil)
    }

    @Test func 资源和工具都列出来_清单里也列了() throws {
        let uris = ((request("resources/list").reply["result"] as! [String: Any])["resources"] as! [[String: Any]]).map { $0["uri"] as! String }
        #expect(uris.contains("data/settings") && uris.contains("data/apps"))
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/App/luoke-accessory.json")
        let caps = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any])["capabilities"] as! [String: Any]
        #expect(caps["data"] as? [String] == SettingsService.dataResources)
    }

    // MARK: - 动作

    @Test func 没在螺壳里点过的不做() {
        let r = act(["op": "reset_usage"], clicked: false)
        #expect(r["isError"] as? Bool == true)
        #expect((r["structuredContent"] as! [String: Any])["code"] as? String == "needs_user_action")
    }

    @Test func 输入法没在运行时答not_running_请求也取回了() throws {
        let r = act(["op": "clear_learned", "engine": "xiaohe"])
        #expect((r["structuredContent"] as! [String: Any])["code"] as? String == "not_running")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: ShellRequests.dir(paths).path)) ?? []
        #expect(left.isEmpty, "没人取走的请求要删掉，免得输入法之后才做")
    }

    @Test func 恢复一个词_答复以后重读已经不在了() throws {
        try fillNormal()
        let ime = FakeIME(paths)
        defer { ime.stop() }
        let id = ((data()["forgotten"] as! [String: Any])["recent"] as! [[String: String]])[0]["id"]!
        let r = act(["op": "restore", "id": id])
        #expect(r["isError"] as? Bool == false)
        #expect(((r["structuredContent"] as! [String: Any])["data"] as! [String: String]) == ["op": "restore", "id": id])
        #expect(ime.requests.map(\.args) == [["input": "wo", "text": "窝"]])
        #expect(((data()["forgotten"] as! [String: Any])["recent"] as! [[String: String]]).map { $0["text"]! } == ["数"])
        #expect((act(["op": "restore", "id": "nope"])["structuredContent"] as! [String: Any])["code"] as? String == "invalid")
    }

    @Test func 清除和清零交给输入法() {
        let ime = FakeIME(paths)
        defer { ime.stop() }
        #expect(act(["op": "clear_learned", "engine": "xiaohe"])["isError"] as? Bool == false)
        #expect(act(["op": "reset_usage"])["isError"] as? Bool == false)
        #expect(ime.requests.map(\.op) == ["clear_learned", "reset_usage"])
        #expect(ime.requests[0].args == ["engine": "xiaohe"])
    }

    @Test func 开发模式改设置文件_只认能选的打字引擎() {
        #expect(act(["op": "dev_mode", "engine": "quanpin", "on": true])["isError"] as? Bool == false)
        #expect(ShellConfig.load(paths.settings).devMode == ["quanpin"])
        #expect(act(["op": "dev_mode", "engine": "quanpin", "on": false])["isError"] as? Bool == false)
        #expect(ShellConfig.load(paths.settings).devMode.isEmpty)
        #expect((act(["op": "dev_mode", "engine": "personal", "on": true])["structuredContent"] as! [String: Any])["code"] as? String == "invalid")
        #expect((act(["op": "nope"])["structuredContent"] as! [String: Any])["code"] as? String == "invalid")
    }

    @Test func 过期的请求不做_没人拿的答复会清掉() throws {
        let d = ShellRequests.dir(paths)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try Self.json(["op": "reset_usage"]).write(to: d.appendingPathComponent("old.json"))
        try Self.json(["ok": true]).write(to: d.appendingPathComponent("old.done"))
        #expect(ShellRequests.take(paths, now: Date().addingTimeInterval(120)).isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).isEmpty)
    }

    // MARK: - 场景样例（工具协议 §11）

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../fixtures/agent").standardized

    /// 一步：录成哪个文件、做了什么（写进 scenario.json）、发的请求。
    private typealias Step = (file: String, does: String, method: String, params: [String: Any])

    /// 一个场景：照先后发每一步；`ime` 为 true 时有假的输入法在答复。
    private func record(_ situation: String, ime: Bool, fill: () throws -> Void, steps: [Step]) throws -> [String: Data] {
        try fill()
        let fake = ime ? FakeIME(paths) : nil
        defer { fake?.stop() }
        var files: [String: Data] = [:]
        let meta: [String: Any] = ["io.modelcontextprotocol/protocolVersion": SettingsService.protocolVersion]
        for (name, _, method, params) in steps {
            var p = params
            p["_meta"] = (p["_meta"] as? [String: Any] ?? [:]).merging(meta) { $1 }
            var (req, reply) = request(method, p)
            // resources/read 的 text 在线上是一段 JSON 文字，这里解开
            if var r = reply["result"] as? [String: Any], var c = r["contents"] as? [[String: Any]], let t = c.first?["text"] as? String,
               let v = try? JSONSerialization.jsonObject(with: Data(t.utf8)) {
                c[0]["text"] = v
                r["contents"] = c
                reply["result"] = r
            }
            req["id"] = 1
            files[name + ".json"] = normalized(["request": req, "reply": reply])
        }
        let manifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/App/luoke-accessory.json")
        // 版本号每次改动都升，样例里写成固定的，免得只升版本也要重录
        var m = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        m["version"] = "0.0.0"
        files["manifest.json"] = normalized(m)
        files["scenario.json"] = normalized(["situation": situation, "steps": steps.map { ["clock": Self.clockISO, "do": $0.does, "file": $0.file + ".json"] }])
        return files
    }

    /// 临时目录换成用户目录的写法，JSON 按键排序、缩进两格。
    private func normalized(_ v: Any) -> Data {
        let d = try! JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let s = String(decoding: d, as: UTF8.self).replacingOccurrences(of: paths.root.path, with: "~/.luoke/ime")
        return Data((s + "\n").utf8)
    }

    /// scenario.json 里写的时钟。日期按本机时区的中午算，东西十一个时区以内录出来都一样。
    static let clockISO = "2026-11-19T12:00:00+08:00"

    private func scene(_ name: String) throws -> [String: Data] {
        let read: [String: Any] = ["uri": "data/settings"]
        let readApps: [String: Any] = ["uri": "data/apps"]
        func call(_ tool: String, _ args: [String: Any]) -> [String: Any] { ["name": tool, "arguments": args, "_meta": click] }
        /// 「各应用」页上的点按：surfaceId 是页名 apps
        func callApps(_ args: [String: Any]) -> [String: Any] {
            ["name": "ime_set", "arguments": args, "_meta": ["ai.luoke/user-action": ["surfaceId": "apps", "componentId": "x", "at": "2026-11-19T12:00:00+08:00"]]]
        }
        /// 核心接上来先问的：发现、工具、资源，每分钟读的 outbox，「各应用」页（还是输入法画的 A2UI 页）
        let connect: [Step] = [
            ("server-discover", "核心接上来先问能做什么", "server/discover", [:]),
            ("tools-list", "列工具", "tools/list", [:]),
            ("resources-list", "列资源", "resources/list", [:]),
            ("read-outbox", "核心每分钟读一次 outbox（输入法没有要报的事，答空列表）", "resources/read", ["uri": "luoke://luoke-ime/outbox"]),
            ("read-page-apps", "打开「各应用」页（还是输入法画的 A2UI 页，没有单独设置的应用）", "resources/read", ["uri": "page/apps"]),
            ("read-data-settings", "打开设置页，读数据", "resources/read", read),
            ("read-data-apps", "打开「各应用」页，读数据", "resources/read", readApps),
        ]
        if name == "normal" {
            return try record("平常：小鹤双拼，忘掉过两个词、另有三个列不出原文；最近七天里 11-15 没有打字；小鹤开着开发模式，记录文件夹在；输入法在运行",
                              ime: true, fill: fillNormal, steps: connect + [
                ("call-ime_do-restore", "恢复已忘记的「窝」", "tools/call", call("ime_do", ["op": "restore", "id": SettingsService.forgottenID("wo", "窝")])),
                ("read-data-settings-after-restore", "重读：「窝」不在已忘记的列表里了", "resources/read", read),
                ("call-ime_do-clear_learned", "确认后清除小鹤双拼的已学词语", "tools/call", call("ime_do", ["op": "clear_learned", "engine": "xiaohe"])),
                ("call-ime_do-reset_usage", "确认后清零使用统计", "tools/call", call("ime_do", ["op": "reset_usage"])),
                ("call-ime_do-dev_mode", "关掉小鹤双拼的开发模式", "tools/call", call("ime_do", ["op": "dev_mode", "engine": "xiaohe", "on": false])),
                ("call-ime_set-fontSize", "字号改成 18", "tools/call", call("ime_set", ["key": "fontSize", "value": 18])),
                ("read-data-settings-after-set", "重读：字号 18，开发模式关了", "resources/read", read),
                ("call-ime_set-app-predict", "终端里打开联想", "tools/call", callApps(["key": "apps.com.apple.Terminal.predict", "value": "on"])),
                ("call-ime_set-app-reset", "备忘录恢复跟随全局", "tools/call", callApps(["key": "apps.com.apple.Notes.reset", "value": true])),
                ("read-data-apps-after-set", "重读：终端联想开，备忘录各项跟随全局", "resources/read", readApps),
                ("read-data-apps-target", "在 Safari 里从输入法菜单点「此应用设置」：带 app 读，Safari 还没有单独设置，多给一项 new", "resources/read",
                 ["uri": "data/apps?app=com.apple.Safari"]),
                ("call-ime_set-new-app", "Safari 默认英文", "tools/call", callApps(["key": "apps.com.apple.Safari.english", "value": "on"])),
                ("read-data-apps-after-new", "不带参数重读：Safari 进了列表", "resources/read", readApps),
            ])
        }
        return try record("空的：没学到词、没有忘掉过的词、没有使用计数，没开开发模式，记录文件夹不在；输入法没在运行",
                          ime: false, fill: {}, steps: connect + [
            ("call-ime_do-clear_learned-not-running", "确认后清除已学词语：输入法没在运行，答 not_running", "tools/call",
             call("ime_do", ["op": "clear_learned", "engine": "xiaohe"])),
        ])
    }

    @Test(arguments: ["normal", "empty"]) func 场景样例和仓库里的一样(_ name: String) throws {
        let files = try scene(name)
        let dir = Self.fixtures.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["LUOKE_RECORD_FIXTURES"] == "1" {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (n, d) in files { try d.write(to: dir.appendingPathComponent(n)) }
            return
        }
        let have = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        #expect(have == Set(files.keys), "场景 \(name) 的文件对不上：LUOKE_RECORD_FIXTURES=1 重录")
        for (n, d) in files {
            let old = try? Data(contentsOf: dir.appendingPathComponent(n))
            #expect(old == d, "场景 \(name) 的 \(n) 变了：LUOKE_RECORD_FIXTURES=1 swift test --filter 设置页的数据 重录，并告诉 luoke-agent")
        }
    }
}
