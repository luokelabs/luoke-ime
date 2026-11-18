import AppKit
import Carbon
import InputMethodKit
import LuokeShell
import os

/// 每个输入框一个：把系统按键事件翻译后交给状态机，把状态机的画面画到输入框和候选窗上。
/// 按键规则一律在状态机里（ADR 0007），这里不做任何判断。
@objc(LuokeInputController)
final class LuokeInputController: IMKInputController, SessionClient {
    static let log = Logger(subsystem: "ai.luoke.inputmethod", category: "input")
    private(set) var session: Session!
    private var timer: DispatchSourceTimer?
    private var lastMarked = ""
    private var lastEnglish = false
    private var manager: EngineManager { EngineManager.shared }
    private var panel: CandidatePanel { CandidatePanel.shared }
    /// 只有当前激活的输入框画候选窗（候选窗是共用的；引擎停用时壳会给所有会话设提示）。
    private var isActive = false
    /// 系统交出组字时指定的客户端：往它上屏，而不是往 client() 当前指向的那个。
    private var committingTo: IMKTextInput?

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        session = Session(client: self, settings: EngineManager.shared.config.settings)
        session.onFirstUseNoticeSeen = { EngineManager.shared.memoryPromptSeen() }
        EngineManager.shared.register(self)
    }

    private var textClient: IMKTextInput? { committingTo ?? client() }

    override func recognizedEvents(_ sender: Any!) -> Int {
        // 鼠标按下只用来判断"单按 Shift"（⇧ 加点击扩选不算），一律放行
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]).rawValue)
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        isActive = true
        EnabledWatch.activated()
        lastMarked = ""
        // 中英状态：规则在 ShellConfig.englishOnEnter（全局默认、应用覆盖、记住上次模式）
        let english = manager.enter(app: appID)
        lastEnglish = english // 进入输入框时恢复的状态不闪"中/英"提示，只有用户切换时才闪
        session.setEnglish(english)
        manager.applyPrivacy(secureInput: isSecureInput, mayRecord: mayRecord) // 开发模式的记录：换了输入框先按这个应用定，再读前文
        if let ask = manager.memoryPrompt() { session.setFirstUseNotice(ask) } // 第一次用时说一声，带着它打完一段才不再说
    }

    override func deactivateServer(_ sender: Any!) {
        committingTo = sender as? IMKTextInput
        session.focusLost()
        committingTo = nil
        isActive = false
        panel.hide()
        super.deactivateServer(sender)
    }

    /// 系统要求交出正在输入的内容（比如用户点了别处）：收尾上屏，不等待。
    override func commitComposition(_ sender: Any!) {
        committingTo = sender as? IMKTextInput
        session.focusLost()
        committingTo = nil
    }

    /// 系统要求取消组字：丢弃，不上屏。
    override func cancelComposition() {
        session.cancelComposition()
        super.cancelComposition()
    }

    override func hidePalettes() {
        panel.hide()
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        UpgradeWatch.lastKeyAt = Date()
        isActive = true // 收到按键的就是当前输入框（以防有的应用不先调 activateServer）
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            session.pointerPressed()
            return false
        }
        let flagsChanged = event.type == .flagsChanged
        guard flagsChanged || event.type == .keyDown,
              let key = MacKeys.translate(keyCode: event.keyCode, characters: flagsChanged ? nil : event.characters,
                                          modifierFlags: event.modifierFlags.rawValue, flagsChanged: flagsChanged)
        else { return false }
        // 开发模式的记录：安全输入（密码框等）、"不记录"的应用、暂停记录时什么都不记，连引擎的收发
        manager.applyPrivacy(secureInput: isSecureInput, mayRecord: mayRecord)
        manager.typing?.recorder?.record(.key, key.json)
        let handled = session.handle(key)
        reschedule()
        return handled
    }

    // MARK: - 引擎消息与计时

    func pump() {
        session.pump()
        reschedule()
    }

    /// 在状态机下一个到期时刻调用 tick（50 ms 画候选窗、1 秒卡死、5 秒退格计数等）。
    func reschedule() {
        timer?.cancel()
        timer = nil
        guard let deadline = session.nextDeadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + delay, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.session.tick()
            self.reschedule()
        }
        t.resume()
        timer = t
    }

    // MARK: - SessionClient

    func textBeforeCursor(limit: Int) -> String? {
        guard let c = textClient else { return nil }
        let sel = c.selectedRange()
        guard sel.location != NSNotFound else { return nil }
        if sel.location == 0 { return "" }
        let start = max(0, sel.location - limit)
        guard let text = c.attributedSubstring(from: NSRange(location: start, length: sel.location - start))?.string else { return nil }
        return String(text.suffix(limit))
    }

    var appID: String? { textClient?.bundleIdentifier() }

    var isSecureInput: Bool { IsSecureEventInputEnabled() }

    var mayRecord: Bool { manager.mayRecord(in: appID) }

    var mayPredict: Bool { manager.config.predict(for: appID) }

    /// 记忆记录开没开（自带的默认开）；会话照 PersonalPolicy 定能交给个人化组件什么。
    var memoryConsented: Bool { manager.memoryConsented }

    var personalThirdParty: Bool { manager.personalIsThirdParty }

    func insert(_ text: String) {
        textClient?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        lastMarked = "" // 上屏会顶掉光标处正在输入的文字
    }

    func caretLocation() -> Int? {
        guard let c = textClient else { return nil }
        let sel = c.selectedRange()
        return sel.location == NSNotFound ? nil : sel.location
    }

    func replaceStrayTab(at location: Int, with text: String) -> Bool {
        // 只在光标处放着显示串时认（联想打开时不管拼音显示在哪都放，0.1.16 起）：没有显示串时 location 处是原文，可能本来就是个制表符，不碰。
        guard let c = textClient, !lastMarked.isEmpty else { return false }
        let marked = c.markedRange()
        let char = c.attributedSubstring(from: NSRange(location: location, length: 1))?.string
        Self.log.notice("联想的 Tab：光标 \(location, privacy: .public)、显示串在 \(marked.location == NSNotFound ? -1 : marked.location, privacy: .public)、那一格是制表符 \(char == "\t", privacy: .public)")
        // Grok 里实测：制表符就在光标那一格，Chromium 报的显示串也从那一格起，也就是它把应用插的制表符算进了组字的范围。
        // 这时把显示串清掉，制表符就跟着没了；再照常上屏选的联想。别的写法都试过、不行：组字时 insertText 的替换范围不认；
        // 照常上屏后再替换是异步落下的，联想会出两遍或删多了；空串的 insertText 不认。
        // 没插的应用里，那一格是显示串的第一个字、不会是制表符，所以不会误动
        guard char == "\t", marked.location == location, !text.isEmpty else { return false }
        let none = NSRange(location: NSNotFound, length: NSNotFound)
        c.insertText(text, replacementRange: none)
        lastMarked = ""
        // 上屏是异步落到页面里的：等它落下以后、不在组字时，再把"制表符 + 联想"换成联想
        let range = NSRange(location: location, length: 1 + (text as NSString).length)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            guard c.attributedSubstring(from: NSRange(location: location, length: 1))?.string == "\t" else { return }
            c.insertText(text, replacementRange: range)
        }
        return true
    }


    func render(_ view: SessionView) {
        let inline = manager.config.inline(for: appID)
        // 联想打开时，高亮的那个总放在光标处，拼音显示在候选窗里的模式也一样：光标处没有显示串时，Chromium 会把输入法接下的
        // Tab、方向键再交给网页，Tab 就把焦点移走了（测试机上 Chrome 实测）。拼音本身照旧只显示在候选窗里
        // 拼音显示在候选窗里时，组字期间光标处放一个零宽空格当显示串：道理同上，没有显示串时 Chromium、Electron 会把输入法
        // 接下的退格、方向键再交给网页，删拼音的同时删掉已经上屏的字。零宽，看上去和光标处没有东西一样；上屏、Esc 时照常被换掉
        let marked = inline || view.predicting ? view.marked : (view.marked.isEmpty ? "" : "\u{200B}")
        if marked != lastMarked, let c = textClient {
            let attrs: [NSAttributedString.Key: Any] = [.underlineStyle: NSUnderlineStyle.single.rawValue, .markedClauseSegment: 0]
            c.setMarkedText(NSAttributedString(string: marked, attributes: attrs),
                            selectionRange: NSRange(location: (marked as NSString).length, length: 0),
                            replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            lastMarked = marked
        }
        guard isActive else { return }
        let caret = caretRect()
        if view.english != lastEnglish {
            lastEnglish = view.english
            manager.remember(english: view.english, for: appID)
            panel.flash(view.english ? "英" : "中", near: caret)
        }
        panel.show(view, markedInPanel: inline || view.predicting ? nil : view.marked, near: caret,
                   fontSize: manager.config.fontSize, orientation: manager.config.settings.orientation)
        panel.hideHint() // 联想现在直接画在候选窗里（淡一点），不再单独提示
    }

    private func caretRect() -> NSRect {
        var rect = NSRect.zero
        _ = textClient?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        if rect == .zero {
            let mouse = NSEvent.mouseLocation
            rect = NSRect(x: mouse.x, y: mouse.y - 20, width: 1, height: 20)
        }
        return rect
    }

    // MARK: - 菜单

    /// 菜单只放常用操作；全局默认值和按应用覆盖在设置窗口里（luokelabs/luoke-ime#1）。
    /// 菜单和设置窗口改的是同一份设置（EngineManager.update）。
    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "螺壳")
        let config = manager.config

        // ---- 螺壳没连上：打字照常，只是少了模型做的那几样；不提示的话只觉得「重排没了」，不知道原因
        if !manager.hubReachable {
            menu.addItem(disabled("未连接螺壳：AI 重排\(config.voiceOn ? "、联想和语音输入" : "和联想")不可用"))
            menu.addItem(.separator())
        }

        // ---- 输入方案
        let current = manager.typing?.id
        let engines = manager.typingEntries
        menu.addItem(disabled("输入方案"))
        if engines.isEmpty {
            menu.addItem(disabled("无可用引擎：请将引擎文件夹放入 ~/.luoke/ime/engines"))
        }
        for e in engines {
            let name = e.manifest?.name ?? e.id
            if let why = manager.refusal(e) {
                let item = detail("「\(name)」（第三方）不可用", why)
                item.indentationLevel = 1
                menu.addItem(item)
                continue
            }
            let suffix = e.bundled ? "" : manager.approved(e) ? "（第三方）" : "（第三方，需确认）"
            let item = NSMenuItem(title: name + suffix, action: #selector(selectEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = e.id
            item.state = e.id == current ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
        }
        // 等确认的第三方引擎里，不在上面那串里的：和自带的同名的、快捷键引擎、个人化组件
        for e in manager.pending where !engines.contains(where: { $0.id == e.id && !$0.bundled }) {
            let item = action("启用第三方引擎「\(e.manifest?.name ?? e.id)」", #selector(confirmPending(_:)))
            item.representedObject = e.id
            item.indentationLevel = 1
            menu.addItem(item)
        }
        for e in manager.entries where e.manifest == nil {
            menu.addItem(detail("\(e.id)：不可用", e.error ?? ""))
        }
        if let t = manager.typing, case let .disabled(reason) = t.state {
            menu.addItem(detail("「\(t.manifest.name)」已停用", reason))
            let again = action("重新启用「\(t.manifest.name)」", #selector(reenable(_:)))
            again.representedObject = t.id
            menu.addItem(again)
        }
        for h in manager.hotkeys { // 快捷键引擎（语音）停用了：候选窗说「原因见输入法菜单」，原因和重新启用都在这里
            guard case let .disabled(reason) = h.state else { continue }
            menu.addItem(detail("「\(h.manifest.name)」已停用", reason))
            let again = action("重新启用「\(h.manifest.name)」", #selector(reenable(_:)))
            again.representedObject = h.id
            menu.addItem(again)
        }
        addDenials(to: menu)
        let mode = action("当前模式：\(session.english ? "英文" : "中文")" + (config.settings.shiftToggles ? "（⇧ 切换）" : ""),
                          #selector(toggleCurrentMode(_:)))
        menu.addItem(mode)
        if let t = manager.typing, t.manifest.forgetAll {
            let clear = t.state == .running ? action("清除「\(t.manifest.name)」的已学词语", #selector(forgetLearned(_:)))
                : disabled("清除「\(t.manifest.name)」的已学词语（引擎未运行）")
            clear.representedObject = t.id
            menu.addItem(clear)
        }
        if let error = manager.migrationError {
            menu.addItem(detail("设置文件升级失败，修改的设置不会保存（原文件未改动）", error))
        }

        // ---- 当前应用
        if let app = appID {
            menu.addItem(.separator())
            menu.addItem(disabled("当前应用：\(appName(app))"))
            let settings = action("此应用设置（\(config.app(app).isEmpty ? "跟随全局" : "已自定义")）", #selector(openAppSettings(_:)))
            settings.representedObject = app
            settings.indentationLevel = 1
            menu.addItem(settings)
            if manager.personal != nil {
                if config.settings.predict || config.app(app).predict == true {
                    let off = action("在此应用关闭联想", #selector(toggleAppPredict(_:)))
                    // 照实际是否联想打勾：终端默认不联想（ShellConfig.predict(for:)），没覆盖时也是勾上的
                    off.state = config.predict(for: app) ? .off : .on
                    off.representedObject = app
                    off.indentationLevel = 1
                    menu.addItem(off)
                }
                let noRecord = action("在此应用禁止记录", #selector(toggleNoRecord(_:)))
                noRecord.state = config.noRecord(for: app) ? .on : .off
                noRecord.representedObject = app
                noRecord.indentationLevel = 1
                menu.addItem(noRecord)
            }
        }

        // ---- 记忆
        if let p = manager.personal {
            menu.addItem(.separator())
            if case let .disabled(reason) = p.state {
                menu.addItem(detail("「\(p.manifest.name)」已停用", reason))
                let again = action("重新启用「\(p.manifest.name)」", #selector(reenable(_:)))
                again.representedObject = p.id
                menu.addItem(again)
            }
            let state = manager.recordingState(in: appID)
            menu.addItem(disabled("记忆记录：\(Self.describe(state, status: manager.memoryStatus))"))
            switch state {
            case .notConsented:
                let on = action("开启记忆记录", #selector(openGlobalSettings(_:)))
                on.indentationLevel = 1
                menu.addItem(on)
            case .paused:
                let resume = action("恢复记录", #selector(togglePause(_:)))
                resume.indentationLevel = 1
                menu.addItem(resume)
            case .recording, .appForbidden:
                let pause = action("暂停所有记录", #selector(togglePause(_:)))
                pause.indentationLevel = 1
                menu.addItem(pause)
            case .unavailable:
                break
            }
            // 整份记忆在螺壳记忆（luoke-mem 配件）自己的界面里看和管（顶层 ADR 0002、0003）：这里只负责打开它
            if FileManager.default.fileExists(atPath: manager.paths.memory.path) {
                let manage = Self.memoryAvailable
                    ? action("管理记忆", #selector(openMemory(_:))) : disabled("管理记忆（需安装螺壳）")
                manage.indentationLevel = 1
                menu.addItem(manage)
            }
        }
        // ---- 设置
        menu.addItem(.separator())
        menu.addItem(action("设置", #selector(openGlobalSettings(_:))))
        let tools = NSMenu()
        if let t = manager.typing {
            let dev = action("开发模式：记录「\(t.manifest.name)」的输入", #selector(toggleDevMode(_:)))
            dev.state = config.devMode.contains(t.id) ? .on : .off
            dev.representedObject = t.id
            tools.addItem(dev)
            tools.addItem(disabled("开启时在本机记录按键和引擎收发，保留 7 天；与记忆记录无关"))
            tools.addItem(.separator())
        }
        tools.addItem(action("打开引擎文件夹", #selector(openEngines(_:))))
        tools.addItem(action("打开设置文件", #selector(openSettings(_:))))
        let toolsItem = NSMenuItem(title: "高级", action: nil, keyEquivalent: "")
        toolsItem.submenu = tools
        menu.addItem(toolsItem)
        return menu
    }

    /// 被沙盒拦下的操作：菜单里只写做了什么、对着哪里（路径截短），点一项复制完整说明，可以直接贴给写引擎的人或 agent
    private func addDenials(to menu: NSMenu) {
        for c in [manager.typing, manager.personal].compactMap({ $0 }) + manager.hotkeys {
            guard let ds = manager.denials[c.id], !ds.isEmpty else { continue }
            let sub = NSMenu()
            sub.addItem(disabled("点按条目复制详情"))
            for d in ds {
                let item = action(d.summary, #selector(copyDetail(_:)))
                item.toolTip = d.suggestion
                item.representedObject = d.suggestion
                sub.addItem(item)
            }
            sub.addItem(.separator())
            let all = action("复制全部", #selector(copyDetail(_:)))
            all.representedObject = ds.map(\.suggestion).joined(separator: "\n")
            sub.addItem(all)
            let clear = action("清除", #selector(clearDenials(_:)))
            clear.representedObject = c.id
            sub.addItem(clear)
            let item = NSMenuItem(title: "「\(c.manifest.name)」的 \(ds.count) 项操作被沙盒拦截", action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }
    }

    /// 记忆记录的状态写成一句话（菜单和设置窗口共用）。
    static func describe(_ state: EngineManager.RecordingState, status: String?) -> String {
        switch state {
        case .unavailable:
            switch status {
            case "too_new": return "不可用（记忆版本高于个人化组件，需更新输入法）"
            case "broken": return "不可用（记忆无法打开）"
            default: return "不可用"
            }
        case .notConsented: return "已关闭"
        case .paused: return "已暂停"
        case .appForbidden: return "当前应用禁止"
        case .recording: return "记录中"
        }
    }

    private func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        return item
    }

    /// 一行标题加一段可能很长的说明：说明截短接在标题后面，点一下复制完整的（菜单会按最长的一项变宽，长句会把它撑满屏幕）。
    private func detail(_ title: String, _ text: String) -> NSMenuItem {
        let first = text.components(separatedBy: "\n").first ?? text
        let short = first.count > 36 ? String(first.prefix(35)) + "…" : first
        let item = action(short.isEmpty ? title : "\(title)：\(short)", #selector(copyDetail(_:)))
        item.toolTip = text
        item.representedObject = "\(title)：\(text)"
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// 输入法菜单的动作发来的 sender 是个字典，菜单项在 IMKCommandMenuItem 里。
    private func menuItem(_ sender: Any?) -> NSMenuItem? {
        (sender as? NSMenuItem) ?? (sender as? [String: Any])?["IMKCommandMenuItem"] as? NSMenuItem
    }

    @objc private func selectEngine(_ sender: Any?) {
        guard let id = menuItem(sender)?.representedObject as? String else { return }
        if let e = manager.pending.first(where: { $0.id == id }) {
            if SettingsWindow.confirmThirdParty(e, replacing: manager.typingEntries.first { $0.id == id && $0.bundled }) { manager.approve(e) }
            return
        }
        manager.select(engine: id)
    }

    /// 启用等确认的第三方引擎：先弹系统的确认框，列出它要的权限（默认按钮是不启用）。
    @objc private func confirmPending(_ sender: Any?) {
        guard let id = menuItem(sender)?.representedObject as? String, let e = manager.pending.first(where: { $0.id == id }) else { return }
        let bundled = manager.entries.first { $0.id == id && $0.bundled }
        if SettingsWindow.confirmThirdParty(e, replacing: bundled) { manager.approve(e) }
    }

    /// 菜单里点"当前模式"：切换当前的中英文，和单按 Shift 一样（不改默认值）。
    @objc private func toggleCurrentMode(_ sender: Any?) {
        session.setEnglish(!session.english)
    }

    @objc private func openAppSettings(_ sender: Any?) {
        guard let app = menuItem(sender)?.representedObject as? String else { return }
        SettingsWindow.shared.show(.app(app, name: appName(app)))
    }

    @objc private func openGlobalSettings(_ sender: Any?) {
        SettingsWindow.shared.show(.global)
    }

    /// "在此应用关闭联想"：勾上是这个应用覆盖成关，取消是恢复跟随全局。
    @objc private func toggleAppPredict(_ sender: Any?) {
        guard let app = menuItem(sender)?.representedObject as? String else { return }
        manager.update { $0.togglePredict(app: app) }
    }

    @objc private func toggleDevMode(_ sender: Any?) {
        guard let id = menuItem(sender)?.representedObject as? String else { return }
        manager.toggleDevMode(id)
    }

    /// 清掉打字引擎学到的词：确认框在 SettingsWindow.confirmForgetLearned（设置窗口里也用）。
    @objc private func forgetLearned(_ sender: Any?) {
        guard let t = manager.typing, t.id == menuItem(sender)?.representedObject as? String else { return }
        SettingsWindow.confirmForgetLearned(t)
    }

    @objc private func reenable(_ sender: Any?) {
        let id = menuItem(sender)?.representedObject as? String
        manager.reenable(([manager.typing, manager.personal].compactMap { $0 } + manager.hotkeys).first { $0.id == id })
    }

    /// 螺壳记忆并进了主控（顶层 ADR 0003 文末修订）：`open luoke://memory`，主控没在跑时系统会拉起它
    ///（luoke-core 注册页「记忆并进主控、luoke://memory」）。过渡期主控还是旧版、没注册这个 scheme 时，退回旧的「螺壳记忆.app」。
    static let memoryURL = URL(string: "luoke://memory")!
    static let memoryApp = "ai.luoke.memory"

    /// 有没有能打开螺壳记忆的：认领 luoke:// 的主控，或者旧的螺壳记忆.app。
    static var memoryAvailable: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: memoryURL) != nil
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: memoryApp) != nil
    }

    /// 打开螺壳记忆的界面；壳不派生进程，也不管它的生命周期。
    static func openMemoryUI() {
        if NSWorkspace.shared.urlForApplication(toOpen: memoryURL) != nil {
            NSWorkspace.shared.open(memoryURL)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: memoryApp) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc private func openMemory(_ sender: Any?) {
        Self.openMemoryUI()
    }


    @objc private func copyDetail(_ sender: Any?) {
        guard let text = menuItem(sender)?.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func clearDenials(_ sender: Any?) {
        guard let id = menuItem(sender)?.representedObject as? String else { return }
        manager.clearDenials(id)
    }

    @objc private func toggleNoRecord(_ sender: Any?) {
        guard let app = menuItem(sender)?.representedObject as? String else { return }
        manager.update { c in c.setApp(app) { $0.noRecord.toggle() } }
    }

    @objc private func togglePause(_ sender: Any?) {
        manager.setRecordingPaused(!manager.config.recordingPaused)
    }

    @objc private func openEngines(_ sender: Any?) {
        NSWorkspace.shared.open(manager.paths.engines)
    }

    @objc private func openSettings(_ sender: Any?) {
        if !FileManager.default.fileExists(atPath: manager.paths.settings.path) { try? manager.config.save(manager.paths.settings) }
        NSWorkspace.shared.open(manager.paths.settings)
    }
}
