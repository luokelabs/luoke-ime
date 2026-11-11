import Foundation

/// 本机的使用计数（docs/设计.md#使用计数）：只记次数，不记打了什么、在哪个应用，按天合计，留 90 天，不上传。
/// 设置窗口「高级」里给用户看，评测时读它看联想、改选在真用时的情况。密码框里、暂停所有记录、禁止记录的应用里
/// 不记（Session 判断）。
public final class Usage {
    public enum Event: String, CaseIterable {
        /// 打字引擎的一次上屏
        case commit
        /// 上屏的一段里选的是首选 / 别的候选（按选过的每一段算，原样上屏的字母不算）
        case pickFirst = "pick_first"
        case pickOther = "pick_other"
        /// 上屏后紧接着按了退格（每次上屏最多算一次）
        case backspaceAfterCommit = "backspace_after_commit"
        /// 联想：提示亮出来了、按 Tab 打开了、选了一个、选的一共多少个字
        case predictShown = "predict_shown"
        case predictOpened = "predict_opened"
        case predictPicked = "predict_picked"
        case predictChars = "predict_chars"
    }

    public static let keepDays = 90
    /// 攒着的计数最多隔这么久写一次盘；退出时 flush。
    public static let saveInterval: TimeInterval = 60

    private let url: URL?
    private let now: () -> Date
    private var days: [String: [String: Int]] = [:]
    private var dirty = false
    private var savedAt = Date.distantPast

    /// `url` 为 nil 时只在内存里记（测试、命令行版）。
    public init(url: URL?, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
        if let url, let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let d = obj["days"] as? [String: [String: Int]] {
            days = d
        }
    }

    public func add(_ e: Event, _ n: Int = 1) {
        guard n > 0 else { return }
        days[Self.day(now()), default: [:]][e.rawValue, default: 0] += n
        dirty = true
        if now().timeIntervalSince(savedAt) >= Self.saveInterval { flush() }
    }

    /// 最近 `lastDays` 天（含今天）的合计。
    public func total(lastDays: Int) -> [Event: Int] {
        let keys = Set((0..<lastDays).map { Self.day(now().addingTimeInterval(-Double($0) * 86_400)) })
        var out: [Event: Int] = [:]
        for (d, counts) in days where keys.contains(d) {
            for (k, v) in counts { if let e = Event(rawValue: k) { out[e, default: 0] += v } }
        }
        return out
    }

    public func reset() {
        days = [:]
        dirty = true
        flush()
    }

    public func flush() {
        guard dirty, let url else { return }
        let oldest = Self.day(now().addingTimeInterval(-Double(Self.keepDays) * 86_400))
        days = days.filter { $0.key > oldest }
        let obj: [String: Any] = ["version": 1, "days": days]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        dirty = false
        savedAt = now()
    }

    static func day(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
