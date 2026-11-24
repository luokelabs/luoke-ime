// 热词纠正：转写出来的字和记忆里的常用说法（热词）读音一样、写法不一样时，换成热词。
// 热词已经放在转写模型的上下文里了，模型多数时候会照着写；这里只管它没照着写的（同音字的人名、大小写和空格不对的英文专名）。
// 宁可漏改，不能错改：
// - 英文热词（带字母的）：去掉大小写、空格和连字符以后一样才换（「git hub」「Chat GPT」→ GitHub、ChatGPT），至少 3 个字母或数字，
//   前后不能紧挨着别的字母或数字（不改单词的一部分）。
// - 中文热词（全是汉字，2–8 个字）：逐字的拼音连声调都一样才换（「章伟」→「张伟」；「实验」「试验」声调不同不换，
//   「往小明家」不会变成「王小明家」）。拼音用系统的转换（ICU），多音字取它的默认读法，两边一样算。
// - 本身也是热词的那几个字不动。
import Foundation

/// 一个汉字带声调的拼音（「ké」），系统转换出来的；不是汉字、转不出拼音时为 nil。
private var pinyinCache: [Character: String?] = [:]
private func pinyin(_ c: Character) -> String? {
    if let hit = pinyinCache[c] { return hit }
    var v: String?
    if isHan(c), let t = String(c).applyingTransform(.mandarinToLatin, reverse: false)?.lowercased(),
       let plain = t.applyingTransform(.stripDiacritics, reverse: false), !plain.isEmpty, plain.allSatisfy({ $0.isASCII && $0.isLetter }) {
        v = t
    }
    pinyinCache[c] = v
    return v
}

func isHan(_ c: Character) -> Bool {
    c.unicodeScalars.count == 1 && (0x4E00...0x9FFF).contains(Int(c.unicodeScalars.first!.value))
}

private func latinKey(_ s: Substring) -> String { String(s.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }).lowercased() }

/// 把 text 里和热词读音一样、写法不一样的地方换成热词。
func correctHotwords(_ text: String, _ words: [String]) -> String {
    guard !words.isEmpty, !text.isEmpty else { return text }
    let set = Set(words)
    var out = fixLatin(text, words.filter { $0.contains(where: { $0.isASCII && $0.isLetter }) }, set)
    out = fixHan(out, words.filter { (2...8).contains($0.count) && $0.allSatisfy(isHan) }, set)
    return out
}

/// 英文热词：连着的 1–3 个英文词（中间只隔空格或连字符），去掉大小写和间隔以后和热词一样就换。
private func fixLatin(_ text: String, _ words: [String], _ all: Set<String>) -> String {
    var keys: [String: String] = [:]
    for w in words.sorted(by: { $0.count > $1.count }) {
        let k = latinKey(Substring(w))
        if k.count >= 3, keys[k] == nil { keys[k] = w }
    }
    guard !keys.isEmpty else { return text }
    let chars = Array(text)
    func latin(_ i: Int) -> Bool { i >= 0 && i < chars.count && chars[i].isASCII && (chars[i].isLetter || chars[i].isNumber) }
    // 各个英文词的起止（下标）
    var tokens: [(Int, Int)] = []
    var i = 0
    while i < chars.count {
        if latin(i) {
            var j = i
            while latin(j) { j += 1 }
            tokens.append((i, j))
            i = j
        } else { i += 1 }
    }
    var out = "", last = 0, t = 0
    while t < tokens.count {
        var matched = false
        for n in stride(from: min(3, tokens.count - t), through: 1, by: -1) {
            let s = tokens[t].0, e = tokens[t + n - 1].1
            // 词和词之间只能是空格或连字符
            if n > 1, !(t..<(t + n - 1)).allSatisfy({ k in chars[tokens[k].1..<tokens[k + 1].0].allSatisfy { $0 == " " || $0 == "-" } }) { continue }
            let span = String(chars[s..<e])
            guard let w = keys[latinKey(Substring(span))], w != span, !all.contains(span) else { continue }
            out += String(chars[last..<s]) + w
            last = e
            t += n
            matched = true
            break
        }
        if !matched { t += 1 }
    }
    return out + String(chars[last...])
}

/// 中文热词：逐字拼音一样就换，长的热词先换；换过的字不再参与别的热词。
private func fixHan(_ text: String, _ words: [String], _ all: Set<String>) -> String {
    var chars = Array(text)
    var locked = [Bool](repeating: false, count: chars.count)
    for w in words.sorted(by: { $0.count > $1.count }) {
        let wc = Array(w)
        let wp = wc.map(pinyin)
        guard wp.allSatisfy({ $0 != nil }) else { continue }
        let n = wc.count
        guard chars.count >= n else { continue }
        var i = 0
        while i + n <= chars.count {
            let win = chars[i..<(i + n)]
            if !locked[i..<(i + n)].contains(true), win.allSatisfy(isHan), Array(win) != wc, !all.contains(String(win)) {
                let same = zip(win, wp).allSatisfy { c, p in pinyin(c).map { $0 == p } ?? false }
                if same {
                    chars.replaceSubrange(i..<(i + n), with: wc)
                    for k in i..<(i + n) { locked[k] = true }
                    i += n
                    continue
                }
            }
            i += 1
        }
    }
    return String(chars)
}
