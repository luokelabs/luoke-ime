import AppKit
import InputMethodKit
import LuokeShell

// 螺壳输入法（macOS 外壳）。
//
//   LuokeIME                         作为输入法运行（由系统启动）
//   LuokeIME --register              注册输入源（macOS 26 以前还请求启用；26 起要用户在系统设置里自己添加）
//   LuokeIME --select                把螺壳设为当前输入源，并核对真的切过去了（0 切过去了，1 调用失败，3 调用成功但没切过去）
//   LuokeIME --disable               停用输入源
//   LuokeIME --current               打印当前输入源
//   LuokeIME --status                一行 JSON：注册了没有、用户添加了没有、能不能切过去（给主控的向导和诊断）
//   LuokeIME --render-panel <out.png> [dark] [pending] [predict]   把候选窗画成图片（检查外观用；pending：画出"还在算"的小点；
//                                                                  predict：画还没激活的联想）
//   LuokeIME --render-guide <out.png> [added] [dark] [tutorial1|2|3]   把添加输入源的引导窗口画成图片
//   LuokeIME --render-settings <out.png> [global|apps|privacy|tools] [dark]   把设置窗口的一页画成图片（检查外观用）

let arguments = CommandLine.arguments

if arguments.contains("--register") {
    exit(InputSource.register(bundle: Bundle.main.bundleURL) ? 0 : 1)
}
if arguments.contains("--select") {
    exit(InputSource.selectVerified())
}
if arguments.contains("--disable") {
    InputSource.disable()
    exit(0)
}
if arguments.contains("--status") {
    print(InputSource.status())
    exit(0)
}
if arguments.contains("--current") {
    print(InputSource.current() ?? "")
    exit(0)
}
if let i = arguments.firstIndex(of: "--render-panel"), i + 1 < arguments.count {
    let rest = arguments.dropFirst(i + 2)
    exit(CandidatePanel.snapshot(to: URL(fileURLWithPath: arguments[i + 1]), dark: rest.contains("dark"), pending: rest.contains("pending"),
                                 predict: rest.contains("predict")) ? 0 : 1)
}
if let i = arguments.firstIndex(of: "--render-guide"), i + 1 < arguments.count {
    let rest = arguments.dropFirst(i + 2)
    _ = NSApplication.shared
    let tutorial = rest.compactMap { $0.hasPrefix("tutorial") ? Int($0.dropFirst(8)).map { $0 - 1 } : nil }.first
    exit(AddGuide.snapshot(to: URL(fileURLWithPath: arguments[i + 1]), added: rest.contains("added"), dark: rest.contains("dark"),
                           tutorialStep: tutorial) ? 0 : 1)
}
if let i = arguments.firstIndex(of: "--render-settings"), i + 1 < arguments.count {
    let rest = arguments.dropFirst(i + 2)
    let tab = rest.compactMap(SettingsModel.Tab.init(rawValue:)).first ?? .global
    _ = NSApplication.shared
    exit(SettingsWindow.snapshot(to: URL(fileURLWithPath: arguments[i + 1]), tab: tab, dark: rest.contains("dark")) ? 0 : 1)
}

// 走到这里就要当输入法服务起 IMKServer。带了别的参数（--help、拼错的）就打印用法退出：从终端起出第二个同身份的
// IMKServer，它退出时系统登记的输入端点跟着没了，正在用的螺壳失联（luokelabs/luoke-ime#7）。系统启动时不带参数；
// 老系统可能带 -psn_，AppKit 认的 -NS… / -Apple… 也放过。
let usage = """
用法：LuokeIME --register | --select | --disable | --current | --status
      LuokeIME --render-panel <out.png> [dark] [pending] [predict]
      LuokeIME --render-settings <out.png> [global|apps|privacy|tools] [dark]
      LuokeIME --render-guide <out.png> [added] [dark] [tutorial1|2|3]
不带参数时作为输入法运行，只该由系统启动（从终端直接运行会退出）。

"""
let extra = arguments.dropFirst().filter { !$0.hasPrefix("-psn_") && !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
if !extra.isEmpty {
    let help = extra.contains("--help") || extra.contains("-h")
    FileHandle.standardError.write(Data(((help ? "" : "不认识的参数：\(extra.joined(separator: " "))\n") + usage).utf8))
    exit(help ? 0 : 2)
}

// 只当一份输入法服务（luokelabs/luoke-ime#7 后续）：不带参数从终端、脚本直接运行，或者 `open` 起出第二份，
// 它也会起同名的 IMKServer，退出时正在用的螺壳失联。系统拉起的父进程是 launchd；再用一把文件锁占位，
// 已有一份在跑就退出。换装时旧的那份可能还没退完，所以拿锁最多等 3 秒。
if getppid() != 1 {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
let lockPath = FileManager.default.temporaryDirectory.appendingPathComponent((Bundle.main.bundleIdentifier ?? "LuokeIME") + ".lock").path
let lockFD = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
var locked = lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) == 0
let lockDeadline = Date().addingTimeInterval(3)
while lockFD >= 0, !locked, Date() < lockDeadline {
    usleep(50_000)
    locked = flock(lockFD, LOCK_EX | LOCK_NB) == 0
}
if lockFD >= 0, !locked {
    // 用户自己又打开了一次（Finder 里双击）：请在跑的那份看看要不要弹添加输入源的引导，这一份退出
    DistributedNotificationCenter.default().postNotificationName(AddGuide.showRequest, object: nil, userInfo: nil, deliverImmediately: true)
    FileHandle.standardError.write(Data("螺壳输入法已经有一份在运行，这一份退出\n".utf8))
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let connection = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String ?? "ai.luoke.inputmethod.Luoke_Connection"
guard let server = IMKServer(name: connection, bundleIdentifier: Bundle.main.bundleIdentifier) else {
    fatalError("螺壳无法启动 InputMethodKit 服务")
}
EngineManager.shared.start()
EnabledWatch.start()
UpgradeWatch.start()
// 用户自己打开了 LuokeIME.app、螺壳却还没被添加：弹引导（系统只拉起已经添加的输入法，所以没添加时只能是用户打开的）
DispatchQueue.main.async { AddGuide.shared.showIfNeeded() }
DistributedNotificationCenter.default().addObserver(forName: AddGuide.showRequest, object: nil, queue: .main) { _ in
    AddGuide.shared.showIfNeeded()
}
// 已经在跑时用户在 Finder 里双击（或 `open`）：系统不另起一份，只给在跑的这份发"重新打开"的 Apple Event。
// 要在 app.run() 里 AppKit 装好它自己的处理之后再装，不然被盖掉
DispatchQueue.main.async { AddGuide.shared.handleReopen() }

// 被结束（换装、注销时系统发的 SIGTERM 等）或正常结束时先收尾：结束 log stream、告诉主控正常退出（#9、#12）
var terminationSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        EngineManager.shared.shutdown()
        exit(0)
    }
    source.resume()
    terminationSources.append(source)
}
NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
    EngineManager.shared.shutdown()
}
withExtendedLifetime(server) { app.run() }
