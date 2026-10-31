import Foundation

/// 按键方案。小鹤双拼、自然码双拼和全拼共用这份代码，只在"一串按键怎么读"上不同
/// （engines/ziranma、engines/quanpin 用 --scheme ziranma / quanpin 运行）。
/// - 双拼（小鹤、自然码）：每个音节固定两个键，引擎自己把按键拆成全拼音节（用 ' 隔开）交给苹果的转换引擎；两种只差键位表。
/// - 全拼：原始字母直接交给苹果。音节怎么切、每个候选用掉几个键，都按苹果给的拼音段和音节长度算——
///   它会消歧（fangan → 方案 / 反感）、认简拼（nh → 你好）、纠错（zhognguo → 中国）。
enum Scheme: String {
    case xiaohe, ziranma, quanpin

    static let current: Scheme = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--scheme"), i + 1 < a.count, let s = Scheme(rawValue: a[i + 1]) { return s }
        return .xiaohe
    }()

    /// 每个音节两个键。
    var isDouble: Bool { self != .quanpin }

    var name: String { ["xiaohe": "小鹤双拼", "ziranma": "自然码双拼", "quanpin": "全拼"][rawValue]! }

    /// 雾凇里的方案：double_pinyin 就是自然码。
    var rimeSchema: String { ["xiaohe": "double_pinyin_flypy", "ziranma": "double_pinyin", "quanpin": "rime_ice"][rawValue]! }

    /// 增量复用：定的时候往后看了至少这么多个键才沿用（约 4 个音节）。
    var margin: Int { isDouble ? 8 : 12 }
}

/// 一串按键怎么读。
struct Reading {
    /// 苹果的汉字候选和 emoji（文字，用掉的键数），按苹果的顺序。
    var candidates: [(text: String, consume: Int)] = []
    /// 每个完整音节在第几个键结束（累计）。
    var ends: [Int] = []
    /// 光标处显示的样子。
    var display: String
    /// 整串都读得通（双拼：都拆得成音节；全拼：苹果有用掉整串的汉字候选）。
    var complete = false
    /// 值得让模型重排：读得通、至少两个音节。
    var refinable = false

    /// 前 n 个字用掉几个键（RIME 的词只给文字，按音节对上）；不够 n 个完整音节时为 nil。
    func consume(chars n: Int) -> Int? { n >= 1 && n <= ends.count ? ends[n - 1] : nil }
}

/// 同一串键怎么读不会变（不向苹果的引擎反馈学习），算过的一直留着。
var readingCache: [String: Reading] = [:]
func reading(_ input: String) -> Reading {
    if let r = readingCache[input] { return r }
    if readingCache.count > 5000 { readingCache = [:] }
    let r = Scheme.current.isDouble ? doubleReading(input) : quanpinReading(input)
    readingCache[input] = r
    return r
}

/// 双拼：用掉的键数按候选对应的音节数算（每个音节两个键，末尾半个音节时以可解读的键数为限）；苹果没说时按每个字两个键。
/// 字数跟音节数对不上的汉字候选丢掉：那是苹果把一个音节拆成了两个全拼音节（huai → 互爱、xiao → 西澳、
/// ta'm → 天安门），双拼里这些字不是这么打的。
func doubleReading(_ input: String) -> Reading {
    let keys = Array(input)
    let p = parse(keys)
    var r = Reading(display: input) // 光标处原样显示敲的键：每两个键一个音节，没有歧义；打英文时也不会变成怪的全拼
    r.complete = p.validKeys == keys.count
    r.refinable = r.complete && keys.count >= 4
    r.ends = p.syllables.indices.map { 2 * ($0 + 1) }
    guard p.validKeys > 0 else { return r }
    var seen = Set<String>()
    for c in mecabra.lookup(p.pinyin, limit: 40) where c.emoji || (isHan(c.text) && (c.syllables ?? c.text.count) == c.text.count) {
        guard seen.insert(c.text).inserted else { continue }
        r.candidates.append((c.text, min(2 * (c.syllables ?? c.text.count), p.validKeys)))
    }
    return r
}

/// 全拼：苹果给的拼音段就是原始字母的开头一段，它的长度就是用掉的键数；对不上的（苹果纠错时可能这样）丢掉。
/// 音节的切分取苹果第一个用掉整串的汉字候选。
func quanpinReading(_ input: String) -> Reading {
    var r = Reading(display: input)
    var seen = Set<String>()
    for c in mecabra.lookup(input, limit: 40, lengths: true) where c.emoji || isHan(c.text) {
        guard let a = c.analysis, !a.isEmpty, input.hasPrefix(a), seen.insert(c.text).inserted else { continue }
        r.candidates.append((c.text, a.count))
        if r.ends.isEmpty, !c.emoji, a.count == input.count, let lens = c.syllableLengths, lens.reduce(0, +) == a.count {
            var e = 0
            r.ends = lens.map { e += $0; return e }
        }
    }
    r.complete = r.candidates.contains { isHan($0.text) && $0.consume == input.count }
    r.refinable = r.complete && r.ends.count >= 2
    if !r.ends.isEmpty {
        let chars = Array(input)
        var start = 0
        r.display = r.ends.map { e in defer { start = e }; return String(chars[start..<e]) }.joined(separator: " ")
    }
    return r
}
