import Foundation

/// 打错纠正（双拼）：整串读不通时，在第一个读不通的那对键和它前面几个键里改一处——按成相邻的键、多按一个相邻的键、
/// 漏了一个、相邻两个打反——留下改完整串读得通的，各取整串的首选，交模型按前文挑最通顺的（answerQuery）。
/// 打对的按键在双拼里总读得通（末尾单独一个声母也算），所以打对的字不会被改；代价是打错后仍读得通的
/// （比如漏一个键、末尾正好剩个声母）抓不到。
/// 离线评测（博客 600 句、每句照真人的比例打错一处，engines/xiaohe/typo_probe.py --only-unreadable --window 4）：
/// 258 句读不通，纠回 129 句（占全部的 21.5%，原来 3.7%）；只改附近 4 个键平均试 26 种改法，不限位置时 75 种、只多纠回 1%。
enum Typo {
    /// 第一个读不通的键往前再看几个键。
    static let window = 4

    static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map(Array.init)

    /// 键盘上挨着的字母：同一排左右、上下两排斜着挨着的（和 variants.py 一样）。
    static func neighbors(_ ch: Character) -> [Character] {
        guard let r = rows.firstIndex(where: { $0.contains(ch) }), let c = rows[r].firstIndex(of: ch) else { return [] }
        var out: [Character] = []
        for (dr, dcs) in [(0, [-1, 1]), (-1, [0, 1]), (1, [-1, 0])] {
            for dc in dcs {
                let rr = r + dr, cc = c + dc
                if rr >= 0, rr < rows.count, cc >= 0, cc < rows[rr].count { out.append(rows[rr][cc]) }
            }
        }
        return out
    }

    /// 第一个读不通的键；整串读得通时为 nil。
    static func firstBad(_ keys: [Character]) -> Int? {
        let v = parse(keys).validKeys
        return v < keys.count ? v : nil
    }

    /// 在 [from, to) 里改一处的各种按法（去掉原样的），只留偶数个键的（双拼每个音节两个键）。
    static func edits(_ keys: [Character], from: Int, to: Int) -> [String] {
        var out: [String] = [], seen: Set<String> = [String(keys)]
        func add(_ k: [Character]) {
            let s = String(k)
            if k.count % 2 == 0, !k.isEmpty, seen.insert(s).inserted { out.append(s) }
        }
        for i in max(0, from)..<min(keys.count, to) {
            for n in neighbors(keys[i]) {
                var sub = keys; sub[i] = n; add(sub)
                var ins = keys; ins.insert(n, at: i + 1); add(ins)
            }
            var del = keys; del.remove(at: i); add(del)
            if i + 1 < keys.count, keys[i] != keys[i + 1] {
                var swap = keys; swap.swapAt(i, i + 1); add(swap)
            }
        }
        return out
    }

    /// 改一处以后读得通的各种按法和它们的整串首选（苹果的，没有时 RIME 的），首选相同的只留一个。最多 limit 个。
    static func candidates(_ input: String, limit: Int) -> [(keys: String, text: String)] {
        let keys = Array(input)
        guard let bad = firstBad(keys) else { return [] }
        var out: [(keys: String, text: String)] = [], seen = Set<String>()
        for k in edits(keys, from: bad - window, to: bad + 2) where reading(k).complete {
            let apple = appleCandidates(k).first { $0.consume == k.count && isHan($0.text) }?.text
            guard let t = apple ?? rime?.menu(k).first(where: { isHan($0) && 2 * $0.count == k.count }),
                  !memory.isForgotten(input, t), seen.insert(t).inserted else { continue }
            out.append((k, t))
            if out.count >= limit { break }
        }
        return out
    }
}
