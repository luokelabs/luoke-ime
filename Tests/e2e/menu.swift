import AppKit
import ApplicationServices
import Carbon

// 输入法菜单和设置窗口的真机核对（luokelabs/luoke-ime#1、#2）：在图形会话里跑（menu.command，借终端的辅助功能授权）。
// 只点菜单项、开关设置窗口、切两次当前模式（再切回来），不打字、不改别的设置。结果写成 JSON。
//   menu <结果.json> [文本文件]

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let document = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let modeID = "ai.luoke.inputmethod.Luoke.Hans"
let imeBundle = "ai.luoke.inputmethod.Luoke"
var steps: [[String: Any]] = []

func wait(_ s: Double) { usleep(useconds_t(s * 1_000_000)) }
func note(_ step: String, _ ok: Bool, _ detail: Any = "") {
    steps.append(["step": step, "ok": ok, "detail": detail])
    let data = try! JSONSerialization.data(withJSONObject: ["steps": steps], options: [.prettyPrinted, .sortedKeys])
    try? data.write(to: out)
    FileHandle.standardError.write(Data("\(ok ? "✓" : "✗") \(step)\n".utf8))
}

func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] }
func title(_ e: AXUIElement) -> String { (attr(e, kAXTitleAttribute as String) as? String) ?? "" }
func press(_ e: AXUIElement) -> Bool { AXUIElementPerformAction(e, kAXPressAction as CFString) == .success }

/// 一棵 AX 树里所有能读到的文字（标题、值、说明），用来核对窗口里有什么。
func texts(_ e: AXUIElement, depth: Int = 0) -> [String] {
    guard depth < 14 else { return [] }
    var out: [String] = []
    for k in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] as [String] {
        if let s = attr(e, k) as? String, !s.isEmpty { out.append(s) }
    }
    for c in children(e) { out += texts(c, depth: depth + 1) }
    return out
}

func app(_ bundle: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
}

func frontBundle() -> String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

/// 键盘焦点所在元素属于哪个进程（不激活应用的面板也能拿到键盘焦点，前台应用不变）。
func focusOwner() -> String? {
    guard let f = attr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as String) else { return nil }
    var pid: pid_t = 0
    guard AXUIElementGetPid(f as! AXUIElement, &pid) == .success else { return nil }
    return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
}

// MARK: 输入源

func sourceID(_ s: TISInputSource) -> String? {
    TISGetInputSourceProperty(s, kTISPropertyInputSourceID).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
}
func select(_ id: String) -> Bool {
    let list = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
    for s in list where sourceID(s) == id { return TISSelectInputSource(s) == noErr }
    return false
}
let original = sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())

// MARK: 输入法菜单（系统的 TextInputMenuAgent 画的，螺壳的菜单项由输入法给）

func menuExtra() -> AXUIElement? {
    guard let agent = app("com.apple.TextInputMenuAgent") else { return nil }
    let a = AXUIElementCreateApplication(agent.processIdentifier)
    guard let bar = attr(a, "AXExtrasMenuBar") else { return nil }
    return children(bar as! AXUIElement).first
}

func role(_ e: AXUIElement) -> String { (attr(e, kAXRoleAttribute as String) as? String) ?? "" }

/// 在一棵树里找打开着的菜单（AXMenu，有子项的）。
func findMenu(_ e: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if role(e) == "AXMenu", !children(e).isEmpty { return e }
    guard depth < 5 else { return nil }
    for c in children(e) { if let m = findMenu(c, depth: depth + 1) { return m } }
    return nil
}

func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute as String), let z = attr(e, kAXSizeAttribute as String) else { return nil }
    var pos = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pos)
    AXValueGetValue(z as! AXValue, .cgSize, &size)
    return CGRect(origin: pos, size: size)
}

/// 真的点一下鼠标（macOS 26 上菜单栏的输入法图标不认 AXPress，-25204）。
func click(_ e: AXUIElement) -> Bool {
    guard let f = frame(e) else { return false }
    let c = CGPoint(x: f.midX, y: f.midY)
    for t in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: c, mouseButton: .left)!.post(tap: .cghidEventTap)
        usleep(80_000)
    }
    return true
}

/// 选一个菜单项：先 AXPress，不行就点它。
func choose(_ item: AXUIElement) {
    if !press(item) { _ = click(item) }
}

