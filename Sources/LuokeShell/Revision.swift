import Foundation

/// 改后对比：上屏的字后来被用户在输入框里自己改了（鼠标选中改中间的词、退格重打），壳在下一次开始输入时、切走前
/// 读回那一段附近的字，和上屏时比；不一样就作为一次反馈 `revised` 转给打字引擎和个人化组件（引擎协议「revised」）。
/// 只读刚上屏那一段和它前后几个字，不读整篇；安全输入、暂停记录、禁止记录的应用里不读；读不到、对不上就什么都不做。
/// 同一个客户端里可能换了输入框（网页里点到另一个框，系统不切走），所以：上屏时前后都没有字的一段不盯（读回时认不出
/// 是不是同一个框）；读回前光标离那一段太远的，当作换了地方，不读、不再盯。
struct Revision {
    /// 上屏时记下前后各这么多个字（UTF-16），读回时靠它们找到那一段：前面的字被改过，位置会挪。
    static let anchor = 8
    /// 读回时在原位置前后多读这么多，容纳前面的字增删造成的挪动。
    static let slack = 16

    /// 上屏的那一段。
    struct Watch {
        var text: String
        /// 在文档里从哪儿开始（UTF-16）。
        var start: Int
        /// 上屏时它前面、后面紧挨着的字（各最多 anchor 个）。
        var before: String
        var after: String
        /// 告诉打字引擎时的上屏序号（没告诉时 nil）、个人化组件那边的序号。
        var told: Int?
        var recorded: Int?
        var at: TimeInterval
        /// 读回过几次、都没变。
        var checks = 0

        var length: Int { (text as NSString).length }
        var end: Int { start + length }

        /// 光标在这一段附近（容得下前面的字增删造成的挪动）：改它、在它后面接着打的都是这样。
        func isNear(caret: Int) -> Bool {
            caret >= start - Revision.slack && caret <= end + Revision.slack
        }

        /// 读回时要读的范围。
        var window: (start: Int, length: Int) {
            let s = max(0, start - Revision.anchor - Revision.slack)
            return (s, end + Revision.anchor + Revision.slack - s)
        }
    }

    /// 从读回的一段字（文档里从 `windowStart` 起的 `window`）里找出那一段现在的样子；找不到时为 nil。
    /// 前面的字靠 `before` 定位（离原位置最近的一处），后面靠 `after`；上屏时后面没有字（打在末尾）的，按原来的长度取。
    static func current(of w: Watch, window: String, windowStart: Int) -> String? {
        let ns = window as NSString
        let expected = w.start - windowStart
        var s = expected
        if !w.before.isEmpty {
            guard let r = nearest(w.before, in: ns, to: expected, end: true) else { return nil }
            s = r.location + r.length
        } else if expected != 0 {
            return nil
        }
        var e: Int
        if !w.after.isEmpty {
            guard let r = nearest(w.after, in: ns, to: s + w.length, end: false, from: s) else { return nil }
            e = r.location
        } else {
            e = s + w.length
        }
        guard s >= 0, e >= s, e <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: s, length: e - s))
    }

    /// `needle` 在 `ns` 里离 `target` 最近（end：按出现处的末尾算，否则按开头）、相差不超过 slack 的一处。
    private static func nearest(_ needle: String, in ns: NSString, to target: Int, end: Bool, from: Int = 0) -> NSRange? {
        var best: NSRange?
        var search = NSRange(location: from, length: ns.length - from)
        while search.length > 0 {
            let r = ns.range(of: needle, options: .literal, range: search)
            if r.location == NSNotFound { break }
            let at = end ? r.location + r.length : r.location
            if abs(at - target) <= slack, best == nil || abs(at - target) < abs((end ? best!.location + best!.length : best!.location) - target) {
                best = r
            }
            search = NSRange(location: r.location + 1, length: ns.length - r.location - 1)
        }
        return best
    }

    /// 读回的字算不算一次改动：不一样、不是空的、没有换行，长短相差不多（差太多多半是定位错了，不当真）。
    static func isRevision(_ old: String, _ new: String) -> Bool {
        new != old && !new.isEmpty && !new.contains("\n") && abs(new.count - old.count) <= 8
    }
}
