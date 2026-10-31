import AppKit
import LuokeShell
import SwiftUI

/// 设置窗口：通用、应用、记忆、高级（原名全局设置、应用设置、隐私与记忆、诊断与开发）（luokelabs/luoke-ime#1）。
/// 改的是 EngineManager 的同一份设置，和菜单一样走 update；外面改了设置文件，窗口跟着刷新。
/// 窗口里不放文本框：输入法自己的窗口里打字，按键会交给输入法自己，所以只用开关、单选和步进。
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    enum Page: Equatable {
        case global
        case app(String, name: String)
        case privacy
        case tools
    }

    let model = SettingsModel()
    private var window: NSWindow?
    /// 打开设置前在前台的应用：关窗口时还给它。
    private var previous: NSRunningApplication?

    func show(_ page: Page) {
        model.open(page)
        let w = window ?? makeWindow()
        window = w
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous = front }
        SettingsWindow.allowFront()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    /// 用不激活应用的面板：macOS 14 起应用不能自己抢到前台（点的是系统的输入法菜单，前台还是原来的应用，
    /// 测试机上实测 activate 不生效），面板不用激活应用也能成为键盘焦点所在的窗口。
    private func makeWindow() -> NSWindow {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .closable, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.becomesKeyOnlyIfNeeded = false
        w.hidesOnDeactivate = false
        w.isFloatingPanel = false
        w.title = "螺壳输入法设置"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView(model: model))
        w.delegate = self
        w.center()
        return w
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        previous?.activate()
        previous = nil
    }

    /// 输入法平时是 .prohibited（不进程序坞、不能到前台）：要弹窗口时先换成 .accessory 才能到前台、收键盘。
    static func allowFront() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
    }

    var isOpen: Bool { window?.isVisible == true }

    /// 离屏画成图片（检查外观用：LuokeIME --render-settings <out.png> [页]）。
    static func snapshot(to url: URL, tab: SettingsModel.Tab, dark: Bool) -> Bool {
        let model = SettingsModel(preview: true)
        model.tab = tab
        model.selectedApp = model.apps.first
        let view = NSHostingView(rootView: SettingsView(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 560)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// 启用第三方引擎前的确认框（luokelabs/luoke-ime#6）：写明它装在哪、不是随螺壳发布的、启用以后能做什么不能做什么。
    /// 默认按钮是"不启用"。同意了返回 true。
    static func confirmThirdParty(_ e: EngineManager.Entry, replacing bundled: EngineManager.Entry?) -> Bool {
        guard let m = e.manifest else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let place = e.dir.path.hasPrefix(home) ? "~" + e.dir.path.dropFirst(home.count) : e.dir.path
        var text = "它装在 \(place)，不是随螺壳发布的。启用以后它：\n" + ThirdParty.describe(m).map { "• " + $0 }.joined(separator: "\n")
        if let b = bundled { text += "\n\n它和螺壳自带的「\(b.manifest?.name ?? b.id)」同名：启用后用它代替自带的那份。" }
        text += "\n\n以后它的引擎说明里这些变了，会再问你。"
        let alert = NSAlert()
        alert.messageText = "启用第三方引擎「\(m.name)」？"
        alert.informativeText = text
        alert.addButton(withTitle: "不启用")
        alert.addButton(withTitle: "启用")
        let front = NSWorkspace.shared.frontmostApplication
        let mine = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        allowFront()
        let answer = alert.runModal()
        if !shared.isOpen { NSApp.setActivationPolicy(.prohibited) }
        if !mine { front?.activate() }
        return answer == .alertSecondButtonReturn
    }

    /// 清掉打字引擎学到的词：先弹系统的确认框（默认按钮是取消），确认了再告诉引擎。确认框要把输入法拉到前台，关掉后还给原来的应用。
    static func confirmForgetLearned(_ t: EngineConnection) {
        let alert = NSAlert()
        alert.messageText = "清掉「\(t.manifest.name)」学到的词？"
        alert.informativeText = "你改选过、它记住放在前面的词会全部清掉，以后按默认的顺序出；按 Shift+⌫ 忘掉的词照旧不出。清掉以后找不回来。"
        alert.addButton(withTitle: "取消")
        let clear = alert.addButton(withTitle: "清掉")
        clear.hasDestructiveAction = true
        let front = NSWorkspace.shared.frontmostApplication
        let mine = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        allowFront()
        let answer = alert.runModal()
        if !shared.isOpen { NSApp.setActivationPolicy(.prohibited) }
        if !mine { front?.activate() }
        guard answer == .alertSecondButtonReturn else { return }
        EngineManager.shared.forgetAll(t)
    }
}

/// 设置窗口的数据：照着 EngineManager 的设置，改的时候交回给它。
final class SettingsModel: ObservableObject {
    enum Tab: String, Hashable, CaseIterable { case global, apps, privacy, tools }

    @Published var config: ShellConfig
    @Published var tab: Tab = .global
    @Published var selectedApp: String?
    /// 从记忆页「去通用里开关」过来：通用页打开时滚到记忆记录
    @Published var focusMemory = false
    /// 应用列表里要显示的应用（有自己设置的，加上从菜单"此应用设置"进来的那个）和它们的名字。
    @Published var extraApps: [String] = []
    @Published var names: [String: String] = [:]
    private let preview: Bool

    init(preview: Bool = false) {
        self.preview = preview
        config = preview ? Self.previewConfig : EngineManager.shared.config
        if !preview { EngineManager.shared.onConfigChange = { [weak self] in self?.refresh() } }
    }

    private static var previewConfig: ShellConfig {
        var c = ShellConfig()
        c.apps["com.openai.chat"] = .init(english: true)
        return c
    }

    private var manager: EngineManager { .shared }

    func refresh() {
        guard !preview else { return }
        config = manager.config
    }

    func update(_ change: (inout ShellConfig) -> Void) {
        if preview { change(&config); return }
        manager.update(change)
        refresh()
    }

    func open(_ page: SettingsWindow.Page) {
        refresh()
        reloadForgotten()
        switch page {
        case .global: tab = .global
        case .privacy: tab = .privacy
        case .tools: tab = .tools
        case let .app(app, name):
            tab = .apps
            names[app] = name
            if !extraApps.contains(app) { extraApps.append(app) }
            selectedApp = app
        }
    }

    var apps: [String] {
        var list = config.apps.keys.sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
        for a in extraApps where !list.contains(a) { list.insert(a, at: 0) }
        return list
    }

    func name(of app: String) -> String {
        if let n = names[app] { return n }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { return app }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: 引擎、记忆（不在设置文件里的状态）

    var typingEngines: [(id: String, name: String)] {
        preview ? [("xiaohe", "小鹤双拼"), ("ziranma", "自然码双拼"), ("quanpin", "全拼")] : manager.typingEntries.map { ($0.id, $0.manifest?.name ?? $0.id) }
    }

    var currentEngine: String? { preview ? "xiaohe" : manager.typing?.id }
    var hasPersonal: Bool { preview || manager.personal != nil }
    var memoryConsented: Bool { preview ? false : manager.memoryConsented }
    var recordingState: String {
        preview ? "未开启" : LuokeInputController.describe(manager.recordingState(in: nil), status: manager.memoryStatus)
    }
    /// 应用设置里"跟随全局"后面写的：全局的实际状态。
    var globalRecording: String {
        if !memoryConsented { return "已关闭" }
        return config.recordingPaused ? "已暂停" : "已开启"
    }
    var memoryAppInstalled: Bool { LuokeInputController.memoryAvailable }
    var learnedEngine: EngineConnection? { preview ? nil : manager.typing.flatMap { $0.manifest.forgetAll ? $0 : nil } }

    func setMemoryConsent(_ on: Bool) {
        guard !preview else { return }
        manager.setMemoryConsent(on)
        refresh()
        objectWillChange.send()
    }

    func openMemory() {
        LuokeInputController.openMemoryUI()
    }

    /// 打字引擎忘掉过的词（打开设置窗口、撤销以后刷新）。
    @Published var forgotten = EngineManager.ForgottenList()

    func reloadForgotten() {
        forgotten = preview ? .init(items: [.init(input: "wo", text: "窝")]) : manager.forgottenWords()
    }

    func unforget(_ input: String, _ text: String) {
        guard !preview, manager.unforget(input: input, text: text) else { return }
        forgotten.items.removeAll { $0.input == input && $0.text == text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.reloadForgotten() } // 引擎改完 forgotten.json 再读一遍
    }

    func forgetLearned() {
        guard let t = learnedEngine, t.state == .running else { return }
        SettingsWindow.confirmForgetLearned(t)
    }

    func open(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 界面

/// 跟随全局、开、关三选一（应用设置里用）。
private enum Choice: Hashable {
    case follow, on, off
    init(_ v: Bool?) { self = v.map { $0 ? .on : .off } ?? .follow }
    var value: Bool? { self == .follow ? nil : self == .on }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView(selection: $model.tab) {
            GlobalPage(model: model).tabItem { Text("通用") }.tag(SettingsModel.Tab.global)
            AppsPage(model: model).tabItem { Text("应用") }.tag(SettingsModel.Tab.apps)
            PrivacyPage(model: model).tabItem { Text("记忆") }.tag(SettingsModel.Tab.privacy)
            ToolsPage(model: model).tabItem { Text("高级") }.tag(SettingsModel.Tab.tools)
        }
        .padding(12)
        .tint(Color.lkPrimary)   // 开关用品牌深色，不用系统蓝（规范第 6 节）
        .frame(width: 640, height: 560)
    }
}

private struct GlobalPage: View {
    @ObservedObject var model: SettingsModel

    private func scrollToMemory(_ proxy: ScrollViewProxy) {
        guard model.focusMemory else { return }
        DispatchQueue.main.async { withAnimation { proxy.scrollTo("memory", anchor: .top) }; model.focusMemory = false }
    }

    var body: some View {
        let c = model.config
        ScrollViewReader { proxy in
        Form {
            Section(lk: "输入方式") {
                Picker("输入方案", selection: Binding(get: { model.currentEngine ?? "" }, set: { id in model.update { $0.currentEngine = id } })) {
                    ForEach(model.typingEngines, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            Section(lk: "中英文") {
                Picker("进入应用时默认", selection: Binding(get: { c.defaultEnglish }, set: { v in model.update { $0.setDefaultEnglish(v) } })) {
                    Text("中文").tag(false)
                    Text("英文").tag(true)
                }
                Toggle("记住各应用上次的中英文模式", isOn: Binding(get: { c.rememberMode }, set: { v in model.update { $0.setRememberMode(v) } }))
                Toggle("单按 Shift 切换中英文", isOn: Binding(get: { c.settings.shiftToggles }, set: { v in model.update { $0.settings.shiftToggles = v } }))
            }
            Section(lk: "排版") {
                Toggle("中英文之间自动加空格", isOn: Binding(get: { c.settings.autoSpace }, set: { v in model.update { $0.settings.autoSpace = v } }))
                Toggle("中文状态下 { } 打成「」", isOn: Binding(get: { c.settings.cornerBraces }, set: { v in model.update { $0.settings.cornerBraces = v } }))
            }
            Section(lk: "候选窗口") {
                Stepper("字号：\(Int(c.fontSize))", value: Binding(get: { c.fontSize }, set: { v in model.update { $0.fontSize = min(max(v, 10), 40) } }),
                        in: 10...40, step: 1)
                Picker("排列", selection: Binding(get: { c.settings.orientation }, set: { v in model.update { $0.settings.orientation = v } })) {
                    Text("横排").tag(ShellSettings.Orientation.horizontal)
                    Text("竖排").tag(ShellSettings.Orientation.vertical)
                }
                Stepper("每页候选数：\(c.settings.pageSize)", value: Binding(get: { c.settings.pageSize }, set: { v in
                    model.update { $0.settings.pageSize = min(max(v, 1), 9) }
                }), in: 1...9)
                Picker("翻页键", selection: Binding(get: { c.settings.pagingKeys }, set: { v in model.update { $0.settings.pagingKeys = v } })) {
                    Text("- 和 =").tag(ShellSettings.PagingKeys.minusEqual)
                    Text(", 和 .").tag(ShellSettings.PagingKeys.commaPeriod)
                }
                Picker("拼音显示在", selection: Binding(get: { c.inline }, set: { v in model.update { $0.inline = v } })) {
                    Text("输入框里").tag(true)
                    Text("候选窗口里").tag(false)
                }
            }
            if model.hasPersonal {
                Section(lk: "联想") {
                    SettingRow(title: "联想", detail: "按 Tab 选用推荐。") {
                        Toggle("联想", isOn: Binding(get: { c.settings.predict }, set: { v in model.update { $0.settings.predict = v } })).toggleStyle(.switch).labelsHidden()
                    }
                }
                // 记忆记录的总开关在这里（luokelabs/luoke-ime#1 的后续）；记忆页只讲记了什么、怎么看和删
                Section(lk: "记忆记录") {
                    SettingRow(title: "记录输入内容到记忆", detail: "记在本机的螺壳记忆里，用来联想、让候选更合你的习惯。关掉不删已记下的。") {
                        Text(model.recordingState).foregroundStyle(.secondary)
                        // 这个名字主控首次运行的完成页、输入法的添加引导里原样引用了（luoke-core 246279c）；改名时告诉 luoke-core 一起改
                        Toggle("记录输入内容到记忆", isOn: Binding(get: { model.memoryConsented }, set: { model.setMemoryConsent($0) })).toggleStyle(.switch).labelsHidden()
                    }
                    .id("memory")
                    SettingRow(title: "暂停所有记录", detail: "临时不记，随时恢复。") {
                        Toggle("暂停所有记录", isOn: Binding(get: { c.recordingPaused }, set: { v in model.update { $0.recordingPaused = v } })).toggleStyle(.switch).labelsHidden()
                    }
                    .disabled(!model.memoryConsented)
                }
            }
        }
        .formStyle(.grouped)
        // 两种都接：TabView 重新建页面时走 onAppear，页面保活时走 onChange
        .onAppear { scrollToMemory(proxy) }
        .onChange(of: model.focusMemory) { _, on in if on { scrollToMemory(proxy) } }
        }
    }
}

private struct AppsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $model.selectedApp) {
                ForEach(model.apps, id: \.self) { app in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name(of: app))
                        Text(model.config.app(app).isEmpty ? "跟随全局" : "已自定义").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(app)
                }
            }
            .frame(width: 190)
            Divider()
            if let app = model.selectedApp {
                AppDetail(model: model, app: app)
            } else {
                VStack(spacing: 8) {
                    Text(model.apps.isEmpty ? "还没有单独设置的应用" : "选一个应用")
                    Text("在应用里打开输入法菜单，选「此应用设置」。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct AppDetail: View {
    @ObservedObject var model: SettingsModel
    let app: String

    var body: some View {
        let c = model.config
        let a = c.app(app)
        Form {
            Section(lk: model.name(of: app)) {
                Picker("默认输入模式", selection: binding(\.english)) {
                    Text("跟随全局（\(c.defaultEnglish ? "英文" : "中文")）").tag(Choice.follow)
                    Text("中文").tag(Choice.off)
                    Text("英文").tag(Choice.on)
                }
                Picker("拼音显示在", selection: binding(\.inline)) {
                    Text("跟随全局（\(c.inline ? "输入框里" : "候选窗口里")）").tag(Choice.follow)
                    Text("输入框里").tag(Choice.on)
                    Text("候选窗口里").tag(Choice.off)
                }
                if model.hasPersonal {
                    Picker("联想", selection: binding(\.predict)) {
                        // 终端默认不联想（ShellConfig.terminals）：照实显示跟随的结果
                        Text(ShellConfig.terminals.contains(app) ? "跟随默认（终端里关）" : "跟随全局（\(c.settings.predict ? "开" : "关")）").tag(Choice.follow)
                        Text("开").tag(Choice.on)
                        Text("关").tag(Choice.off)
                    }
                    Picker("记忆记录", selection: Binding(get: { a.noRecord }, set: { v in model.update { $0.setApp(app) { $0.noRecord = v } } })) {
                        Text("跟随全局（\(model.globalRecording)）").tag(false)
                        Text("禁止记录").tag(true)
                    }
                    Text("全局关着或暂停时，这里都不记。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("恢复跟随全局") { model.update { c in c.setApp(app) { $0 = .init() } } }.buttonStyle(.bordered)
                    .disabled(a.isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    private func binding(_ key: WritableKeyPath<ShellConfig.AppSettings, Bool?>) -> Binding<Choice> {
        Binding(get: { Choice(model.config.app(app)[keyPath: key]) },
                set: { v in model.update { c in c.setApp(app) { $0[keyPath: key] = v.value } } })
    }
}

private struct PrivacyPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            if model.hasPersonal {
                Section(lk: "记忆") {
                    SettingRow(title: "记忆记录", detail: "记下你打的字、在哪个应用打的，连同开始时光标前的一段文字（可能是别人写的，只用来理解上下文），存在本机的螺壳记忆里。密码框里、暂停时、禁止记录的应用里不记；密码、验证码、卡号这类会遮掉。") {
                        Text(model.recordingState).foregroundStyle(.secondary)
                        Button("去开关") { model.focusMemory = true; model.tab = .global }.buttonStyle(.bordered)
                    }
                    SettingRow(title: "查看和管理记忆", detail: model.memoryAppInstalled ? "每一条都能看、能删。" : "要先装螺壳。") {
                        Button("打开") { model.openMemory() }.buttonStyle(.bordered).disabled(!model.memoryAppInstalled)
                    }
                }
            }
            if let t = model.learnedEngine {
                // 学到的、忘掉的都存在当前输入方案自己那里：换成别的方案，这里显示那个方案的
                Section(lk: "「\(t.manifest.name)」的词") {
                    SettingRow(title: "学到的词", detail: "你改选过的词会排到前面。清掉后按默认顺序出。") {
                        Button("全部清掉") { model.forgetLearned() }.buttonStyle(.bordered).disabled(t.state != .running)
                    }
                    SettingRow(title: "忘掉的词", detail: model.forgotten.items.isEmpty && model.forgotten.older == 0
                               ? "还没有。候选上按 Shift+⌫ 忘掉一个词。" : "这些词不再出现，点撤销恢复。") { EmptyView() }
                    ForEach(model.forgotten.items, id: \.self) { w in
                        HStack {
                            Text(w.text)
                            Text(w.input).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("撤销") { model.unforget(w.input, w.text) }.disabled(t.state != .running)
                        }
                    }
                    if model.forgotten.older > 0 {
                        Text("另有 \(model.forgotten.older) 个早先忘掉的词列不出来，照旧不出。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ToolsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let c = model.config
        let paths = EngineManager.shared.paths
        Form {
            Section(lk: "开发模式") {
                ForEach(model.typingEngines, id: \.id) { e in
                    SettingRow(title: "记录「\(e.name)」的输入") {
                        Toggle("记录「\(e.name)」的输入", isOn: Binding(get: { c.devMode.contains(e.id) }, set: { v in
                            model.update { if v { $0.devMode.insert(e.id) } else { $0.devMode.remove(e.id) } }
                        })).toggleStyle(.switch).labelsHidden()
                    }
                }
                SettingRow(title: "记录文件夹", detail: "开发模式的记录，留 7 天。") {
                    Button("打开") { model.open(paths.recordsRoot) }.buttonStyle(.bordered)
                }
            }
            Section(lk: "文件") {
                SettingRow(title: "引擎文件夹", detail: "放自己写的引擎。") {
                    Button("打开") { model.open(paths.engines) }.buttonStyle(.bordered)
                }
                SettingRow(title: "设置文件") {
                    Button("打开") {
                        if !FileManager.default.fileExists(atPath: paths.settings.path) { try? c.save(paths.settings) }
                        model.open(paths.settings)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// 分组标题用品牌的 11/500（brand DESIGN §3），和主控、邮件、记忆一致
private extension Section where Parent == Text, Footer == EmptyView, Content: View {
    init(lk title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title).font(.system(size: 11, weight: .medium)) })
    }
}

/// 一行设置：左边标题，下面跟一句灰色说明（同一行里，不另起一行，没有分隔线）；右边放控件
private struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}
