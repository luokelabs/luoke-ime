import Foundation

/// 螺壳主窗口里的「螺壳输入法」应用页：`luoke-ime mcp` 每次答一个请求（luoke-agent 工具协议 §2a），
/// 页面照现在的设置文件画（A2UI，协议 §4），用户在页上点了，改设置文件（ADR 0018）。
///
/// 和输入法自己的设置窗口并存，改的是同一份 `~/.luoke/ime/settings.json`：正在运行的输入法每秒看一次修改时间，
/// 读到了马上生效，自己存盘前也先读一遍外面改过的。这里只改一张写死的表（`SettingsService.apply`），
/// 确认第三方引擎、主控地址、开发模式这些不在表里；学到的词、忘掉的词要经正在运行的打字引擎，留在输入法自己的窗口。
public struct SettingsService {
    public static let protocolVersion = "2026-07-28"
    public static let catalogId = "ai.luoke/a2ui/agent/1"
    public static let userAction = "ai.luoke/user-action"
    /// 协议 §4：每页最多 200 个组件。
    public static let maxComponents = 200
    /// 「各应用」页最多列几个应用（每个占两个组件，其余留给选中那个的设置）。
    static let maxListedApps = 60

    public static let pages: [(id: String, title: String)] = [("settings", "设置"), ("apps", "各应用")]

    public var paths: Paths
    public var bundledEngines: URL?
    public var version: String
    /// 应用的名字（命令行用 NSWorkspace 查；这一层只依赖 Foundation）。
    public var appName: (String) -> String

    public init(paths: Paths, bundledEngines: URL?, version: String, appName: @escaping (String) -> String = { $0 }) {
        self.paths = paths
        self.bundledEngines = bundledEngines
        self.version = version
        self.appName = appName
    }

    // MARK: - 请求

