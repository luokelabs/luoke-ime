import Foundation
import Testing
@testable import LuokeShell

/// `luoke-ime mcp`：螺壳主窗口里的设置页（SettingsService，ADR 0018）。每个测试一份临时的设置和自带引擎。
@Suite final class 主窗口的设置页 {
    private let root: URL
    private let service: SettingsService
    private var paths: Paths { service.paths }

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("luoke-ime-mcp-\(UUID().uuidString)")
        self.root = root
        let bundled = root.appendingPathComponent("bundle/engines")
        try Self.engine(bundled, "xiaohe", #"{"protocol":1,"name":"小鹤双拼","kind":"typing","run":["./x"],"input_keys":"abc"}"#)
        try Self.engine(bundled, "quanpin", #"{"protocol":1,"name":"全拼","kind":"typing","run":["./x"],"input_keys":"abc"}"#)
        try Self.engine(bundled, "personal", #"{"protocol":1,"name":"个人化","kind":"personal","run":["./x"],"permissions":{"memory":true}}"#)
        try Self.engine(bundled, "voice", #"{"protocol":1,"name":"语音","kind":"hotkey","hotkey":{"key":"right_option","mode":"hold"},"run":["./x"],"permissions":{"microphone":true}}"#)
        let p = Paths(root: root.appendingPathComponent("ime"))
        // 没确认过的第三方打字引擎：不能选
        try Self.engine(p.engines, "sneaky", #"{"protocol":1,"name":"第三方","kind":"typing","run":["./x"],"input_keys":"abc"}"#)
        service = SettingsService(paths: p, bundledEngines: bundled, version: "0.0.1", appName: { $0 == "com.example.notes" ? "笔记" : $0 })
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private static func engine(_ dir: URL, _ id: String, _ json: String) throws {
        let d = dir.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try json.write(to: d.appendingPathComponent("engine.json"), atomically: true, encoding: .utf8)
    }

    private func request(_ method: String, _ params: [String: Any] = [:]) -> [String: Any] {
        let line = SettingsService.serialize(["jsonrpc": "2.0", "id": 7, "method": method, "params": params])
        let reply = service.handle(line: line)!
        #expect(!(reply.contains("\n")), "答复要是一行")
        return try! JSONSerialization.jsonObject(with: Data(reply.utf8)) as! [String: Any]
    }

    private let click: [String: Any] = ["ai.luoke/user-action": ["surfaceId": "settings", "componentId": "x", "at": "2026-11-09T18:00:00+08:00"]]

    private func set(_ args: [String: Any], clicked: Bool = true) -> [String: Any] {
        request("tools/call", ["name": "ime_set", "arguments": args, "_meta": clicked ? click : [:]])["result"] as! [String: Any]
    }

    private func page(_ id: String) -> [[String: Any]] {
        let r = request("resources/read", ["uri": "page/\(id)"])["result"] as! [String: Any]
        let text = ((r["contents"] as! [[String: Any]])[0]["text"] as! String)
        return try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [[String: Any]]
    }

    private func components(_ messages: [[String: Any]]) -> [[String: Any]] {
        (messages[1]["updateComponents"] as! [String: Any])["components"] as! [[String: Any]]
    }

    private func texts(_ messages: [[String: Any]]) -> [String] {
        components(messages).filter { $0["component"] as? String == "Text" }.map { $0["text"] as! String }
    }

    private func config() -> ShellConfig { ShellConfig.load(paths.settings) }

    /// 每页：先 createSurface 再 updateComponents；组件编号不重复、引用的都在、不超过 200 个、都在目录里。
    private func checkWellFormed(_ m: [[String: Any]], surface: String) {
        let create = m[0]["createSurface"] as? [String: Any]
        #expect(create?["surfaceId"] as? String == surface)
        #expect(create?["catalogId"] as? String == "ai.luoke/a2ui/agent/1")
        let comps = components(m)
        #expect(comps.count <= SettingsService.maxComponents)
        let ids = comps.map { $0["id"] as! String }
        #expect(Set(ids).count == ids.count, "编号重复：\(ids.filter { id in ids.filter { $0 == id }.count > 1 })")
        #expect(ids.first == "root")
        let known = Set(ids)
        let catalog: Set<String> = ["Text", "Row", "Column", "List", "Card", "Divider", "Button", "CheckBox", "ChoicePicker", "TextField",
                                    "DateTimeInput", "Icon", "ProgressBar"]
        for c in comps {
            #expect(catalog.contains(c["component"] as! String))
            for k in (c["children"] as? [String] ?? []) + [c["child"] as? String].compactMap({ $0 }) {
                #expect(known.contains(k), "\(c["id"]!) 引用了不存在的 \(k)")
            }
        }
    }

    /// 页上所有按钮的动作（工具名、参数）。
    private func actions(_ m: [[String: Any]]) -> [(name: String, context: [String: Any])] {
        components(m).compactMap { c in
            guard let e = (c["action"] as? [String: Any])?["event"] as? [String: Any] else { return nil }
            return (e["name"] as! String, e["context"] as? [String: Any] ?? [:])
        }
    }

    @Test func 答发现_列工具_不认的请求报错() {
        let d = request("server/discover")["result"] as! [String: Any]
        #expect(d["supportedVersions"] as? [String] == ["2026-07-28"])
        let tools = (request("tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]]
        let set = tools.first { $0["name"] as? String == "ime_set" }
        #expect((set?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == false)
        #expect(request("resources/read", ["uri": "page/nope"])["error"] != nil)
        #expect(request("nope")["error"] != nil)
        #expect(service.handle(line: #"{"jsonrpc":"2.0","method":"notifications/x"}"#) == nil, "通知不答")
        #expect(service.handle(line: "not json") != nil)
    }

    /// agent 每轮都读每个工具的 outbox，答错误就当成没在运行（ime-private#30）。没有要报的事时答空列表。
    @Test func outbox_两种写法都答空列表() throws {
        for uri in ["outbox", "luoke://luoke-ime/outbox"] {
            let r = try #require(request("resources/read", ["uri": uri])["result"] as? [String: Any], "\(uri) 要能读")
            let c = try #require((r["contents"] as? [[String: Any]])?.first)
            #expect(c["mimeType"] as? String == "application/json")
            let text = try #require(c["text"] as? String)
            let body = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            #expect((body["items"] as? [Any])?.isEmpty == true)
        }
        #expect(request("resources/read", ["uri": "luoke://luoke-mail/outbox"])["error"] != nil, "别人的 outbox 不认")
    }

    @Test func 设置页和设置窗口的通用页一样_不列没确认的第三方引擎() {
        let m = page("settings")
        checkWellFormed(m, surface: "settings")
        let t = texts(m)
        for s in ["输入方式", "模糊音", "语音", "中英文", "排版", "候选窗口", "联想", "记忆记录", "小鹤双拼", "全拼"] {
            #expect(t.contains(s), "少了「\(s)」")
        }
        #expect(!(t.contains("第三方")), "没确认过的第三方引擎不列")
        #expect(!(t.contains("z = zh")), "模糊音关着时不列六组")
    }

    @Test func 没在螺壳里点过不改() {
        let r = set(["key": "fuzzyOn", "value": true], clicked: false)
        #expect(r["isError"] as? Bool == true)
        #expect((r["structuredContent"] as? [String: Any])?["code"] as? String == "needs_user_action")
        #expect(!(FileManager.default.fileExists(atPath: paths.settings.path)))
    }

    @Test func 改了一项答复里带重画的整页() {
        let r = set(["page": "settings", "key": "fuzzyOn", "value": true])
        #expect(r["isError"] as? Bool == false)
        #expect(config().fuzzyOn)
        let card = (r["structuredContent"] as! [String: Any])["card"] as! [[String: Any]]
        checkWellFormed(card, surface: "settings")
        #expect(texts(card).contains("z = zh"))
        _ = set(["key": "fuzzyPairs.an_ang", "value": false])
        #expect(config().fuzzyActive == ["z_zh", "s_sh", "c_ch", "en_eng", "in_ing"])
    }

    /// 页上的每个按钮点一下都能改成（表和页对得上），值也真的写进去了。
    @Test func 两页上每个按钮点了都能改成() {
        _ = set(["key": "voiceOn", "value": true])
        _ = set(["key": "fuzzyOn", "value": true])
        var c = config()
        c.apps["com.example.notes"] = .init(english: true)
        try! c.save(paths.settings)
        for id in ["settings", "apps"] {
            let m = page(id)
            checkWellFormed(m, surface: id)
            #expect(!(actions(m).isEmpty))
            for a in actions(m) {
                let r = request("tools/call", ["name": a.name, "arguments": a.context, "_meta": click])["result"] as! [String: Any]
                #expect(r["isError"] as? Bool == false, "\(a.context) 没改成：\(r)")
                // 改完把这一项还原，下一个按钮照原来的页
                try! c.save(paths.settings)
            }
        }
    }

    @Test func 只改表里的设置_值的类型不对不改() {
        for (key, value) in [("approvedEngines", ["sneaky": "x"]), ("approved_engines", ["sneaky": "x"]), ("devMode", ["xiaohe"]),
                             ("hub", "/tmp/x"), ("currentEngine", "sneaky"), ("currentEngine", "nope"), ("fuzzyOn", 1),
                             ("fontSize", 99), ("fontSize", true), ("voiceKey", "left_option"), ("fuzzyPairs.zh_ch", true),
                             ("apps.com/../x.english", "on"), ("apps.com.example.other.english", "maybe"), ("apps.com.example.other.nope", "on")] as [(String, Any)] {
            #expect(set(["key": key, "value": value])["isError"] as? Bool == true, "\(key) = \(value) 不该改成")
        }
        #expect(config() == ShellConfig(), "什么都没改")
        #expect(set(["key": "currentEngine", "value": "quanpin"])["isError"] as? Bool == false)
        #expect(config().currentEngine == "quanpin")
        #expect(set(["key": "voiceKey", "value": "right_command"])["isError"] as? Bool == false)
        #expect(config().voiceKey == .rightCommand)
        #expect(set(["key": "fontSize", "value": 18])["isError"] as? Bool == false)
        #expect(config().fontSize == 18)
    }

    @Test func 记忆记录开关改自带个人化组件的那一项() {
        _ = set(["key": "memory", "value": false])
        #expect(config().memoryOff == ["personal"])
        #expect(!(texts(page("settings")).contains("暂停所有记录")), "记录关着时不给暂停")
        _ = set(["key": "memory", "value": true])
        #expect(config().memoryOff == [])
        #expect(texts(page("settings")).contains("暂停所有记录"))
    }

    @Test func 设置文件读不懂时不覆盖() throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try "{ broken".write(to: paths.settings, atomically: true, encoding: .utf8)
        #expect(set(["key": "fuzzyOn", "value": true])["isError"] as? Bool == true)
        #expect(try String(contentsOf: paths.settings, encoding: .utf8) == "{ broken")
        #expect(texts(page("settings")).contains("设置文件无法读取"))
    }

    @Test func 各应用页_点列表里的应用展开_窗口重读时还是它() {
        #expect(texts(page("apps")).contains("暂无单独设置的应用"))
        var c = ShellConfig()
        c.apps["com.example.notes"] = .init(english: true)
        c.apps["com.example.mail"] = .init(noRecord: true)
        try! c.save(paths.settings)
        let list = page("apps")
        checkWellFormed(list, surface: "apps")
        #expect(texts(list).contains("笔记") && texts(list).contains("com.example.mail"))
        #expect(!texts(list).contains("默认输入模式"), "没点之前只列应用")
        // 点「笔记」：只读的 ime_page 记下看哪个；窗口点完重新读页（不带参数），照记下的展开
        let show = actions(list).first { $0.name == "ime_page" && $0.context["app"] as? String == "com.example.notes" }!
        let r = request("tools/call", ["name": "ime_page", "arguments": show.context])["result"] as! [String: Any]
        #expect(r["isError"] as? Bool == false)
        let open = page("apps")
        checkWellFormed(open, surface: "apps")
        #expect(texts(open).contains("默认输入模式") && texts(open).contains("返回列表"))
        #expect(texts(open).contains("com.example.mail"), "别的应用照样列着")
        // 改了一项，重读还展开着
        _ = set(["page": "apps", "app": "com.example.notes", "key": "apps.com.example.notes.inline", "value": "off"])
        #expect(texts(page("apps")).contains("默认输入模式"))
        // 回到列表
        let back = actions(page("apps")).first { $0.name == "ime_page" && $0.context["app"] == nil }!
        _ = request("tools/call", ["name": "ime_page", "arguments": back.context])
        #expect(!texts(page("apps")).contains("默认输入模式"))
        #expect(c.apps.count == 2 && config() != c, "看哪个不改设置；上面那一项改了")
        // 展开着的应用恢复跟随全局以后就不在列表里了，页面回到列表
        _ = request("tools/call", ["name": "ime_page", "arguments": ["page": "apps", "app": "com.example.mail"]])
        _ = set(["page": "apps", "key": "apps.com.example.mail.reset", "value": true])
        #expect(config().apps["com.example.mail"] == nil)
        #expect(!texts(page("apps")).contains("默认输入模式"))
        // 不认识的应用不记
        _ = request("tools/call", ["name": "ime_page", "arguments": ["page": "apps", "app": "com.example.nope"]])
        #expect(service.viewedApp() == nil)
        _ = set(["page": "apps", "app": "com.example.notes", "key": "apps.com.example.notes.english", "value": "follow"])
        _ = set(["page": "apps", "app": "com.example.notes", "key": "apps.com.example.notes.inline", "value": "follow"])
        #expect(config().apps.isEmpty, "没有覆盖项了就整条删掉")
    }

    @Test func 应用很多时也不超过200个组件() {
        var c = ShellConfig()
        for i in 0..<150 { c.apps["com.example.app\(i)"] = .init(english: true) }
        try! c.save(paths.settings)
        checkWellFormed(page("apps"), surface: "apps")
        for app in ["com.example.app0", "com.example.app30", "com.example.app99"] {
            _ = request("tools/call", ["name": "ime_page", "arguments": ["page": "apps", "app": app]])
            checkWellFormed(page("apps"), surface: "apps")
            #expect(texts(page("apps")).contains("返回列表"))
        }
    }

    @Test func 配件清单里的页和动作对得上() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/App/luoke-accessory.json")
        let m = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let caps = m["capabilities"] as! [String: Any]
        #expect(caps["transport"] as? String == "stdio" && caps["protocol"] as? Int == 1)
        #expect(caps["permissions"] == nil, "麦克风照旧由输入法自己要（ADR 0018）")
        let pages = ((caps["service"] as! [String: Any])["pages"] as! [[String: String]]).map { $0["id"]! }
        #expect(pages == SettingsService.pages.map(\.id))
        let writes = (caps["actions"] as! [[String: Any]]).map { $0["name"] as! String }
        let tools = SettingsService.tools.filter { ($0["annotations"] as! [String: Any])["readOnlyHint"] as? Bool == false }.map { $0["name"] as! String }
        #expect(writes == tools, "会改动东西的工具都要列进 actions（协议 §5）")
    }

    @Test func 从键里取应用() {
        #expect(SettingsService.appOf("apps.com.example.notes.english") == "com.example.notes")
        #expect(SettingsService.appOf("apps.english") == nil)
    }
}
