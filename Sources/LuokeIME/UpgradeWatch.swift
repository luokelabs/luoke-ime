import AppKit
import os

/// 换了新版、旧进程还在跑旧代码时自己让位：磁盘上包里的版本号和启动时的不一样了，就等所有输入框都空闲、
/// 最近 3 秒没按键、设置窗口和添加引导都关着时收尾退出，再用 `open -g` 从装好的路径拉起新版（不等系统下一次按键）。
/// 主控换包后自己会结束旧进程再拉起（luoke-core d1d7ef6）；这里兜住别的装法和主控没结束到的情况。
/// 旧进程找资源、起引擎都按包的路径，换包后那里已是新文件，留着旧壳会去起新版的引擎（开发机上 0.1.13 → 0.1.16）。
enum UpgradeWatch {
    private static let log = Logger(subsystem: "ai.luoke.inputmethod", category: "upgrade")
    static var lastKeyAt = Date.distantPast
    private static let launched = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    private static var timer: Timer?
    private static var leaving = false

    static func start() {
        guard launched != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in check() }
    }

    /// 读磁盘上的 Info.plist（Bundle.main.infoDictionary 是启动时缓存的那份）。
    static func versionOnDisk(_ bundle: URL = Bundle.main.bundleURL) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        return (NSDictionary(contentsOf: plist) as? [String: Any])?["CFBundleVersion"] as? String
    }

    private static func check() {
        guard !leaving, let onDisk = versionOnDisk(), onDisk != launched else { return }
        // 新包的可执行文件还在才走：换包换到一半（或被删了）时不退
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/LuokeIME")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        // 设置窗口、添加引导开着时不走：退出会把窗口带走，新版起来不会重开
        guard Date().timeIntervalSince(lastKeyAt) >= 3, EngineManager.shared.allIdle,
              !SettingsWindow.shared.isOpen, !AddGuide.shared.isOpen else { return }
        leaving = true
        log.notice("磁盘上换成了 build \(onDisk, privacy: .public)（在跑的是 \(launched ?? "?", privacy: .public)），空闲时退出让新版起来")
        // 拉起新版的命令在我们退出后才跑：新进程拿单实例锁最多等 3 秒，这里先等 1 秒
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; exec /usr/bin/open -g \"$0\"", Bundle.main.bundleURL.path]
        try? relaunch.run()
        EngineManager.shared.shutdown()
        exit(0)
    }
}
