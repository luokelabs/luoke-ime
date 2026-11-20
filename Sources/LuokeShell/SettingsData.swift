import Foundation

/// 主窗口设置页要的原始数据（`data/settings`）和数据操作（`ime_do`）：页由 luoke-agent 拼，这里只给代号、数字、
/// ISO 日期和路径，不给句子（顶层 ADR 0002）。形状和 luoke-agent 商定，样例在 `fixtures/agent/`。
extension SettingsService {
    /// 配件清单 `capabilities.data` 里列的：agent 看到列了才自己拼页。
    public static let dataResources = ["settings", "apps"]

    // MARK: - data/settings

    func settingsData(_ s: State) -> [String: Any] {
        var out: [String: Any] = ["version": 1, "paths": ["engines": paths.engines.path, "settings": paths.settings.path]]
        guard let c = s.config else {
            out["state"] = "unreadable"
            return out
        }
        out["state"] = c.migratedFromV1 ? "not_ready" : "ok"
        out["settings"] = settingItems(c, s)
        let engines = typingChoices(s, c)
        let current = s.catalog.current(c)
        if let e = current, e.manifest?.forgetAll == true {
            out["learned"] = ["engine": ["id": e.id, "name": e.manifest?.name ?? e.id]]
            let f = forgotten(storage: Self.storage(e, s))
            out["forgotten"] = ["recent": f.items.map { ["id": Self.forgottenID($0.input, $0.text), "input": $0.input, "text": $0.text] },
                                "older": f.older]
        } else {
            out["learned"] = NSNull()
            out["forgotten"] = ["recent": [Any](), "older": 0]
        }
        out["usage"] = ["personal": personal(s, c) != nil,
                        "days": Usage(url: paths.usage, now: now).daily(lastDays: 7).map { ["date": $0.date, "counts": $0.counts] }]
        var isDir: ObjCBool = false
        let logs = paths.recordsRoot
        out["dev"] = ["engines": engines.map { ["id": $0.id, "name": $0.name, "on": c.devMode.contains($0.id)] },
                      "log_dir": logs.path,
                      "log_dir_exists": FileManager.default.fileExists(atPath: logs.path, isDirectory: &isDir) && isDir.boolValue]
        return out
    }

    // MARK: - data/apps

    /// 有单独设置的应用（应用是在输入法菜单的「此应用设置」里加的），每个一项：bundle id、名字、各项的值。
    /// 三选一的项值是 `follow`、`on`、`off`，`follow` 那项实际是开还是关给在 `follow` 里（终端里联想默认关）；
    /// 改一项、恢复跟随全局都走 `ime_set`（`apps.<bundle id>.<项>`、`apps.<bundle id>.reset`）。
    /// 带了 `target`（菜单「此应用设置」点进来的）而它还没有单独设置时，多给它一项，各项跟随全局，带 `new: true`。
    func appsData(_ s: State, target: String? = nil) -> [String: Any] {
        guard let c = s.config else { return ["version": 1, "state": "unreadable"] }
        let hasPersonal = personal(s, c) != nil
        var ids = Array(c.apps.keys)
        let fresh = target.flatMap { Self.validBundleID($0) && c.apps[$0] == nil ? $0 : nil }
        if let fresh { ids.append(fresh) }
        let apps = ids.map { ($0, appName($0)) }.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
        func tri(_ v: Bool?) -> String { v.map { $0 ? "on" : "off" } ?? "follow" }
        return ["version": 1, "state": c.migratedFromV1 ? "not_ready" : "ok", "personal": hasPersonal,
                "apps": apps.map { id, name -> [String: Any] in
                    let a = c.app(id)
                    var items: [[String: Any]] = [
                        ["key": "apps.\(id).english", "value": tri(a.english), "follow": c.defaultEnglish],
                        ["key": "apps.\(id).inline", "value": tri(a.inline), "follow": c.inline],
                    ]
                    if hasPersonal {
                        let terminal = ShellConfig.terminals.contains(id)
                        items.append(["key": "apps.\(id).predict", "value": tri(a.predict), "follow": terminal ? false : c.settings.predict,
                                      "terminal": terminal])
                        items.append(["key": "apps.\(id).noRecord", "value": a.noRecord])
                    }
                    var app: [String: Any] = ["id": id, "name": name, "settings": items]
                    if id == fresh { app["new"] = true }
                    return app
                }]
    }

