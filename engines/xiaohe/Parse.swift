// 把小鹤按键拆成全拼音节。

/// 全拼音节 → 小鹤两个键。
func xiaoheKeys(_ syl: String) -> String? {
    for (initial, key) in [("zh", "v"), ("ch", "i"), ("sh", "u")] where syl.hasPrefix(initial) {
        return xiaoheFinals[String(syl.dropFirst(2))].map { key + $0 }
    }
    if let first = syl.first, "bpmfdtnlgkhjqxrzcsyw".contains(first), let f = xiaoheFinals[String(syl.dropFirst())] {
        return String(first) + f
    }
    return xiaoheZero[syl]
}

/// 小鹤两个键 → 全拼音节。
let xiaoheSyllable: [String: String] = {
    var m: [String: String] = [:]
    for s in pinyinSyllables {
        guard let k = xiaoheKeys(s) else { fatalError("编码表里缺少音节 \(s)") }
        precondition(m[k] == nil, "\(k) 对应了两个音节：\(m[k]!) 和 \(s)")
        m[k] = s
    }
    return m
}()

struct Parsed {
    /// 完整的音节。
    var syllables: [String] = []
    /// 末尾单独一个键时，它代表的声母（或 a e o）。
    var trailing: String?
    /// 能解读的键数；之后的键不成音节。
    var validKeys = 0

    /// 交给转换引擎的拼音，音节之间用 ' 分隔。
    var pinyin: String { (syllables + [trailing].compactMap { $0 }).joined(separator: "'") }
}

func parse(_ keys: [Character]) -> Parsed {
    var p = Parsed()
    var i = 0
    while i + 1 < keys.count, let s = xiaoheSyllable[String(keys[i...i + 1])] {
        p.syllables.append(s)
        i += 2
    }
    if i == keys.count - 1 {
        let k = keys[i]
        let initial: String? = ["v": "zh", "i": "ch", "u": "sh"][k]
            ?? ("bpmfdtnlgkhjqxrzcsywaeo".contains(k) ? String(k) : nil)
        if let initial {
            p.trailing = initial
            i += 1
        }
    }
    p.validKeys = i
    return p
}