    /// 答一行请求；没有 `id` 的通知不答（nil）。
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data) else {
            return Self.serialize(Self.rpcError(nil, -32700, "不是 JSON"))
        }
        guard let reply = handle(any) else { return nil }
        return Self.serialize(reply)
    }

    func handle(_ message: Any) -> [String: Any]? {
        guard let msg = message as? [String: Any], msg["jsonrpc"] as? String == "2.0", let method = msg["method"] as? String else {
            return Self.rpcError((message as? [String: Any])?["id"], -32600, "不是 JSON-RPC 2.0 请求")
        }
        guard let rid = msg["id"] else { return nil }
        let params = msg["params"] ?? [String: Any]()
        guard let p = params as? [String: Any] else { return Self.rpcError(rid, -32602, "params 要是对象") }
        let meta = p["_meta"] as? [String: Any] ?? [:]
        if let v = meta["io.modelcontextprotocol/protocolVersion"], v as? String != Self.protocolVersion {
            return Self.rpcError(rid, -32602, "不支持这个协议版本", data: ["supportedVersions": [Self.protocolVersion]])
        }
        switch method {
        case "server/discover":
            return Self.result(rid, ["supportedVersions": [Self.protocolVersion], "capabilities": ["tools": [:], "resources": [:]],
                                     "_meta": ["io.modelcontextprotocol/serverInfo": ["name": "luoke-ime", "version": version]]])
        case "resources/list":
            return Self.result(rid, ["resources": Self.pages.map { ["uri": "page/\($0.id)", "name": $0.title, "mimeType": "application/json"] }])
        case "resources/read":
            let uri = p["uri"] as? String ?? ""
            // agent 每轮都读 outbox，答错误会被当成输入法没在运行（工具协议 §2、§3）。输入法现在没有要报的事。
            if uri == "outbox" || uri == "luoke://luoke-ime/outbox" {
                return Self.result(rid, ["contents": [["uri": uri, "mimeType": "application/json",
                                                       "text": Self.serialize(["items": [Any]()])]]])
            }
            guard uri.hasPrefix("page/"), let page = Self.pages.first(where: { "page/\($0.id)" == uri })?.id else {
                return Self.rpcError(rid, -32002, "没有这个资源", data: ["uri": uri])
            }
            let state = load()
            return Self.result(rid, ["contents": [["uri": uri, "mimeType": "application/json",
                                                   "text": Self.serialize(messages(page, state: state, app: viewedApp()))]]])
        case "tools/list":
            return Self.result(rid, ["tools": Self.tools])
        case "tools/call":
            return call(rid, p, meta)
        default:
            return Self.rpcError(rid, -32601, "没有这个方法：\(method)")
        }
    }

    static let tools: [[String: Any]] = [
        ["name": "ime_set", "title": "修改输入法设置",
         "description": "改一项输入法设置（只在用户点了页上的按钮时调）",
         "inputSchema": ["type": "object", "required": ["key", "value"],
                         "properties": ["page": ["type": "string"], "app": ["type": "string"], "key": ["type": "string"], "value": [:]]],
         "annotations": ["readOnlyHint": false]],
        ["name": "ime_page", "title": "选择「各应用」页展开的应用",
         "description": "带 app 展开这个应用的设置，不带回到列表（只记在 window-page.json 里，不改输入法的行为）",
         "inputSchema": ["type": "object", "properties": ["page": ["type": "string"], "app": ["type": "string"]]],
         "annotations": ["readOnlyHint": true]],
    ]

    private func call(_ rid: Any, _ p: [String: Any], _ meta: [String: Any]) -> [String: Any] {
        let name = p["name"] as? String ?? ""
        guard name == "ime_set" || name == "ime_page" else { return Self.rpcError(rid, -32602, "没有这个工具：\(name.isEmpty ? "?" : name)") }
        guard let args = (p["arguments"] ?? [String: Any]()) as? [String: Any] else { return Self.rpcError(rid, -32602, "arguments 要是对象") }
        let page = Self.pages.contains { $0.id == args["page"] as? String } ? args["page"] as! String : "settings"
        if name == "ime_page" {
            // 窗口点完按钮重新读 page/<id>、不带参数（luoke-agent 界面接口 §6）：看哪个应用记在文件里，读页时照它画
            let state = load()
            let app = (args["app"] as? String).flatMap { state.config?.apps[$0] != nil ? $0 : nil }
            saveViewedApp(app)
            return Self.result(rid, ["content": [["type": "text", "text": "已修改"]], "isError": false,
                                     "structuredContent": ["card": messages(page, state: state, app: app)]])
        }
        guard Self.validUserAction(meta[Self.userAction]) else {
            return Self.result(rid, Self.toolError("needs_user_action", "此设置需由用户在螺壳窗口中修改"))
        }
        var state = load()
        guard var config = state.config else { return Self.result(rid, Self.toolError("failed", "设置文件无法读取，未修改；可在输入法菜单的「设置…」中修改")) }
        guard !config.migratedFromV1 else { return Self.result(rid, Self.toolError("not_ready", "输入法设置尚未升级为新版本，使用输入法后即可修改")) }
        guard let key = args["key"] as? String, let value = args["value"] else { return Self.result(rid, Self.toolError("invalid", "缺少参数：key、value")) }
        switch apply(key: key, value: value, to: &config, state: state) {
        case .failure(let message):
            return Self.result(rid, Self.toolError("invalid", message))
        case .success(let text):
            do { try config.save(paths.settings) } catch {
                return Self.result(rid, Self.toolError("failed", "设置保存失败，请重试"))
            }
            state.config = config
            return Self.result(rid, ["content": [["type": "text", "text": text]], "isError": false,
                                     "structuredContent": ["card": messages(page, state: state, app: viewedApp())]])
        }
    }

    static func validUserAction(_ v: Any?) -> Bool {
        guard let o = v as? [String: Any] else { return false }
        return ["surfaceId", "componentId", "at"].allSatisfy { !((o[$0] as? String) ?? "").isEmpty }
    }

    // MARK: - 「各应用」页看的是哪个

    /// 只记页面上展开的是哪个应用（`{"apps": "<bundle id>"}`），不是设置：输入法不读它。
    var viewFile: URL { paths.root.appendingPathComponent("window-page.json") }

    func viewedApp() -> String? {
        guard let d = try? Data(contentsOf: viewFile), let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return m["apps"] as? String
    }

    func saveViewedApp(_ app: String?) {
        guard let app else { try? FileManager.default.removeItem(at: viewFile); return }
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try? Data(Self.serialize(["apps": app]).utf8).write(to: viewFile, options: .atomic)
    }

    // MARK: - 状态

    struct State {
        /// nil：设置文件在，但读不懂。
        var config: ShellConfig?
        var catalog: EngineCatalog
    }

    func load() -> State {
        let config = ShellConfig.loadIfValid(paths.settings)
        return State(config: config, catalog: .scan(bundled: bundledEngines, user: paths.engines, approved: config?.approvedEngines ?? [:]))
    }

    /// 能选的输入方案：自带的和确认过的第三方打字引擎。
    func typingChoices(_ s: State, _ c: ShellConfig) -> [(id: String, name: String)] {
        s.catalog.typing.filter { EngineCatalog.usable($0, approved: c.approvedEngines) }.map { ($0.id, $0.manifest?.name ?? $0.id) }
    }

    func personal(_ s: State, _ c: ShellConfig) -> EngineCatalog.Entry? { s.catalog.personal(approved: c.approvedEngines) }

    func hasVoice(_ s: State, _ c: ShellConfig) -> Bool {
        s.catalog.entries.contains { e in e.manifest.map(EngineCatalog.isVoice) == true && EngineCatalog.usable(e, approved: c.approvedEngines) }
    }

    // MARK: - 改设置：写死的一张表

    enum Applied { case success(String), failure(String) }

    static let switches: [String: (title: String, get: (ShellConfig) -> Bool, set: (inout ShellConfig, Bool) -> Void)] = [
        "fuzzyOn": ("模糊音", { $0.fuzzyOn }, { $0.fuzzyOn = $1 }),
        "voiceOn": ("语音输入", { $0.voiceOn }, { $0.voiceOn = $1 }),
        "voiceTidy": ("语音整理", { $0.voiceTidyActive }, { $0.voiceTidy = $1 }),
        "defaultEnglish": ("进入应用时默认英文", { $0.defaultEnglish }, { $0.setDefaultEnglish($1) }),
        "rememberMode": ("记住各应用上次的中英文模式", { $0.rememberMode }, { $0.setRememberMode($1) }),
        "shiftToggles": ("单按 Shift 切换中英文", { $0.settings.shiftToggles }, { $0.settings.shiftToggles = $1 }),
        "autoSpace": ("中英文之间自动加空格", { $0.settings.autoSpace }, { $0.settings.autoSpace = $1 }),
        "cornerBraces": ("中文状态下 { } 输入为「」", { $0.settings.cornerBraces }, { $0.settings.cornerBraces = $1 }),
        "inline": ("拼音显示在输入框中", { $0.inline }, { $0.inline = $1 }),
        "predict": ("联想", { $0.settings.predict }, { $0.settings.predict = $1 }),
        "recordingPaused": ("暂停所有记录", { $0.recordingPaused }, { $0.recordingPaused = $1 }),
    ]

    func apply(key: String, value: Any, to c: inout ShellConfig, state: State) -> Applied {
        let bad = Applied.failure("值无效，未修改")
        if let s = Self.switches[key] {
            guard let v = Self.bool(value) else { return bad }
            s.set(&c, v)
            return .success(v ? "已开启「\(s.title)」" : "已关闭「\(s.title)」")
        }
        if key.hasPrefix("fuzzyPairs.") {
            let pair = String(key.dropFirst("fuzzyPairs.".count))
            guard ShellConfig.fuzzyChoices.contains(pair), let v = Self.bool(value) else { return bad }
            if v { c.fuzzyPairs.insert(pair) } else { c.fuzzyPairs.remove(pair) }
            return .success("模糊音 \(Self.pairName(pair))：\(v ? "已开启" : "已关闭")")
        }
        if key.hasPrefix("apps.") { return applyApp(key: key, value: value, to: &c) }
        switch key {
        case "currentEngine":
            guard let id = value as? String, let e = typingChoices(state, c).first(where: { $0.id == id }) else { return bad }
            c.currentEngine = e.id
            return .success("输入方案：「\(e.name)」")
        case "voiceKey":
            guard let raw = value as? String, let k = Manifest.Hotkey.Key(rawValue: raw) else { return bad }
            c.voiceKey = k == .rightOption ? nil : k
            return .success("语音输入按键：\(Self.voiceKeyName(k))")
        case "orientation":
            guard let raw = value as? String, let o = ShellSettings.Orientation(rawValue: raw) else { return bad }
            c.settings.orientation = o
            return .success(o == .horizontal ? "候选排列：横排" : "候选排列：竖排")
        case "pagingKeys":
            guard let raw = value as? String, let k = ShellSettings.PagingKeys(rawValue: raw) else { return bad }
            c.settings.pagingKeys = k
            return .success("翻页键：\(Self.pagingName(k))")
        case "fontSize":
            guard let n = Self.int(value), (10...40).contains(n) else { return bad }
            c.fontSize = Double(n)
            return .success("字号：\(n)")
        case "pageSize":
            guard let n = Self.int(value), (1...9).contains(n) else { return bad }
            c.settings.pageSize = n
            return .success("每页候选数：\(n)")
        case "memory":
            guard let v = Self.bool(value), let p = personal(state, c) else { return bad }
            c.setMemory(key: EngineCatalog.consentKey(p), bundled: p.bundled, on: v)
            return .success(v ? "已开启记忆记录" : "已关闭记忆记录，已有记录保留")
        default:
            return .failure("未知设置，未修改")
        }
    }

    /// `apps.<bundle id>.<项>`：只改已经有单独设置的应用（应用是在输入法菜单的「此应用设置」里加的）。
    private func applyApp(key: String, value: Any, to c: inout ShellConfig) -> Applied {
        let bad = Applied.failure("值无效，未修改")
        guard let app = Self.appOf(key), c.apps[app] != nil, let item = key.split(separator: ".").last.map(String.init) else {
            return .failure("此应用没有单独设置，未修改")
        }
        let name = appName(app)
        if item == "reset" {
            c.setApp(app) { $0 = .init() }
            return .success("「\(name)」已恢复跟随全局")
        }
        if item == "noRecord" {
            guard let v = Self.bool(value) else { return bad }
            c.setApp(app) { $0.noRecord = v }
            return .success(v ? "「\(name)」：禁止记录" : "「\(name)」：记忆记录跟随全局")
        }
        let paths: [String: WritableKeyPath<ShellConfig.AppSettings, Bool?>] = ["english": \.english, "inline": \.inline, "predict": \.predict]
        guard let path = paths[item], let raw = value as? String, ["follow", "on", "off"].contains(raw) else { return .failure("未知设置，未修改") }
        c.setApp(app) { $0[keyPath: path] = raw == "follow" ? nil : raw == "on" }
        return .success("「\(name)」设置已修改")
    }

    /// `apps.com.example.app.english` 里的应用：去掉开头的 apps. 和最后一段。
    static func appOf(_ key: String) -> String? {
        let start = key.index(key.startIndex, offsetBy: 5, limitedBy: key.endIndex) ?? key.endIndex
        guard key.hasPrefix("apps."), let dot = key.lastIndex(of: "."), dot > start else { return nil }
        let app = String(key[start..<dot])
        return app.isEmpty ? nil : app
    }

    // MARK: - 页

    func messages(_ page: String, state: State, app: String?) -> [[String: Any]] {
        var b = PageBuilder(page: page)
        if let c = state.config {
            if page == "apps" { appsPage(&b, c, state, selected: app) } else { settingsPage(&b, c, state) }
        } else {
            b.section("broken") { b in
                b.text("broken-t", "设置文件无法读取", variant: "h4")
                b.text("broken-c", "~/.luoke/ime/settings.json 可能已损坏，输入法继续使用原有设置；在输入法菜单的「设置…」中修改任一项后将重新写入", variant: "caption")
            }
        }
        return b.messages()
    }

    private func settingsPage(_ b: inout PageBuilder, _ c: ShellConfig, _ s: State) {
        let engines = typingChoices(s, c)
        let current = s.catalog.current(c)?.id
        b.section("input", "输入方式") { b in
            b.choice("engine", "输入方案", engines.map { ($0.name, $0.id as Any, $0.id == current) }, key: "currentEngine")
        }
        b.section("fuzzy", "模糊音") { b in
            b.toggle("fuzzy", "模糊音", on: c.fuzzyOn, key: "fuzzyOn")
            if c.fuzzyOn {
                for pair in ShellConfig.fuzzyChoices {
                    b.toggle("fuzzy-\(pair)", Self.pairName(pair), on: c.fuzzyPairs.contains(pair), key: "fuzzyPairs.\(pair)")
                }
            }
            b.text("fuzzy-note", "开启后同时给出拼法相近的字，准确的候选可能排序靠后", variant: "caption")
        }
        if hasVoice(s, c) {
            let key = c.voiceKey ?? .rightOption
            b.section("voice", "语音") { b in
                b.toggle("voice", "语音输入", on: c.voiceOn, key: "voiceOn")
                if c.voiceOn {
                    b.choice("voice-key", "语音输入按键", [Manifest.Hotkey.Key.rightOption, .rightCommand, .rightControl].map {
                        (Self.voiceKeyName($0), $0.rawValue as Any, $0 == key)
                    }, key: "voiceKey")
                    b.text("voice-key-note", "使用外接 Windows 键盘或在系统设置中对调过修饰键时，右 Alt 可能被识别为右 ⌘，此时请选择右 ⌘", variant: "caption")
                    b.toggle("voice-tidy", "语音整理：去除口头禅、修正改口、整理列表和分段", on: c.voiceTidyActive, key: "voiceTidy")
                }
                b.text("voice-note", c.voiceOn && !ShellConfig.voiceTidyDefault
                       ? "按住所选按键说话，松开后上屏；识别和整理均由螺壳在本机完成；内存 24 GB 及以下的 Mac 上整理耗时数秒，默认关闭"
                       : "按住所选按键说话，松开后上屏；识别和整理均由螺壳在本机完成；首次使用时系统将请求麦克风权限", variant: "caption")
            }
        }
        b.section("lang", "中英文") { b in
            b.choice("default-lang", "进入应用时的默认模式", [("中文", false as Any, !c.defaultEnglish), ("英文", true as Any, c.defaultEnglish)], key: "defaultEnglish")
            b.toggle("remember", "记住各应用上次的中英文模式", on: c.rememberMode, key: "rememberMode")
            b.toggle("shift", "单按 Shift 切换中英文", on: c.settings.shiftToggles, key: "shiftToggles")
        }
        b.section("typeset", "排版") { b in
            b.toggle("space", "中英文之间自动加空格", on: c.settings.autoSpace, key: "autoSpace")
            b.toggle("braces", "中文状态下 { } 输入为「」", on: c.settings.cornerBraces, key: "cornerBraces")
        }
        b.section("window", "候选窗口") { b in
            b.stepper("font", "字号：\(Int(c.fontSize))", value: Int(c.fontSize), range: 10...40, key: "fontSize", less: "减小字号", more: "增大字号")
            b.choice("orient", "候选排列", [("横排", "horizontal" as Any, c.settings.orientation == .horizontal),
                                         ("竖排", "vertical" as Any, c.settings.orientation == .vertical)], key: "orientation")
            b.stepper("pagesize", "每页候选数：\(c.settings.pageSize)", value: c.settings.pageSize, range: 1...9, key: "pageSize",
                      less: "减少候选数", more: "增加候选数")
            b.choice("paging", "翻页键", [ShellSettings.PagingKeys.minusEqual, .commaPeriod].map {
                (Self.pagingName($0), $0.rawValue as Any, $0 == c.settings.pagingKeys)
            }, key: "pagingKeys")
            b.choice("inline", "拼音显示位置", [("输入框", true as Any, c.inline), ("候选窗口", false as Any, !c.inline)], key: "inline")
        }
        if let p = personal(s, c) {
            let on = c.memoryEnabled(key: EngineCatalog.consentKey(p), bundled: p.bundled)
            b.section("predict", "联想") { b in
                b.toggle("predict", "联想", on: c.settings.predict, key: "predict")
                b.text("predict-note", "按 Tab 选用推荐", variant: "caption")
            }
            b.section("memory", "记忆记录") { b in
                b.toggle("memory", "记录输入内容到记忆", on: on, key: "memory")
                b.text("memory-note", "保存在本机的螺壳记忆中，用于联想和候选排序；关闭后已有记录保留", variant: "caption")
                if on {
                    b.toggle("paused", "暂停所有记录", on: c.recordingPaused, key: "recordingPaused")
                    b.text("paused-note", "暂停期间不记录，可随时恢复", variant: "caption")
                }
            }
        }
        b.section("more") { b in
            b.text("more-note", "已学词语、已忘记词语、使用统计和开发模式位于输入法菜单的「设置…」中", variant: "caption")
        }
    }

    /// 上面是有单独设置的应用的列表，点一个（`ime_page`）就在列表里展开它的设置，带「回到列表」。
    private func appsPage(_ b: inout PageBuilder, _ c: ShellConfig, _ s: State, selected: String?) {
        let apps = c.apps.keys.map { ($0, appName($0)) }.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
        guard !apps.isEmpty else {
            b.section("empty") { b in
                b.text("empty-t", "暂无单独设置的应用", variant: "h4")
                b.text("empty-c", "在应用中打开输入法菜单，选择「此应用设置」", variant: "caption")
            }
            return
        }
        let open = apps.firstIndex { $0.0 == selected }
        let shown = Array(apps.prefix(Self.maxListedApps))
        let before = open.map { Array(apps[..<$0].prefix(Self.maxListedApps)) } ?? shown
        let after = open.map { Array(apps[($0 + 1)...].prefix(max(0, Self.maxListedApps - $0 - 1))) } ?? []
        b.section("list", "应用单独设置") { b in
            for (id, name) in before { b.button("app-\(Self.slug(id))", name, action: "ime_page", context: ["page": "apps", "app": id]) }
        }
        if let i = open { appDetail(&b, c, s, apps[i]) }
        if !after.isEmpty {
            b.section("list2") { b in
                for (id, name) in after { b.button("app-\(Self.slug(id))", name, action: "ime_page", context: ["page": "apps", "app": id]) }
            }
        }
        b.section("list-end") { b in
            if apps.count > Self.maxListedApps {
                b.text("list-more", "另有 \(apps.count - Self.maxListedApps) 个应用，可在输入法菜单的「设置…」中查看", variant: "caption")
            }
            b.text("list-note", "为其他应用单独设置：在该应用中打开输入法菜单，选择「此应用设置」", variant: "caption")
        }
    }

    private func appDetail(_ b: inout PageBuilder, _ c: ShellConfig, _ s: State, _ app: (String, String)) {
        let a = c.app(app.0)
        let hasPersonal = personal(s, c) != nil
        b.section("detail", app.1) { b in
            b.choice("english", "默认输入模式", [("跟随全局（\(c.defaultEnglish ? "英文" : "中文")）", "follow", a.english == nil),
                                                ("中文", "off", a.english == false), ("英文", "on", a.english == true)],
                     key: "apps.\(app.0).english", app: app.0)
            b.choice("inline", "拼音显示位置", [("跟随全局（\(c.inline ? "输入框" : "候选窗口")）", "follow", a.inline == nil),
                                             ("输入框", "on", a.inline == true), ("候选窗口", "off", a.inline == false)],
                     key: "apps.\(app.0).inline", app: app.0)
            if hasPersonal {
                let follow = ShellConfig.terminals.contains(app.0) ? "跟随默认（终端中关闭）" : "跟随全局（\(c.settings.predict ? "开启" : "关闭")）"
                b.choice("predict", "联想", [(follow, "follow", a.predict == nil), ("开启", "on", a.predict == true), ("关闭", "off", a.predict == false)],
                         key: "apps.\(app.0).predict", app: app.0)
                b.toggle("norecord", "在此应用中禁止记录", on: a.noRecord, key: "apps.\(app.0).noRecord", app: app.0)
                b.text("norecord-note", "全局记录关闭或暂停时，此应用同样不记录", variant: "caption")
            }
            b.button("reset", "恢复跟随全局", action: "ime_set", context: ["page": "apps", "app": app.0, "key": "apps.\(app.0).reset", "value": true])
            b.button("back", "返回列表", action: "ime_page", context: ["page": "apps"])
        }
    }

    /// 组件编号里用的应用标识（bundle id 里只有字母、数字、点和连字符，点换掉）。
    static func slug(_ id: String) -> String { id.replacingOccurrences(of: ".", with: "_") }

    // MARK: - 文字

    static func voiceKeyName(_ k: Manifest.Hotkey.Key) -> String {
        switch k {
        case .rightOption: return "右 ⌥（Alt）"
        case .rightCommand: return "右 ⌘"
        case .rightControl: return "右 ⌃"
        }
    }

    static func pagingName(_ k: ShellSettings.PagingKeys) -> String { k == .minusEqual ? "- 和 =" : ", 和 ." }
    static func pairName(_ pair: String) -> String { pair.replacingOccurrences(of: "_", with: " = ") }

    // MARK: - JSON

    /// 布尔值只认真的 true / false（NSNumber 的 1 不算）。
    static func bool(_ v: Any) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    static func int(_ v: Any) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d == d.rounded() && abs(d) < 1e6 ? Int(d) : nil
    }

    static func result(_ rid: Any, _ r: [String: Any]) -> [String: Any] {
        var r = r
        r["resultType"] = "complete"
        return ["jsonrpc": "2.0", "id": rid, "result": r]
    }

    static func toolError(_ code: String, _ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "structuredContent": ["code": code], "isError": true]
    }

    static func rpcError(_ rid: Any?, _ code: Int, _ message: String, data: Any? = nil) -> [String: Any] {
        var e: [String: Any] = ["code": code, "message": message]
        e["data"] = data
        return ["jsonrpc": "2.0", "id": rid ?? NSNull(), "error": e]
    }

    public static func serialize(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "null" }
        return String(decoding: d, as: UTF8.self)
    }
}

