import AppKit
import AVFoundation
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
        var text = "位置：\(place)，非螺壳自带。启用后，该引擎：\n" + ThirdParty.describe(m).map { "• " + $0 }.joined(separator: "\n")
        if let b = bundled { text += "\n\n与螺壳自带的「\(b.manifest?.name ?? b.id)」同名，启用后将替代自带版本。" }
        text += "\n\n引擎说明中的上述内容变化时，将再次请求确认。"
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
        alert.messageText = "清除「\(t.manifest.name)」的已学词语？"
        alert.informativeText = "因改选而排在前面的词语将全部清除，此后按默认顺序排列；已用 Shift+⌫ 忘记的词语仍不显示。清除后无法恢复。"
        alert.addButton(withTitle: "取消")
        let clear = alert.addButton(withTitle: "清除")
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
        if !preview { EngineManager.shared.onConfigChange = { [weak self] in self?.refresh() } } else { reloadUsage() }
    }

    private static var previewConfig: ShellConfig {
        var c = ShellConfig()
        c.apps["com.openai.chat"] = .init(english: true)
        c.voiceOn = true // 画设置页时语音那一节展开
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
        reloadUsage()
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

    /// 最近 7 天的使用计数（打开设置窗口时读）。
    @Published var usage: [Usage.Event: Int] = [:]

    func reloadUsage() {
        usage = preview ? [.commit: 1240, .pickFirst: 1385, .pickOther: 162, .backspaceAfterCommit: 96,
                           .predictShown: 141, .predictOpened: 38, .predictPicked: 27, .predictChars: 81]
            : manager.usage.total(lastDays: 7)
    }

    func resetUsage() {
        guard !preview else { return }
        manager.usage.reset()
        reloadUsage()
    }

    /// 系统里螺壳输入法的麦克风权限被拒了（打开语音以后提示去系统设置里开）。
    var microphoneDenied: Bool {
        !preview && [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
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
            Section(lk: "模糊音") {
                Toggle("模糊音", isOn: Binding(get: { c.fuzzyOn }, set: { v in model.update { $0.fuzzyOn = v } }))
                // 关着时不列六组（勾选照样留着），打开后才出现
                if c.fuzzyOn {
                    ForEach(ShellConfig.fuzzyChoices, id: \.self) { pair in
                        Toggle(pair.replacingOccurrences(of: "_", with: " = "), isOn: Binding(get: { c.fuzzyPairs.contains(pair) }, set: { v in
                            model.update { if v { $0.fuzzyPairs.insert(pair) } else { $0.fuzzyPairs.remove(pair) } }
                        })).toggleStyle(.checkbox)
                    }
                }
                Text("开启后同时给出拼法相近的字，准确的候选可能排序靠后。").font(.caption).foregroundStyle(.secondary)
            }
            Section(lk: "语音") {
                Toggle("语音输入", isOn: Binding(get: { c.voiceOn }, set: { v in model.update { $0.voiceOn = v } }))
                if c.voiceOn {
                    Picker("语音输入按键", selection: Binding(get: { c.voiceKey ?? .rightOption }, set: { v in model.update { $0.voiceKey = v == .rightOption ? nil : v } })) {
                        ForEach([Manifest.Hotkey.Key.rightOption, .rightCommand, .rightControl], id: \.self) { Text(voiceKeyName($0)).tag($0) }
                    }
                    Text("使用外接 Windows 键盘或在系统设置中对调过修饰键时，右 Alt 可能被识别为右 ⌘，此时请选择右 ⌘。").font(.caption).foregroundStyle(.secondary)
                    Toggle("语音整理：去除口头禅、修正改口、整理列表和分段", isOn: Binding(get: { c.voiceTidyActive }, set: { v in model.update { $0.voiceTidy = v } }))
                    if model.microphoneDenied {
                        HStack {
                            Text("未获得麦克风权限，无法录音。").font(.caption).foregroundStyle(Color.lkDanger)
                            Button("打开系统设置") { model.openMicrophoneSettings() }.controlSize(.small)
                        }
                    }
                }
                Text(c.voiceOn && !ShellConfig.voiceTidyDefault
                     ? "按住所选按键说话，松开后上屏。识别和整理均由螺壳在本机完成，需安装螺壳；内存 24 GB 及以下的 Mac 上整理耗时数秒，默认关闭。"
                     : "按住所选按键说话，松开后上屏。识别和整理均由螺壳在本机完成，需安装螺壳；开启时系统将请求麦克风权限。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(lk: "中英文") {
                Picker("进入应用时的默认模式", selection: Binding(get: { c.defaultEnglish }, set: { v in model.update { $0.setDefaultEnglish(v) } })) {
                    Text("中文").tag(false)
                    Text("英文").tag(true)
                }
                Toggle("记住各应用上次的中英文模式", isOn: Binding(get: { c.rememberMode }, set: { v in model.update { $0.setRememberMode(v) } }))
                Toggle("单按 Shift 切换中英文", isOn: Binding(get: { c.settings.shiftToggles }, set: { v in model.update { $0.settings.shiftToggles = v } }))
            }
            Section(lk: "排版") {
                Toggle("中英文之间自动加空格", isOn: Binding(get: { c.settings.autoSpace }, set: { v in model.update { $0.settings.autoSpace = v } }))
                Toggle("中文状态下 { } 输入为「」", isOn: Binding(get: { c.settings.cornerBraces }, set: { v in model.update { $0.settings.cornerBraces = v } }))
            }
            Section(lk: "候选窗口") {
                Stepper("字号：\(Int(c.fontSize))", value: Binding(get: { c.fontSize }, set: { v in model.update { $0.fontSize = min(max(v, 10), 40) } }),
                        in: 10...40, step: 1)
                Picker("候选排列", selection: Binding(get: { c.settings.orientation }, set: { v in model.update { $0.settings.orientation = v } })) {
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
                Picker("拼音显示位置", selection: Binding(get: { c.inline }, set: { v in model.update { $0.inline = v } })) {
                    Text("输入框").tag(true)
                    Text("候选窗口").tag(false)
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
                    SettingRow(title: "记录输入内容到记忆", detail: "保存在本机的螺壳记忆中，用于联想和候选排序。关闭后已有记录保留。") {
                        Text(model.recordingState).foregroundStyle(.secondary)
                        // 这个名字主控首次运行的完成页、输入法的添加引导里原样引用了（luoke-core 246279c）；改名时告诉 luoke-core 一起改
                        Toggle("记录输入内容到记忆", isOn: Binding(get: { model.memoryConsented }, set: { model.setMemoryConsent($0) })).toggleStyle(.switch).labelsHidden()
                    }
                    .id("memory")
                    SettingRow(title: "暂停所有记录", detail: "暂停期间不记录，可随时恢复。") {
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
                    Text(model.apps.isEmpty ? "暂无单独设置的应用" : "选择应用")
                    Text("在应用中打开输入法菜单，选择「此应用设置」。")
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
                Picker("拼音显示位置", selection: binding(\.inline)) {
                    Text("跟随全局（\(c.inline ? "输入框" : "候选窗口")）").tag(Choice.follow)
                    Text("输入框").tag(Choice.on)
                    Text("候选窗口").tag(Choice.off)
                }
                if model.hasPersonal {
                    Picker("联想", selection: binding(\.predict)) {
                        // 终端默认不联想（ShellConfig.terminals）：照实显示跟随的结果
                        Text(ShellConfig.terminals.contains(app) ? "跟随默认（终端中关闭）" : "跟随全局（\(c.settings.predict ? "开启" : "关闭")）").tag(Choice.follow)
                        Text("开启").tag(Choice.on)
                        Text("关闭").tag(Choice.off)
                    }
                    Picker("记忆记录", selection: Binding(get: { a.noRecord }, set: { v in model.update { $0.setApp(app) { $0.noRecord = v } } })) {
                        Text("跟随全局（\(model.globalRecording)）").tag(false)
                        Text("禁止记录").tag(true)
                    }
                    Text("全局记录关闭或暂停时，此应用同样不记录。")
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
                    SettingRow(title: "记忆记录", detail: "记录输入的文字和所在应用，以及开始输入时光标前的一段文字（可能由他人所写，仅用于理解上下文），保存在本机的螺壳记忆中。密码框、暂停期间和禁止记录的应用中不记录；密码、验证码、卡号等内容会被遮盖。") {
                        Text(model.recordingState).foregroundStyle(.secondary)
                        Button("前往设置") { model.focusMemory = true; model.tab = .global }.buttonStyle(.bordered)
                    }
                    SettingRow(title: "查看和管理记忆", detail: model.memoryAppInstalled ? "可逐条查看和删除。" : "需安装螺壳。") {
                        Button("打开") { model.openMemory() }.buttonStyle(.bordered).disabled(!model.memoryAppInstalled)
                    }
                }
            }
            if let t = model.learnedEngine {
                // 学到的、忘掉的都存在当前输入方案自己那里：换成别的方案，这里显示那个方案的
                Section(lk: "「\(t.manifest.name)」的词语") {
                    SettingRow(title: "已学词语", detail: "改选过的词语排序靠前。清除后按默认顺序排列。") {
                        Button("全部清除") { model.forgetLearned() }.buttonStyle(.bordered).disabled(t.state != .running)
                    }
                    SettingRow(title: "已忘记词语", detail: model.forgotten.items.isEmpty && model.forgotten.older == 0
                               ? "暂无。在候选上按 Shift+⌫ 可忘记词语。" : "以下词语不再显示，可撤销恢复。") { EmptyView() }
                    ForEach(model.forgotten.items, id: \.self) { w in
                        HStack {
                            Text(w.text)
                            Text(w.input).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("撤销") { model.unforget(w.input, w.text) }.disabled(t.state != .running)
                        }
                    }
                    if model.forgotten.older > 0 {
                        Text("另有 \(model.forgotten.older) 个较早忘记的词语未列出，仍不显示。")
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
        let u = model.usage
        Form {
            Section(lk: "使用统计") {
                SettingRow(title: "最近 7 天", detail: "仅在本机统计次数，不记录输入内容和应用，不上传；密码框、暂停所有记录期间和禁止记录的应用中不统计。用于评估候选和联想的排序质量。") {
                    Button("清零") { model.resetUsage() }.buttonStyle(.bordered).disabled(u.isEmpty)
                }
                let picks = (u[.pickFirst] ?? 0) + (u[.pickOther] ?? 0)
                Text("上屏 \(u[.commit] ?? 0) 次；所选候选中首选占比 \(Self.percent(u[.pickFirst] ?? 0, picks))；上屏后立即退格占比 \(Self.percent(u[.backspaceAfterCommit] ?? 0, u[.commit] ?? 0))")
                    .font(.callout)
                if model.hasPersonal {
                    Text("联想显示 \(u[.predictShown] ?? 0) 次，展开 \(u[.predictOpened] ?? 0) 次，选用 \(u[.predictPicked] ?? 0) 次（共 \(u[.predictChars] ?? 0) 字）")
                        .font(.callout)
                }
            }
            Section(lk: "开发模式") {
                ForEach(model.typingEngines, id: \.id) { e in
                    SettingRow(title: "记录「\(e.name)」的输入") {
                        Toggle("记录「\(e.name)」的输入", isOn: Binding(get: { c.devMode.contains(e.id) }, set: { v in
                            model.update { if v { $0.devMode.insert(e.id) } else { $0.devMode.remove(e.id) } }
                        })).toggleStyle(.switch).labelsHidden()
                    }
                }
                SettingRow(title: "记录文件夹", detail: "开发模式的记录，保留 7 天。") {
                    Button("打开") { model.open(paths.recordsRoot) }.buttonStyle(.bordered)
                }
            }
            Section(lk: "文件") {
                SettingRow(title: "引擎文件夹", detail: "用于放置自制引擎。") {
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

    static func percent(_ n: Int, _ of: Int) -> String { of == 0 ? "—" : "\(Int((100 * Double(n) / Double(of)).rounded()))%" }
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

/// 设置里说话的键怎么写：右 ⌥ 是 Windows 键盘上的右 Alt。
func voiceKeyName(_ k: Manifest.Hotkey.Key) -> String {
    switch k {
    case .rightOption: return "右 ⌥（Alt）"
    case .rightCommand: return "右 ⌘"
    case .rightControl: return "右 ⌃"
    }
}
