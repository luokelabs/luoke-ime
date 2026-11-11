import AppKit
import LuokeShell

/// `luoke-ime mcp`：螺壳本体按请求起它，读一条请求（读到结尾或一行），答一行就退出（luoke-agent 工具协议 §2a）。
/// 页面和改设置都在 LuokeShell 的 SettingsService 里；这里只管读写标准输入输出、找自带的引擎和应用的名字。
func runMCP() -> Int32 {
    let max = 1 << 20 // 协议 §2a：一条消息最多 1 MB
    var data = Data()
    while data.count <= max, !data.contains(UInt8(ascii: "\n")) {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty { break }
        data.append(chunk)
    }
    guard !data.isEmpty, data.count <= max + 1 else { return 3 }
    let line = String(decoding: data.prefix { $0 != UInt8(ascii: "\n") }, as: UTF8.self)
    // 自带的引擎在 螺壳输入法.app/Contents/Resources/engines；这个程序在同一个包的 Contents/MacOS 里
    let bundled = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.resourceURL?.appendingPathComponent("engines") : nil
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    let service = SettingsService(paths: Paths(), bundledEngines: bundled, version: version, appName: appName)
    if let reply = service.handle(line: line) {
        FileHandle.standardOutput.write(Data((reply + "\n").utf8))
    }
    return 0
}

private func appName(_ id: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
}
