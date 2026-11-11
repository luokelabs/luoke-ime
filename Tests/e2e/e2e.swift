// 螺壳输入法的跨应用测试：在真实应用里用螺壳打字，再读回输入框的内容核对。
//
//   e2e <用例.tsv> <结果.jsonl> [应用 bundle id，默认 com.apple.TextEdit] [要打开的文件或网址]
//
// 浏览器：打开测试页（page.html#textarea / #input / #editable），在网页内容区里找到输入框并把焦点移过去。
//
// 用例每行：名称 \t 按键脚本 \t 期望输入框里的文字。按键脚本和 `luoke-ime try --keys` 一样：
// 普通字符照打，{space} {tab} {lbrace} {rbrace} {enter} {bs} {esc} {left} {right} {up} {down} {shift}（单按 Shift）
// {forget}（Shift+⌫） {wait:200} {hold:2000}（按住右 ⌥ 2 秒，触发 hold 模式的快捷键引擎） {probe}（记下此刻输入框、光标处的正在输入文字、候选窗是否可见）。
//
// 需要辅助功能权限（从 ssh 用 `open -a Terminal run.command` 启动，借用终端的授权）。
// 测试期间不要碰键盘鼠标；每发一个键前都核对焦点仍在被测应用里，不在就立即中止。
import AppKit
import ApplicationServices
import Carbon

let args = CommandLine.arguments
guard args.count >= 3 else { print("用法：e2e <用例.tsv> <结果.jsonl> [bundle id] [文件或网址]"); exit(2) }
let casesPath = args[1], outPath = args[2]
let bundle = args.count > 3 ? args[3] : "com.apple.TextEdit"
let documentArg = args.count > 4 ? args[4] : nil
/// 页面报告模式：测试页从本机小服务（pageserver.py）打开时，它自己把输入框状态写到这个文件，不靠辅助功能。
let pageState: String? = documentArg?.hasPrefix("http://127.0.0.1") == true
    ? FileManager.default.currentDirectoryPath + "/results/page-state.json" : nil
func pageRead() -> [String: Any]? {
    guard let p = pageState, let d = FileManager.default.contents(atPath: p) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}
let luokeMode = "ai.luoke.inputmethod.Luoke.Hans"
var targetPid: pid_t = 0

func log(_ entry: [String: Any]) {
    guard var d = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
    d.append(0x0A)
    if let h = FileHandle(forWritingAtPath: outPath) { h.seekToEndOfFile(); h.write(d); h.closeFile() }
    else { FileManager.default.createFile(atPath: outPath, contents: d) }
    FileHandle.standardError.write(d)
}
func wait(_ s: Double) { usleep(useconds_t(s * 1_000_000)) }

// MARK: - 辅助功能

func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func range(_ e: AXUIElement, _ n: String) -> CFRange? {
    guard let v = attr(e, n), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var r = CFRange(); return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
}
/// 键盘焦点所在的元素。系统级查询失败时（Chrome），直接问被测应用。
func focused() -> AXUIElement? {
    if let e = attr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as String) { return (e as! AXUIElement) }
    guard targetPid != 0 else { return nil }
    return attr(AXUIElementCreateApplication(targetPid), kAXFocusedUIElementAttribute as String).map { $0 as! AXUIElement }
}
/// 键盘焦点所在应用的进程号。有的应用（Chrome）默认不响应辅助功能查询，这时退回看最前面的普通窗口属于谁。
func focusedPid() -> pid_t? {
    if let app = attr(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as String) {
        var pid: pid_t = 0
        if AXUIElementGetPid(app as! AXUIElement, &pid) == .success { return pid }
    }
    let ws = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return ws.first { ($0[kCGWindowLayer as String] as? Int) == 0 }.flatMap { ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) }
}

