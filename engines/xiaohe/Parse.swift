// 把双拼按键（小鹤或自然码）拆成全拼音节。

/// 全拼音节 → 双拼两个键。小鹤和自然码的声母、零声母一样，只有韵母的键位不同。
func doubleKeys(_ syl: String, finals: [String: String]) -> String? {
    for (initial, key) in [("zh", "v"), ("ch", "i"), ("sh", "u")] where syl.hasPrefix(initial) {
        return finals[String(syl.dropFirst(2))].map { key + $0 }
    }
    if let first = syl.first, "bpmfdtnlgkhjqxrzcsyw".contains(first), let f = finals[String(syl.dropFirst())] {
        return String(first) + f
    }
    return xiaoheZero[syl]
}

/// 双拼两个键 → 全拼音节。
func doubleSyllables(finals: [String: String]) -> [String: String] {
    var m: [String: String] = [:]
    for s in pinyinSyllables {
        guard let k = doubleKeys(s, finals: finals) else { fatalError("编码表里缺少音节 \(s)") }
        precondition(m[k] == nil, "\(k) 对应了两个音节：\(m[k]!) 和 \(s)")
        m[k] = s
    }
    return m
}

let xiaoheSyllable = doubleSyllables(finals: xiaoheFinals)
/// 当前方案的那张表（全拼不用）。
let doubleSyllable = Scheme.current == .ziranma ? doubleSyllables(finals: ziranmaFinals) : xiaoheSyllable

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
    while i + 1 < keys.count, let s = doubleSyllable[String(keys[i...i + 1])] {
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
