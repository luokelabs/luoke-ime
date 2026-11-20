import AppKit
import Carbon
import Foundation
import os

/// 在系统的输入源服务里注册、启用、选中螺壳。
enum InputSource {
    static let bundleID = "ai.luoke.inputmethod.Luoke"
    static let modeID = "ai.luoke.inputmethod.Luoke.Hans"

    static func sources() -> [TISInputSource] {
        (TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
    }

    static func identifier(_ source: TISInputSource) -> String? {
        guard let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    static func current() -> String? {
        identifier(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
    }

    /// 注册安装包，不请求启用。
    /// 第三方输入法只能由用户在系统设置里添加（记录在 com.apple.inputsources 的
    /// AppleEnabledThirdPartyInputSources）：启用调用会返回成功，但只是打开系统设置、弹出一个点了也不生效的确认，所以不调。
    /// 系统是异步收录新安装包的，所以最多等 `timeout` 秒。
    /// 已经是"已启用、可选"的（换装）就什么都不做：macOS 26 上对已启用的源再请求启用，有时会拉起系统设置要用户再确认一次，
    /// 没确认之前螺壳可能就从输入法菜单里没了、TIS 却照样说已启用（换装时拉起过系统设置的，之后有两次
    /// 菜单里没了螺壳；没拉起的换装都没出事。还没坐实，但第一次安装以外不需要这一步）。
    static func register(bundle: URL, timeout: TimeInterval = 8) -> Bool {
        EnabledWatch.report("--register 之前")
        defer { EnabledWatch.report("--register 之后") }
        if EnabledWatch.usable() {
            FileHandle.standardError.write(Data("螺壳已经是启用、可选的输入源：不再注册、不再请求启用（换装时请求启用可能要用户再确认一次）。\n".utf8))
            return true
        }
        let status = TISRegisterInputSource(bundle as CFURL)
        if status != noErr { FileHandle.standardError.write(Data("TISRegisterInputSource 返回 \(status)\n".utf8)) }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if sources().contains(where: { identifier($0) == modeID }) {
                // 不请求启用：它会弹出"Allow "Luoke" to enable …?"，可用户点了"允许"也加不上
                //（测试机（macOS 26.5.1）上实测两次，请求的进程留着也一样，luokelabs/luoke-ime#13），
                // 反倒误导用户。只注册，让螺壳出现在系统设置"编辑… → +"的列表里，由用户自己添加
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        FileHandle.standardError.write(Data("系统里还没出现螺壳的输入模式；如果一直这样，注销再登录一次。\n".utf8))
        return false
    }

    /// 给主控的向导和诊断用的一行 JSON（luokelabs/luoke-ime#13）：每次新起进程现读，TIS 的缓存问题碰不到。
    /// state：not_registered（系统里还没有螺壳的输入模式）、not_added（有了，用户还没在系统设置里添加）、
    /// added_not_selectable（添加了，TIS 却说不可选，比如刚添加、系统还没收录完）、ready（能切过去用）。
    /// 已添加以"用户同意过的第三方输入法"那份偏好为准，读不到时才看 TIS（理由见 EnabledWatch.consented）。
    /// ready 也不保证真能切过去（#15）：other_copies 不空时多半切不过去，要真切一次用 `--select`，看它的退出码。
    static func status() -> String {
        let mode = sources().first { identifier($0) == modeID }
        func flag(_ key: CFString) -> Bool {
            guard let s = mode, let p = TISGetInputSourceProperty(s, key) else { return false }
            return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
        }
        let listed = EnabledWatch.listed("AppleEnabledThirdPartyInputSources", in: "com.apple.inputsources")
        let enabled = flag(kTISPropertyInputSourceIsEnabled), selectable = flag(kTISPropertyInputSourceIsSelectCapable)
        let added = listed ?? enabled
        let state = mode == nil ? "not_registered" : !added ? "not_added" : !(enabled && selectable) ? "added_not_selectable" : "ready"
        let obj: [String: Any] = [
            "state": state, "registered": mode != nil, "added": added, "consent_list": listed.map { $0 as Any } ?? NSNull(),
            "tis_enabled": enabled, "tis_selectable": selectable, "current": current() == modeID, "other_copies": otherCopies(),
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func select(_ wanted: String) -> Bool {
        for s in sources() where identifier(s) == wanted { return TISSelectInputSource(s) == noErr }
        return false
    }

    /// `--select`：选中以后再核对一次真的切过去了没有（另起一个进程读当前输入源，本进程里 TIS 有缓存）。
    /// 系统里同一个 bundle id 登记着别的副本时（比如废纸篓里的旧包），选中的调用照样返回成功、却切不过去
    /// （luokelabs/luoke-ime#15，macOS 27.0.1 上实测）。返回 0 切过去了，1 选中的调用就失败了，3 调用成功但没切过去。
    static func selectVerified(timeout: TimeInterval = 2) -> Int32 {
        guard select(modeID) else { return 1 }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if currentInFreshProcess() == modeID { return 0 }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        FileHandle.standardError.write(Data("选中的调用成功了，可系统没切到螺壳。多半是系统里还登记着别的螺壳副本（比如废纸篓里的旧包）：清掉它们，再重新安装一次螺壳。\n".utf8))
        return 3
    }

    private static func currentInFreshProcess() -> String? {
        let p = Process()
        p.executableURL = Bundle.main.executableURL
        p.arguments = ["--current"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 同一个 bundle id 的别的副本：LaunchServices 认到的（装好的这份以外），加上废纸篓里的
    ///（#15：用户把旧包移进废纸篓，LaunchServices 里还登记着它，新装的那份就切不过去；按 bundle id 查时它不一定露面）。
    static func otherCopies() -> [String] {
        let me = Bundle.main.bundleURL.standardizedFileURL.path
        var out = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).map { $0.standardizedFileURL.path }.filter { $0 != me }
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        for url in (try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "app" {
            if Bundle(url: url)?.bundleIdentifier == bundleID, !out.contains(url.path) { out.append(url.path) }
        }
        return out
    }

    static func disable() {
        for s in sources() {
            guard let id = identifier(s), id.hasPrefix(bundleID) else { continue }
            TISDisableInputSource(s)
        }
    }
}

/// 诊断：系统的输入源启用列表一变，就记下螺壳在系统的输入源接口里还算不算"已启用、可选"（以它为准），旁证是两份偏好：
/// com.apple.inputsources 的 AppleEnabledThirdPartyInputSources（用户在系统设置里同意过的第三方输入法）和 com.apple.HIToolbox
/// 的 AppleEnabledInputSources（macOS 26 起第三方输入法本来就不在这份里，不能拿它当"消失"的证据）。
/// 还记下当时在前台的应用（只记 bundle id）。螺壳偶尔会从输入法菜单里没了，原因没查到；有了这几行，下次能对上时间。
/// 没了的时候 TIS 可能说"已启用、可选"、菜单里却没有（菜单是系统的 TextInputMenuAgent 画的，输入法进程里看不到）。
/// 所以再记两样旁证：LaunchServices 按 bundle id 认到的是哪几份包（装好的那份以外还有，比如安装时的临时副本，就记下来），
/// 和"已启用、可选，却很久没被激活"（用户可能只是一直用别的输入法，只能当旁证）。每 10 分钟查一次，变了才记。
enum EnabledWatch {
    private static let log = Logger(subsystem: "ai.luoke.inputmethod", category: "inputsource")
    private static var last: Bool?
    private static var lastBundles: [String]?
    private static var lastActive = Date()
    private static var idleLogged = false
    private static var timer: Timer?
    static let idleLimit: TimeInterval = 3600

    /// 系统的输入源接口里，螺壳的输入模式是不是已启用、可选。
    static func usable() -> Bool {
        let list = (TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
        guard let s = list.first(where: { InputSource.identifier($0) == InputSource.modeID }) else { return false }
        func flag(_ key: CFString) -> Bool {
            guard let p = TISGetInputSourceProperty(s, key) else { return false }
            return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
        }
        return flag(kTISPropertyInputSourceIsEnabled) && flag(kTISPropertyInputSourceIsSelectCapable)
    }

    /// 某份偏好的某个列表里有没有螺壳；读不到时为 nil。
    static func listed(_ key: String, in domain: String) -> Bool? {
        CFPreferencesAppSynchronize(domain as CFString)
        guard let list = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? [[String: Any]] else { return nil }
        return list.contains { $0["Bundle ID"] as? String == InputSource.bundleID }
    }

    static func start() {
        report("启动")
        let center = DistributedNotificationCenter.default()
        for name in [kTISNotifyEnabledKeyboardInputSourcesChanged as String, "AppleEnabledInputSourcesChangedNotification"] {
            center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in report(name) }
        }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in check() }
    }

    /// 输入控制器被激活（用户切到了螺壳、或者在用着它进了一个输入框）。
    static func activated() {
        lastActive = Date()
        if idleLogged {
            idleLogged = false
            log.notice("输入源：螺壳又被激活了")
        }
    }

    /// LaunchServices 按 bundle id 认到的包：路径，装好的那份（这个进程自己的）标上"（本身）"。
    static func bundles() -> [String] {
        let me = Bundle.main.bundleURL.standardizedFileURL.path
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: InputSource.bundleID).map {
            let p = $0.standardizedFileURL.path
            return p == me ? p + "（本身）" : p
        }
    }

    /// 定时：认到的包变了就记；已启用、可选却超过 idleLimit 没被激活，记一次。
    private static func check() {
        let now = bundles()
        if now != lastBundles {
            let fine = now.count == 1 && now[0].hasSuffix("（本身）")
            let text = now.isEmpty ? "一份也没有" : now.joined(separator: "、")
            if fine { log.notice("LaunchServices 认到的螺壳：\(text, privacy: .public)") }
            else { log.error("LaunchServices 认到的螺壳不只是装好的这份，或者它不是第一个：\(text, privacy: .public)") }
            lastBundles = now
        }
        let idle = Date().timeIntervalSince(lastActive)
        if !idleLogged, idle > idleLimit, consented() {
            idleLogged = true
            log.notice("输入源：螺壳已启用、可选，但 \(Int(idle / 60), privacy: .public) 分钟没被激活（可能只是在用别的输入法；要是用户说切不过去，对一下这个时间）")
        }
    }

    /// 用户同意过的第三方输入法里有没有螺壳：每次现读偏好。常驻的进程里 TIS 有缓存，用户在系统设置里移除以后
    /// 还会报已启用（16 GB 测试机（M1）上实测过），所以拿这个当主证据，TIS 只当旁证；读不到时才看 TIS。
    static func consented() -> Bool {
        listed("AppleEnabledThirdPartyInputSources", in: "com.apple.inputsources") ?? usable()
    }

    static func report(_ why: String) {
        let now = consented()
        func mark(_ b: Bool?) -> String { b.map { $0 ? "有" : "没有" } ?? "读不到" }
        let third = mark(listed("AppleEnabledThirdPartyInputSources", in: "com.apple.inputsources"))
        let tis = usable() ? "已启用、可选" : "不可选"
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        let detail = "第三方同意列表\(third)、TIS 说\(tis)；\(why)；前台应用 \(front)；LaunchServices 认到 \(bundles().joined(separator: "、"))"
        if last == true, !now {
            log.error("螺壳不在用户同意过的第三方输入法里了（\(detail, privacy: .public)）")
        } else {
            log.notice("输入源：螺壳\(now ? "在" : "不在", privacy: .public)用户同意过的第三方输入法里（\(detail, privacy: .public)）")
        }
        last = now
    }
}