/// 拼一页 A2UI：根是一列，每段一列（标题、几行设置），段之间一条分隔线。
struct PageBuilder {
    let page: String
    private(set) var components: [[String: Any]] = []
    private var sections: [String] = []
    private var current: [String] = []

    init(page: String) { self.page = page }

    mutating func section(_ id: String, _ title: String? = nil, _ body: (inout PageBuilder) -> Void) {
        // 段的编号加 s- 前缀，不和段里的开关撞（「联想」段里有个「联想」开关）
        current = []
        if !sections.isEmpty { add(["id": "s-\(id)-div", "component": "Divider"]) }
        if let title { text("s-\(id)-h", title, variant: "h4") }
        body(&self)
        components.append(["id": "s-\(id)", "component": "Column", "children": current])
        sections.append("s-\(id)")
        current = []
    }

    private mutating func add(_ c: [String: Any]) {
        components.append(c)
        current.append(c["id"] as! String)
    }

    /// 只登记组件、不放进这一段（子组件）。
    private mutating func child(_ c: [String: Any]) { components.append(c) }

    mutating func text(_ id: String, _ text: String, variant: String? = nil) {
        var c: [String: Any] = ["id": id, "component": "Text", "text": text]
        c["variant"] = variant
        add(c)
    }

    private func event(_ name: String, _ context: [String: Any]) -> [String: Any] { ["event": ["name": name, "context": context]] }