/// Chrome 默认不对外提供辅助功能信息：给它打开。
func enableChromeAccessibility() {
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome") {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
func text(_ e: AXUIElement) -> String { (attr(e, kAXValueAttribute as String) as? String) ?? "" }


func guardFront(_ at: String) {
    if focusedPid() != targetPid || targetPid == 0 {
        log(["phase": "abort", "at": at, "focused_pid": Int(focusedPid() ?? -1), "target_pid": Int(targetPid)])
        restoreInput()
        exit(3)
    }
}

/// 启动时文本编辑会弹出"打开"面板（单独的进程），按取消。
func dismissPanel() {
    guard let pid = focusedPid(),
          NSRunningApplication(processIdentifier: pid)?.bundleIdentifier?.contains("openAndSavePanelService") == true,
          let win = attr(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as String) else { return }
    func find(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
        if (attr(e, kAXRoleAttribute as String) as? String) == "AXButton",
           ["取消", "Cancel"].contains(attr(e, kAXTitleAttribute as String) as? String ?? "") { return e }
        guard depth < 12 else { return nil }
        for c in (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] { if let f = find(c, depth + 1) { return f } }
        return nil
    }
    if let cancel = find(win as! AXUIElement, 0) { AXUIElementPerformAction(cancel, kAXPressAction as CFString); wait(0.8) }
}

/// 把应用调到前台（可选：用它打开一个文件），并核实键盘焦点真的在它里面。
func activate(_ bundle: String, document: String?) -> Bool {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return false }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = true
    let done = DispatchSemaphore(value: 0)
    if let doc = document {
        let target = doc.contains("://") ? URL(string: doc)! : URL(fileURLWithPath: doc)
        NSWorkspace.shared.open([target], withApplicationAt: url, configuration: cfg) { _, _ in done.signal() }
    } else {
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in done.signal() }
    }
    _ = done.wait(timeout: .now() + 10)
    if bundle == "com.google.Chrome" { enableChromeAccessibility(); wait(1.0) }
    for attempt in 0..<2 {
        for _ in 0..<24 {
            dismissPanel()
            if let pid = focusedPid(), NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundle {
                targetPid = pid; wait(0.5); return true
            }
            wait(0.25)
        }
        if attempt == 0 {
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-a", url.path] + (document.map { [$0] } ?? []))
        }
    }
    return false
}

// MARK: - 输入源

func inputSourceID(_ s: TISInputSource) -> String? {
    TISGetInputSourceProperty(s, kTISPropertyInputSourceID).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
}
func selectInput(_ id: String) -> Bool {
    let list = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
    for s in list where inputSourceID(s) == id { return TISSelectInputSource(s) == noErr }
    return false
}
let original = inputSourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
func restoreInput() { if let o = original { _ = selectInput(o) } }

// MARK: - 发键（美式键盘布局）

let keyCodes: [Character: (CGKeyCode, Bool)] = {
    var m: [Character: (CGKeyCode, Bool)] = [:]
    let lower: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
    ]
    for (c, k) in lower { m[c] = (k, false) }
    for (c, k) in lower where c.isLetter { m[Character(c.uppercased())] = (k, true) }
    let shifted: [Character: Character] = ["!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
                                           "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`"]
    for (s, base) in shifted { m[s] = (lower[base]!, true) }
    return m
}()

func post(_ code: CGKeyCode, flags: CGEventFlags = []) {
    guardFront("post")
    let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
    let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)!
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

/// 单按 Shift：按下、松开，中间没有别的键。
func shiftTap() {
    guardFront("shift")
    let down = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true)!
    down.type = .flagsChanged
    down.flags = [.maskShift, CGEventFlags(rawValue: 0x02)]
    let up = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: false)!
    up.type = .flagsChanged
    up.flags = []
    down.post(tap: .cghidEventTap)
    usleep(40_000)
    up.post(tap: .cghidEventTap)
}

/// 按住右 ⌥ 若干秒再松开（快捷键引擎用 hold 模式的右 ⌥ 时触发它）。0x40 是设备相关的右 ⌥ 位。
func holdRightOption(_ seconds: Double) {
    guardFront("hold")
    let down = CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: true)!
    down.type = .flagsChanged
    down.flags = [.maskAlternate, CGEventFlags(rawValue: 0x40)]
    let up = CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: false)!
    up.type = .flagsChanged
    up.flags = []
    down.post(tap: .cghidEventTap)
    wait(seconds)
    up.post(tap: .cghidEventTap)
}

