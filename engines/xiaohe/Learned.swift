import Foundation

/// 长句里学过的词：用户在某串键上改选过的词（Memory.chosen），这串键又出现在更长的一句里、和音节对得上时，
/// 这一段直接定成学过的词，模型和快的那份整句只排剩下的部分。整串键完全相同的不在这里（fastAnswer 本来就放首位）。
///
/// 防误伤：
/// - 至少 learnedMinSyllables 个音节的才用（博客 600 条、用一位用户真实学过的词：2 个音节时 89.5% → 85.3%，改错 50 多条；3 个时 → 90.2%、没有改错；4 个时 → 89.7%）：两个字的词（nali → 那里 / 哪里、jxge → 加个 / 价格）在别的句子里常常是另一个意思，
///   交给模型按前文挑；
/// - 同一串键学过不止一个词（那里、哪里都选过）的不用：用户自己也是看前文选的；
/// - 忘掉的词不用；
/// - 位置重叠时先取改选次数多的，再取长的，再取靠前的。
struct LearnedSpan: Equatable {
    var start: Int    // 在整串键里从第几个键开始
    var consume: Int  // 用掉几个键
    var word: String
}

/// 评测对照用的选项 learned_min（0 = 不用学过的词）。
var learnedMinSyllables = 3

/// ends：整串键每个完整音节在第几个键结束（Reading.ends）。
func learnedSpans(_ input: String, ends: [Int], memory: Memory, minSyllables: Int = learnedMinSyllables) -> [LearnedSpan] {
    guard minSyllables > 0, ends.count > minSyllables else { return [] }
    let keys = Array(input)
    var syllableAt: [Int: Int] = [0: 0] // 第几个键是第几个音节的开头
    for (i, e) in ends.enumerated() { syllableAt[e] = i + 1 }
    var found: [(span: LearnedSpan, count: Int)] = []
    for (k, words) in memory.chosen where k.count < keys.count {
        let usable = words.filter { isHan($0.key) && $0.key.count >= minSyllables && !memory.isForgotten(k, $0.key) }
        guard words.count == 1, let (word, count) = usable.first else { continue }
        let pattern = Array(k)
        var s = 0
        while s + pattern.count <= keys.count {
            defer { s += 1 }
            guard keys[s] == pattern[0], let i = syllableAt[s], i + word.count <= ends.count,
                  ends[i + word.count - 1] == s + pattern.count, Array(keys[s..<s + pattern.count]) == pattern else { continue }
            found.append((LearnedSpan(start: s, consume: pattern.count, word: word), count))
        }
    }
    found.sort { a, b in
        if a.count != b.count { return a.count > b.count }
        if a.span.consume != b.span.consume { return a.span.consume > b.span.consume }
        return a.span.start < b.span.start
    }
    var picked: [LearnedSpan] = []
    for (s, _) in found where !picked.contains(where: { $0.start < s.start + s.consume && s.start < $0.start + $0.consume }) {
        picked.append(s)
    }
    return picked.sorted { $0.start < $1.start }
}

/// 快的那份整句：学过的词照用，别的部分接苹果对那一段的整句；有一段苹果拼不出来就不给（nil）。
func learnedSentence(_ input: String, spans: [LearnedSpan], appleFull: (String) -> String?) -> String? {
    guard !spans.isEmpty else { return nil }
    let keys = Array(input)
    var out = "", pos = 0
    for s in spans + [LearnedSpan(start: keys.count, consume: 0, word: "")] {
        if s.start > pos {
            guard let t = appleFull(String(keys[pos..<s.start])) else { return nil }
            out += t
        }
        out += s.word
        pos = s.start + s.consume
    }
    return out
}

/// 改后对比（引擎协议「revised」）：上屏的一段（pieces，上屏时的字 before）后来被用户改成了 after。
/// 改动处往前后补到至少 minChars 个字（只补按键对得上的字），每个字都在它那个音节的按键的候选里（readable），
/// 就学成这串键的改选：返回（按键，词）。字数变了、改成了别的音、补不够字的，不学（nil）。
func revisionLesson(pieces: [[String: Any]], before: String, after: String, minChars: Int = learnedMinSyllables,
                    ends: (String) -> [Int], readable: (String, Character) -> Bool) -> (keys: String, word: String)? {
    var charKeys: [String?] = []
    var text = ""
    for p in pieces {
        guard let t = p["text"] as? String, let input = p["input"] as? String else { return nil }
        text += t
        let e = ends(input)
        if p["index"] is Int, p["char"] == nil, isHan(t), e.count == t.count, e.last == input.count {
            let keys = Array(input)
            var from = 0
            for end in e {
                charKeys.append(String(keys[from..<end]))
                from = end
            }
        } else {
            charKeys += Array(repeating: nil, count: t.count)
        }
    }
    let old = Array(before), new = Array(after), n = old.count
    guard text == before, new.count == n, old != new, minChars > 0 else { return nil }
    var lo = 0
    while old[lo] == new[lo] { lo += 1 }
    var hi = n
    while hi > lo, old[hi - 1] == new[hi - 1] { hi -= 1 }
    while hi - lo < minChars {
        if lo > 0, charKeys[lo - 1] != nil { lo -= 1 } else if hi < n, charKeys[hi] != nil { hi += 1 } else { break }
    }
    guard hi - lo >= minChars, hi - lo <= 12 else { return nil }
    var keys = ""
    for i in lo..<hi {
        guard let k = charKeys[i], readable(k, new[i]) else { return nil }
        keys += k
    }
    let word = String(new[lo..<hi])
    guard isHan(word) else { return nil }
    return (keys, word)
}