    private func setContext(key: String, value: Any, app: String?) -> [String: Any] {
        var ctx: [String: Any] = ["page": page, "key": key, "value": value]
        ctx["app"] = app
        return ctx
    }

    /// 一行开关：左边说它管什么，右边开关（协议 §4：开关的文字只给读屏）。
    mutating func toggle(_ id: String, _ title: String, on: Bool, key: String, app: String? = nil) {
        add(["id": id, "component": "Row", "justify": "spaceBetween", "children": ["\(id)-t", "\(id)-b"]])
        child(["id": "\(id)-t", "component": "Text", "text": title])
        child(["id": "\(id)-b", "component": "Button", "variant": "switch", "on": on, "child": "\(id)-bt",
               "action": event("ime_set", setContext(key: key, value: !on, app: app))])
        child(["id": "\(id)-bt", "component": "Text", "text": on ? "关闭\(title)" : "开启\(title)"])
    }

    /// 单选：标题一行，下面每个选项一个按钮，当前那个是主按钮（ChoicePicker 改了值不调工具）。
    mutating func choice(_ id: String, _ title: String, _ options: [(label: String, value: Any, selected: Bool)], key: String, app: String? = nil) {
        add(["id": "\(id)-t", "component": "Text", "text": title])
        var kids: [String] = []
        for (i, o) in options.enumerated() {
            let bid = "\(id)-\(i)"
            var b: [String: Any] = ["id": bid, "component": "Button", "child": "\(bid)-t",
                                    "action": event("ime_set", setContext(key: key, value: o.value, app: app))]
            if o.selected { b["variant"] = "primary" }
            child(b)
            child(["id": "\(bid)-t", "component": "Text", "text": o.label])
            kids.append(bid)
        }
        add(["id": id, "component": "Row", "children": kids])
    }