/// 螺壳进程有没有在屏幕上的浮动窗口（候选窗）。窗口所有者名是应用的显示名（螺壳 / Luoke），所以按进程号认。
func frame(_ e: AXUIElement) -> [Int]? {
    guard let p = attr(e, kAXPositionAttribute as String), let z = attr(e, kAXSizeAttribute as String) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(z as! AXValue, .cgSize, &sz)
    return [Int(pt.x), Int(pt.y), Int(sz.width), Int(sz.height)]
}

/// 螺壳的浮动窗口（候选窗、中/英提示）在屏幕上的位置：[x, y, 宽, 高]，坐标原点在左上角，和辅助功能一致。
func panelFrames() -> [[Int]] {
    let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "ai.luoke.inputmethod.Luoke").map(\.processIdentifier))
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.compactMap { w in
        guard pids.contains((w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) ?? -1), (w[kCGWindowLayer as String] as? Int ?? 0) > 0,
              let b = w[kCGWindowBounds as String] as? [String: Double] else { return nil }
        return [Int(b["X"] ?? 0), Int(b["Y"] ?? 0), Int(b["Width"] ?? 0), Int(b["Height"] ?? 0)]
    }
}

/// 浏览器：在网页内容区（AXWebArea）里找第一个输入框。
var webField: AXUIElement?
func findWebField() -> AXUIElement? {
    let app = AXUIElementCreateApplication(targetPid)
    guard let win = attr(app, kAXFocusedWindowAttribute as String) ?? attr(app, kAXMainWindowAttribute as String) else { return nil }
    func find(_ e: AXUIElement, _ role: Set<String>, _ depth: Int) -> AXUIElement? {
        if let r = attr(e, kAXRoleAttribute as String) as? String, role.contains(r) { return e }
        guard depth < 40 else { return nil }
        for c in (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] { if let f = find(c, role, depth + 1) { return f } }
        return nil
    }
    guard let web = find(win as! AXUIElement, ["AXWebArea"], 0) else { return nil }
    return find(web, ["AXTextArea", "AXTextField"], 0)
}

func click(_ f: [Int]) {
    let pt = CGPoint(x: f[0] + f[2] / 2, y: f[1] + min(f[3] / 2, 20))
    for t in [CGEventType.leftMouseDown, .leftMouseUp] { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap) }
}

/// 把焦点移到网页里的输入框：先用辅助功能设焦点，不行再点它一下。
func focusWebField() -> Bool {
    if bundle == "com.google.Chrome" { enableChromeAccessibility(); wait(0.5) }
    for _ in 0..<20 {
        if let f = findWebField() {
            webField = f
            AXUIElementSetAttributeValue(f, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            wait(0.4)
            if let now = focused(), CFEqual(now, f) { return true }
            if let fr = frame(f) { click(fr); wait(0.4) }
            if let now = focused(), CFEqual(now, f) { return true }
        }
        wait(0.5)
    }
    return false
}

func panelVisible() -> Bool {
    let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "ai.luoke.inputmethod.Luoke").map(\.processIdentifier))
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.contains { pids.contains(($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) ?? -1) && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }
}

/// 执行按键脚本；{probe} 记下当时的状态。
func run(_ script: String, gap: useconds_t = 40_000) -> [[String: Any]] {
    var probes: [[String: Any]] = []
    var i = script.startIndex
    while i < script.endIndex {
        let c = script[i]
        if c == "{", let close = script[i...].firstIndex(of: "}") {
            let name = String(script[script.index(after: i)..<close])
            i = script.index(after: close)
            switch name {
            case "space": post(49)
            case "tab": post(48)
            case "lbrace": post(33, flags: .maskShift) // { 本身是脚本的记号，花括号用这两个名字
            case "rbrace": post(30, flags: .maskShift)
            case "enter": post(36)
            case "bs": post(51)
            case "esc": post(53)
            case "left": post(123)
            case "right": post(124)
            case "down": post(125)
            case "up": post(126)
            case "shift": shiftTap()
            case "forget": post(51, flags: .maskShift)
            case "probe":
                wait(0.3)
                if let st = pageRead() {
                    probes.append(["text": st["value"] as? String ?? "", "marked": (st["composing"] as? String ?? "").count,
                                   "panel": panelVisible(), "panel_frames": panelFrames()])
                    continue
                }
                let f = webField ?? focused()
                var probe: [String: Any] = ["text": f.map(text) ?? "",
                                            "marked": f.flatMap { range($0, "AXTextInputMarkedRange") }.map { $0.length } ?? 0,
                                            "panel": panelVisible()]
                if let f, let fr = frame(f) { probe["field_frame"] = fr }
                probe["panel_frames"] = panelFrames()
                probes.append(probe)
            default:
                if name.hasPrefix("wait:"), let ms = Double(name.dropFirst(5)) { wait(ms / 1000) }
                if name.hasPrefix("hold:"), let ms = Double(name.dropFirst(5)) { holdRightOption(ms / 1000) }
            }
        } else {
            if let (k, shift) = keyCodes[c] { post(k, flags: shift ? .maskShift : []) }
            i = script.index(after: i)
        }
        usleep(gap)
    }
    return probes
}