    /// `ime_set` 认的每一项和现在的值：选项给代号，范围给 min、max、step。叫什么、怎么分组由 agent 按 key 定。
    /// 只在某些情况下才有意义的（模糊音的各组、语音的按键）照样给，显示不显示由页面看上一级的开关。
    func settingItems(_ c: ShellConfig, _ s: State) -> [[String: Any]] {
        var items: [[String: Any]] = []
        func add(_ key: String, _ value: Any, _ extra: [String: Any] = [:]) {
            items.append(["key": key, "value": value].merging(extra) { $1 })
        }
        add("currentEngine", s.catalog.current(c)?.id ?? NSNull(),
            ["options": typingChoices(s, c).map { ["value": $0.id, "name": $0.name] }])
        add("fuzzyOn", c.fuzzyOn)
        for pair in ShellConfig.fuzzyChoices { add("fuzzyPairs.\(pair)", c.fuzzyPairs.contains(pair)) }
        if hasVoice(s, c) {
            add("voiceOn", c.voiceOn)
            add("voiceKey", (c.voiceKey ?? .rightOption).rawValue,
                ["options": [Manifest.Hotkey.Key.rightOption, .rightCommand, .rightControl].map(\.rawValue)])
            add("voiceTidy", c.voiceTidy ?? voiceTidyDefault, ["default": voiceTidyDefault])
        }
        add("defaultEnglish", c.defaultEnglish)
        add("rememberMode", c.rememberMode)
        add("shiftToggles", c.settings.shiftToggles)
        add("autoSpace", c.settings.autoSpace)
        add("cornerBraces", c.settings.cornerBraces)
        add("fontSize", Int(c.fontSize), ["min": 10, "max": 40, "step": 1])
        add("orientation", c.settings.orientation.rawValue,
            ["options": [ShellSettings.Orientation.horizontal, .vertical].map(\.rawValue)])
        add("pageSize", c.settings.pageSize, ["min": 1, "max": 9, "step": 1])
        add("pagingKeys", c.settings.pagingKeys.rawValue,
            ["options": [ShellSettings.PagingKeys.minusEqual, .commaPeriod].map(\.rawValue)])
        add("inline", c.inline)
        if let p = personal(s, c) {
            add("predict", c.settings.predict)
            add("memory", c.memoryEnabled(key: EngineCatalog.consentKey(p), bundled: p.bundled))
            add("recordingPaused", c.recordingPaused)
        }
        return items
    }

    /// 引擎的数据目录名：和自带引擎同名的第三方引擎另起一个（和 EngineManager 一样）。
    static func storage(_ e: EngineCatalog.Entry, _ s: State) -> String {
        !e.bundled && s.catalog.entries.contains { $0.bundled && $0.id == e.id } ? e.id + ".third-party" : e.id
    }

    /// 打字引擎写的 forgotten.json（引擎协议「forget_all」）。
    func forgotten(storage: String) -> (items: [(input: String, text: String)], older: Int) {
        let url = paths.data(storage).appendingPathComponent("forgotten.json")
        guard let d = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return ([], 0) }
        let items = (o["forgotten"] as? [[String: Any]] ?? []).compactMap { e -> (input: String, text: String)? in
            guard let i = e["input"] as? String, let t = e["text"] as? String else { return nil }
            return (i, t)
        }
        return (items, o["older"] as? Int ?? 0)
    }

    /// 已忘记词语的编号：按键和词本身（agent 原样传回，不解析）。
    static func forgottenID(_ input: String, _ text: String) -> String { serialize([input, text]) }

    static func parseForgottenID(_ id: String) -> (input: String, text: String)? {
        guard let a = (try? JSONSerialization.jsonObject(with: Data(id.utf8))) as? [String], a.count == 2 else { return nil }
        return (a[0], a[1])
    }

    // MARK: - ime_do

    /// 已经核过用户操作。答复只带代号：成功 `{"data": {"op", …}}`，失败 `{"code", "data": {"op", "code"}}`。
    func act(_ a: [String: Any]) -> [String: Any] {
        let op = a["op"] as? String ?? ""
        func ok(_ extra: [String: Any] = [:]) -> [String: Any] {
            ["content": [["type": "text", "text": op]], "isError": false,
             "structuredContent": ["data": (["op": op] as [String: Any]).merging(extra) { $1 }]]
        }
        func fail(_ code: String) -> [String: Any] {
            ["content": [["type": "text", "text": code]], "isError": true, "structuredContent": ["code": code, "data": ["op": op, "code": code]]]
        }
        /// 要正在运行的输入法做的：答不上来就是它没在运行。
        func ask(_ args: [String: String] = [:]) -> [String: Any]? {
            guard let r = ShellRequests.submit(paths, op: op, args: args, timeout: requestTimeout) else { return fail("not_running") }
            return r["ok"] as? Bool == true ? nil : fail(r["code"] as? String ?? "failed")
        }
        switch op {
        case "clear_learned":
            if let e = ask((a["engine"] as? String).map { ["engine": $0] } ?? [:]) { return e }
            return ok(a["engine"].map { ["engine": $0] } ?? [:])
        case "restore":
            guard let id = a["id"] as? String, let w = Self.parseForgottenID(id) else { return fail("invalid") }
            if let e = ask(["input": w.input, "text": w.text]) { return e }
            waitForgotten(w)
            return ok(["id": id])
        case "reset_usage":
            if let e = ask() { return e }
            return ok()
        case "dev_mode":
            guard let id = a["engine"] as? String, let on = Self.bool(a["on"] as Any) else { return fail("invalid") }
            let state = load()
            guard var c = state.config else { return fail("settings_unreadable") }
            guard !c.migratedFromV1 else { return fail("not_ready") }
            guard typingChoices(state, c).contains(where: { $0.id == id }) else { return fail("invalid") }
            if on { c.devMode.insert(id) } else { c.devMode.remove(id) }
            do { try c.save(paths.settings) } catch { return fail("failed") }
            return ok(["engine": id, "on": on])
        default:
            return fail("invalid")
        }
    }

    /// 恢复是引擎收到以后自己改 forgotten.json：等它改完再答，页面重读时那一条已经不在了（最多等 1.5 秒）。
    private func waitForgotten(_ w: (input: String, text: String)) {
        let state = load()
        guard let c = state.config, let e = state.catalog.current(c) else { return }
        let storage = Self.storage(e, state)
        let end = Date().addingTimeInterval(1.5)
        while Date() < end, forgotten(storage: storage).items.contains(where: { $0 == w }) { Thread.sleep(forTimeInterval: 0.05) }
    }
}