    /// 步进：「字号：16」，右边小一号、大一号两个按钮；到头的那个不画。
    mutating func stepper(_ id: String, _ title: String, value: Int, range: ClosedRange<Int>, key: String, less: String, more: String) {
        var kids = ["\(id)-t"]
        child(["id": "\(id)-t", "component": "Text", "text": title])
        for (suffix, label, v) in [("less", less, value - 1), ("more", more, value + 1)] where range.contains(v) {
            child(["id": "\(id)-\(suffix)", "component": "Button", "child": "\(id)-\(suffix)-t",
                   "action": event("ime_set", setContext(key: key, value: v, app: nil))])
            child(["id": "\(id)-\(suffix)-t", "component": "Text", "text": label])
            kids.append("\(id)-\(suffix)")
        }
        add(["id": id, "component": "Row", "children": kids])
    }

    mutating func button(_ id: String, _ label: String, action: String, context: [String: Any]) {
        add(["id": id, "component": "Button", "child": "\(id)-t", "action": event(action, context)])
        child(["id": "\(id)-t", "component": "Text", "text": label])
    }

    func messages() -> [[String: Any]] {
        let root: [String: Any] = ["id": "root", "component": "Column", "children": sections]
        return [["version": "v0.9", "createSurface": ["surfaceId": page, "catalogId": SettingsService.catalogId]],
                ["version": "v0.9", "updateComponents": ["surfaceId": page, "components": [root] + components]]]
    }
}