/// 打开输入法菜单，返回菜单项（没打开就是空的）。菜单挂在菜单栏项下面。
func openMenu() -> [AXUIElement] {
    guard let extra = menuExtra(), click(extra) else { return [] }
    for _ in 0..<15 {
        wait(0.2)
        if let m = findMenu(extra) { return children(m).filter { role($0) == "AXMenuItem" } }
    }
    return []
}

func closeMenu() {
    let esc = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!
    esc.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)!.post(tap: .cghidEventTap)
    wait(0.5)
}

func settingsWindow() -> AXUIElement? {
    guard let ime = app(imeBundle) else { return nil }
    let a = AXUIElementCreateApplication(ime.processIdentifier)
    return ((attr(a, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []).first { title($0) == "螺壳输入法设置" }
}

func closeSettings() {
    guard let w = settingsWindow(), let close = attr(w, kAXCloseButtonAttribute as String) else { return }
    _ = press(close as! AXUIElement)
    wait(1.0)
}

func settingsJSON() -> [String: Any] {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".luoke/ime/settings.json")
    guard let d = try? Data(contentsOf: url) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
}

// MARK: 开始

guard AXIsProcessTrusted() else { note("辅助功能授权", false, "这个终端没有辅助功能授权"); exit(1) }

// 1. 打开文本编辑、切到螺壳
let edit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")!
let cfg = NSWorkspace.OpenConfiguration()
cfg.activates = true
let opened = DispatchSemaphore(value: 0)
if let document {
    NSWorkspace.shared.open([URL(fileURLWithPath: document)], withApplicationAt: edit, configuration: cfg) { _, _ in opened.signal() }
} else {
    NSWorkspace.shared.openApplication(at: edit, configuration: cfg) { _, _ in opened.signal() }
}
_ = opened.wait(timeout: .now() + 10)
wait(2)
note("文本编辑在前台", frontBundle() == "com.apple.TextEdit", frontBundle() ?? "?")
note("切到螺壳", select(modeID))
wait(1.5)

// 2. 菜单里有螺壳、有新的几项
var items = openMenu()
var titles = items.map(title)
note("输入法菜单打得开", !items.isEmpty, titles)
note("输入法菜单里有螺壳这个输入源", titles.contains { $0.contains("螺壳") || $0.contains("Luoke") })
for want in ["输入方案", "当前模式：", "当前应用：", "此应用设置", "设置", "高级"] {
    note("菜单里有「\(want)」", titles.contains { $0.hasPrefix(want) })
}

// 3. 设置：窗口出来、到前台；关掉后还给文本编辑
if let g = items.first(where: { title($0) == "设置" }) {
    choose(g)
    wait(2)
    let w = settingsWindow()
    note("设置打开了设置窗口", w != nil)
    note("键盘焦点在设置窗口里", focusOwner() == imeBundle, ["焦点": focusOwner() ?? "?", "前台应用": frontBundle() ?? "?"])
    if let w {
        let t = texts(w)
        note("设置窗口里的字", t.contains { $0.contains("记住各应用上次的中英文模式") }, Array(t.prefix(40)))
        note("通用页里有记忆记录的总开关、联想不叫上屏后联想", t.contains { $0.contains("记录输入内容到记忆") } && !t.contains { $0.contains("上屏后联想") },
             t.filter { $0.contains("记忆") || $0.contains("联想") })
    }
    closeSettings()
    note("关掉设置窗口后文本编辑回到前台", frontBundle() == "com.apple.TextEdit", frontBundle() ?? "?")
} else {
    closeMenu()
}

// 4. 此应用设置：直达文本编辑那一条
items = openMenu()
if let a = items.first(where: { title($0).hasPrefix("此应用设置") }) {
    choose(a)
    wait(2)
    let w = settingsWindow()
    let t = w.map { texts($0) } ?? []
    note("此应用设置直达当前应用", t.contains { $0.contains("文本编辑") || $0.contains("TextEdit") } && t.contains { $0.contains("默认输入模式") },
         Array(t.prefix(40)))
    closeSettings()
} else {
    closeMenu()
}

// 5. 点"当前模式"切换，记住上次模式时存进设置；再切回来
items = openMenu()
titles = items.map(title)
if let m = items.first(where: { title($0).hasPrefix("当前模式：") }) {
    let before = title(m)
    choose(m)
    wait(1.0)
    let modes = settingsJSON()["app_modes"] as? [String: String] ?? [:]
    note("点当前模式切换后记进了设置", modes["com.apple.TextEdit"] != nil, ["之前": before, "app_modes": modes])
    items = openMenu()
    note("菜单上的当前模式跟着变了", items.contains { title($0).hasPrefix("当前模式：") && title($0) != before }, items.map(title).filter { $0.hasPrefix("当前模式") })
    if let back = items.first(where: { title($0).hasPrefix("当前模式：") }) { choose(back); wait(1.0) } else { closeMenu() }
    let after = settingsJSON()["app_modes"] as? [String: String] ?? [:]
    note("切回来以后设置里不再记它（和默认一样的不存）", after["com.apple.TextEdit"] == nil, after)
} else {
    closeMenu()
}

// 6. 清掉学到的词：确认框出来、默认是取消；按取消，学到的词不动
let memURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".luoke/ime/data/xiaohe/memory.json")
let memBefore = try? Data(contentsOf: memURL)
items = openMenu()
if let f = items.first(where: { title($0).hasPrefix("清掉「") }) {
    choose(f)
    wait(2)
    var dialog: AXUIElement?
    if let ime = app(imeBundle) {
        let a = AXUIElementCreateApplication(ime.processIdentifier)
        dialog = ((attr(a, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []).first { texts($0).contains { $0.contains("学到的词？") } }
    }
    note("清掉学到的词：确认框出来了", dialog != nil, dialog.map { Array(texts($0).prefix(10)) } ?? [])
    note("确认框时键盘焦点在它上面", focusOwner() == imeBundle, ["焦点": focusOwner() ?? "?", "前台应用": frontBundle() ?? "?"])
    if let dialog {
        func buttons(_ e: AXUIElement, _ d: Int = 0) -> [AXUIElement] {
            guard d < 6 else { return [] }
            return (role(e) == "AXButton" ? [e] : []) + children(e).flatMap { buttons($0, d + 1) }
        }
        let cancel = buttons(dialog).first { title($0) == "取消" }
        note("确认框里有取消", cancel != nil, buttons(dialog).map(title))
        if let cancel { choose(cancel) }
        wait(1.5)
    }
    note("按了取消，学到的词没动", (try? Data(contentsOf: memURL)) == memBefore)
    note("确认框关掉以后文本编辑回到前台", frontBundle() == "com.apple.TextEdit", frontBundle() ?? "?")
} else {
    closeMenu()
    note("菜单里有清掉学到的词", false, items.map(title))
}

// 7. 第三方引擎（luokelabs/luoke-ime#6）：引擎目录里有第三方的打字引擎时，菜单里标着"确认后才能用"，点它弹确认框；
//    按"不启用"，设置里不记、当前引擎不变
items = openMenu()
if let t = items.first(where: { title($0).contains("（第三方，确认后才能用…）") }) {
    let before = settingsJSON()
    choose(t)
    wait(2)
    var dialog: AXUIElement?
    if let ime = app(imeBundle) {
        let a = AXUIElementCreateApplication(ime.processIdentifier)
        dialog = ((attr(a, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []).first { texts($0).contains { $0.contains("启用第三方引擎") } }
    }
    let t2 = dialog.map { texts($0) } ?? []
    note("第三方引擎：点它弹确认框，写明不能联网", t2.contains { $0.contains("不能联网") }, Array(t2.prefix(12)))
    if let dialog {
        func buttons(_ e: AXUIElement, _ d: Int = 0) -> [AXUIElement] {
            guard d < 6 else { return [] }
            return (role(e) == "AXButton" ? [e] : []) + children(e).flatMap { buttons($0, d + 1) }
        }
        if let no = buttons(dialog).first(where: { title($0) == "不启用" }) { choose(no) }
        wait(1.5)
    }
    let after = settingsJSON()
    note("按了不启用：没记成确认过、当前引擎没变",
         (after["approved_engines"] as? [String: String] ?? [:]).isEmpty && (after["current_engine"] as? String) == (before["current_engine"] as? String),
         ["approved_engines": after["approved_engines"] ?? [:], "current_engine": after["current_engine"] ?? "nil"])
} else {
    closeMenu()
    note("菜单里有等确认的第三方引擎", false, items.map(title))
}

// 8. 设置文件已经是第 2 版，原文件另存了
let s = settingsJSON()
let backup = FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".luoke/ime/settings.v1.json").path)
note("设置文件是第 2 版", (s["version"] as? Int) == 2, s.keys.sorted())
note("第 1 版另存为 settings.v1.json", backup)

if let original { _ = select(original) }
note("完成", true)
