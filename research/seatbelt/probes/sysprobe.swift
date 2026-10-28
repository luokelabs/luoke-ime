// sysprobe: 只读 / 不弹窗的系统服务探测（LaunchServices 查询、剪贴板 changeCount、屏幕录制预检）。
// 绝不调用任何会打开 URL/应用、发 AppleEvent、请求屏幕录制权限、触碰麦克风/摄像头的 API。
import Foundation
import AppKit
import CoreServices
import CoreGraphics

func emit(_ probe: String, _ ok: Bool, _ detail: String) {
    let d: [String: Any] = ["probe": probe, "ok": ok, "detail": detail]
    let data = try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : ""
switch cmd {
case "ls-default-app":
    // LaunchServices 只读查询：https 的默认处理程序是谁（不会打开任何东西）
    let url = URL(string: "https://example.com")! as CFURL
    var err: Unmanaged<CFError>? = nil
    if let u = LSCopyDefaultApplicationURLForURL(url, .all, &err)?.takeRetainedValue() {
        emit("ls-default-app", true, (u as URL).path)
    } else {
        emit("ls-default-app", false, err.map { "\($0.takeRetainedValue())" } ?? "nil")
    }
case "ws-url-for":
    if let u = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) {
        emit("ws-url-for", true, u.path)
    } else { emit("ws-url-for", false, "nil") }
case "pasteboard-count":
    // 仅读 changeCount（不读内容，也就不触发新系统的"粘贴"提示）
    let c = NSPasteboard.general.changeCount
    emit("pasteboard-count", true, "changeCount=\(c)")
case "screen-preflight":
    // CGPreflightScreenCaptureAccess 不弹窗；这里只看沙盒内外返回值是否不同
    emit("screen-preflight", true, "\(CGPreflightScreenCaptureAccess())")
case "window-count":
    // CGWindowListCopyWindowInfo：只数窗口个数（不取标题、不截图）。仅当预检显示已有屏幕录制授权时才调用，保证不会弹窗。
    // force: 由测试脚本在"沙盒外预检已为 true"时才传，用来在沙盒内对照（沙盒内预检本身会因 tccd 被拦而返回 false）
    let force = args.count > 2 && args[2] == "force"
    if !force && !CGPreflightScreenCaptureAccess() { emit("window-count", false, "skipped: no screen-recording grant (would not prompt, but skipped to be safe)"); break }
    if let arr = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
        emit("window-count", arr.count > 0, "windows=\(arr.count)")
    } else { emit("window-count", false, "nil") }
default:
    emit(cmd, false, "unknown subcommand")
}