// MARK: - 主流程

guard AXIsProcessTrusted() else { FileHandle.standardError.write(Data("需要辅助功能权限\n".utf8)); exit(77) }
struct Case { let name, keys, expected: String }
let cases: [Case] = (try! String(contentsOfFile: casesPath, encoding: .utf8)).split(separator: "\n").compactMap {
    if $0.hasPrefix("#") { return nil }
    let f = $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    return f.count >= 3 ? Case(name: f[0], keys: f[1], expected: f[2]) : nil
}

// 先选好螺壳，再激活目标应用（反过来的话，目标应用可能还在用原来的输入法）
// 先切到别的输入法再切回来，让各应用重新连上螺壳
_ = selectInput("com.apple.keylayout.US") || selectInput("com.apple.keylayout.ABC")
wait(0.3)
guard selectInput(luokeMode) else { log(["phase": "abort", "reason": "系统里没有螺壳输入源"]); exit(70) }
wait(0.5)
let scratch = NSTemporaryDirectory() + "luoke-e2e-\(UUID().uuidString.prefix(8)).txt"
FileManager.default.createFile(atPath: scratch, contents: Data())
let doc: String? = documentArg ?? (bundle == "com.apple.TextEdit" ? scratch : nil)
guard activate(bundle, document: doc) else { log(["phase": "abort", "reason": "无法把 \(bundle) 调到前台"]); restoreInput(); exit(3) }
let isBrowser = bundle != "com.apple.TextEdit"
if pageState != nil {
    // 测试页加载后自己把焦点放进输入框；等它报告"已获得焦点"
    var ok = false
    for _ in 0..<40 where !ok { ok = pageRead()?["focused"] as? Bool == true; if !ok { wait(0.25) } }
    if !ok { log(["phase": "abort", "reason": "测试页没有报告输入框获得焦点"]); restoreInput(); exit(3) }
} else if isBrowser, !focusWebField() {
    log(["phase": "abort", "reason": "找不到或聚焦不了网页里的输入框"]); restoreInput(); exit(3)
}
log(["phase": "start", "app": bundle, "input": inputSourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) ?? "?"])

var passed = 0
for c in cases {
    if pageState == nil, isBrowser, let w = webField, !(focused().map { CFEqual($0, w) } ?? false) { _ = focusWebField() }
    let field = webField ?? focused()
    if pageState == nil, field == nil { log(["phase": "abort", "reason": "找不到焦点输入框"]); break }
    // 清空输入框：全选后删除
    post(0, flags: .maskCommand)
    post(51)
    wait(0.3)
    let t0 = Date()
    let probes = run(c.keys)
    wait(0.6)
    var got = pageState != nil ? (pageRead()?["value"] as? String ?? "") : field.map(text) ?? ""
    if pageState != nil {
        // 页面的报告是异步的：等它追上（最多 2 秒）
        for _ in 0..<20 where got != c.expected { wait(0.1); got = pageRead()?["value"] as? String ?? "" }
    }
    let ok = got == c.expected
    if ok { passed += 1 }
    log(["case": c.name, "keys": c.keys, "expected": c.expected, "got": got, "ok": ok, "probes": probes,
         "seconds": (Date().timeIntervalSince(t0) * 100).rounded() / 100])
}
post(0, flags: .maskCommand)
post(51)
restoreInput()
log(["phase": "done", "passed": passed, "total": cases.count])
try? FileManager.default.removeItem(atPath: scratch)
