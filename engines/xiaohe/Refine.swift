import Foundation

/// 模型逐词选：每一步列出首词候选（苹果 + RIME），各自接上剩余按键的最好补全，交给模型给整句打分；
/// 选出首词后对剩下的按键重复。门槛：模型要比苹果的整句首选高出 gate（自然对数）才改。
/// 离线评测（博客 600 条，Qwen3.5-0.8B-Base，门槛 3）：90.0%，苹果 78.8%。
///
/// 模型的用时跟候选数 × 长度成正比（M4 上尤其明显），所以：苹果看前 12 个汉字候选，但单字最多留 4 个（单字后面接的补全都一样，
/// 只取前 8 个又会漏掉「婚礼」这种排在单字后面的词，「他在婚礼上许下了」就选错）；RIME 取前 8 个汉字候选（emoji 不算）；
/// 每个整句截到最长的首词之后 4 个字，更远的部分下一步还会再看。苹果或 RIME 的整句本身被当成首词时（没有更短的首词拼出同一句），
/// 最长的首词就是整句，这一步就不截。
/// 每一步给模型多少个首词候选、一次重排最多算几步。模型的用时跟候选数 × 长度成正比：慢的机器（主控标了 slow，比如 M1）上用小的那档。
/// 慢的机器上每步固定的开销占大头，最后一个键之后接连的步数才是慢的根源，所以那档还限步数：到了最后一步，
/// 整句（首词接上苹果或 RIME 对剩下按键的补全）一起定，不再逐词往下选。
struct Budget: Equatable {
    var apple: Int    // 苹果的前几个汉字候选
    var singles: Int  // 其中单字最多几个
    var rime: Int     // RIME 的前几个汉字候选
    var rounds = Int.max  // 一次重排最多几步（沿用的词不算）

    static let full = Budget(apple: 12, singles: 4, rime: 8)
    static let small = Budget(apple: 6, singles: 2, rime: 4, rounds: 2)
}

struct Refiner {
    /// 某串按键的苹果候选（文字，用掉的键数）。
    let apple: (String) -> [(text: String, consume: Int)]
    /// 某串按键的前 n 个字用掉几个键（RIME 的词只给文字）；不够 n 个音节时为 nil。
    let wordConsume: (String, Int) -> Int?
    let rime: Rime?
    let scorer: Scorer
    let gate: Double
    var budget = Budget.full
    /// 已经有更新的询问了：放弃。
    let cancelled: () -> Bool
    /// 记下各部分用时（LUOKE_XIAOHE_PROFILE=1 时）。
    var profile: Profile?
    /// 整串键里学过的词（Learned.swift）：轮到这一段时直接定下，不问模型，不算步数；它前面的部分只在那一段里选。
    var learned: [LearnedSpan] = []

    /// 定下的一个词。lookahead：定它的时候后面还有几个键。
    struct Step {
        var word: String
        var consume: Int
        var lookahead: Int
    }

    func appleFull(_ keys: String) -> String? {
        apple(keys).first { $0.consume == keys.count && isHan($0.text) }?.text
    }

    /// 一步的整句候选：首词（苹果 + RIME）各自接上剩余按键的最好补全。first：每个整句的首词和它用掉的键数。
    func hypotheses(_ rest: String, profile: Profile? = nil) -> (hyps: [String], first: [String: (word: String, consume: Int)]) {
        var hyps: [String] = []
        var first: [String: (word: String, consume: Int)] = [:]
        func add(_ h: String, _ w: String, _ c: Int) {
            if let old = first[h] {
                if w.count < old.word.count { first[h] = (w, c) } // 同一整句取最短的首词，后面的词下一步还能再选
            } else {
                hyps.append(h)
                first[h] = (w, c)
            }
        }
        var t0 = now()
        var singles = 0
        for (t, c) in apple(rest).lazy.filter({ isHan($0.text) }).prefix(budget.apple) {
            if t.count == 1 {
                singles += 1
                if singles > budget.singles { continue }
            }
            if c == rest.count {
                add(t, t, c)
            } else if c < rest.count, let tail = appleFull(String(rest.dropFirst(c))) {
                add(t + tail, t, c)
            }
        }
        profile?.apple += now() - t0; t0 = now()
        if let rime {
            // RIME 的词接上 RIME 对剩下按键的首选（跟在 RIME 里选了这个词再一路选首选得到的整句一样，但剩下的部分能复用）
            for w in rime.menu(rest).lazy.filter(isHan).prefix(budget.rime) {
                guard let c = wordConsume(rest, w.count) else { continue }
                let tail = String(rest.dropFirst(c))
                if tail.isEmpty {
                    add(w, w, c)
                } else if let t = rime.menu(tail).first, isHan(t) {
                    add(w + t, w, c)
                }
            }
        }
        profile?.rime += now() - t0
        return (hyps, first)
    }

    /// 整句；被取消或模型出错时返回 nil。从 start（之前定下的词）接着选，每定下一个词调一次 decided。
    /// 有学过的词时按它们切成几段：学过的词直接定下，别的段各自逐词选（模型看得到前面定下的全部文字）。
    /// 限了步数的那一步整段一起定，之后的词不再报给 decided（定下的词要首尾相接）。
    func sentence(_ keys: String, context: String, start: [Step] = [], decided: (Step) -> Void = { _ in }) -> String? {
        var done = start.map(\.word).joined()
        var rest = String(keys.dropFirst(start.reduce(0) { $0 + $1.consume }))
        var round = 0
        var reporting = true
        func report(_ s: Step) { if reporting { decided(s) } }
        while !rest.isEmpty {
            if cancelled() { return nil }
            let pos = keys.count - rest.count
            if let l = learned.first(where: { $0.start == pos }) {
                report(Step(word: l.word, consume: l.consume, lookahead: rest.count - l.consume))
                done += l.word
                rest = String(rest.dropFirst(l.consume))
                continue
            }
            // 这一段到下一个学过的词为止
            let segEnd = learned.first { $0.start > pos }?.start ?? keys.count
            let seg = String(rest.prefix(segEnd - pos))
            round += 1
            let last = round >= budget.rounds // 最后一步：整段一起定
            let (hyps, first) = hypotheses(seg, profile: profile)
            guard !hyps.isEmpty else { return nil }
            let d = appleFull(seg)
            // 截到最长的首词之后 4 个字（最后一步不截）；截短后相同的整句只打一次分
            let longest = hyps.map { first[$0]!.word.count }.max()!
            let shown = last ? hyps : hyps.map { String($0.prefix(longest + 4)) }
            var unique: [String] = [], index: [String: Int] = [:]
            for h in shown where index[h] == nil {
                index[h] = unique.count
                unique.append(h)
            }
            let t0 = now()
            let scores = scorer.score(context + done, unique) {
                // 模型在 GPU 上算的时候，先把最可能的下一步（选苹果整句的首词）的候选备好，查过的会留在缓存里
                let t1 = now()
                if let d, let w = first[d], w.consume < seg.count { _ = hypotheses(String(seg.dropFirst(w.consume))) }
                profile?.ahead += now() - t1
            }
            guard let scores else { return nil }
            profile?.model += now() - t0
            profile?.hyps.append(unique.count)
            let lp = shown.map { scores[index[$0]!] }
            var best = lp.indices.max { lp[$0] < lp[$1] }!
            if let d, let di = hyps.firstIndex(of: d), lp[best] - lp[di] < gate { best = di }
            let pick = first[hyps[best]]!
            report(Step(word: pick.word, consume: pick.consume, lookahead: rest.count - pick.consume))
            if last { // 首词之后的补全没逐词选过，不记成定下的词
                reporting = false
                done += hyps[best]
                rest = String(rest.dropFirst(seg.count))
                continue
            }
            done += pick.word
            rest = String(rest.dropFirst(pick.consume))
        }
        return done
    }
}

/// 上一次重排定下的词。用户接着往后打时，前面那些定的时候已经往后看了足够多键的词不必重选，
/// 留到最后一个键之后要算的就只剩末尾几个词。
struct Decided {
    var context = ""
    var keys = ""
    var steps: [Refiner.Step] = []

    /// 定的时候往后看了至少这么多个键（约 4 个音节；小鹤 8 个、全拼 12 个）才沿用。往后看得少就容易定错：
    /// 小鹤的逐键评测（博客 600 条）里只看 4 个键时比每次从头选低 1.2 个百分点，8 个键时不比它低。
    static let margin = Scheme.current.margin

    /// lookahead 截到 keys 里实际还在这个词后面的键数：沿用到更短的按键（退格以后）时，删掉的键不算看过。
    init(context: String = "", keys: String = "", steps: [Refiner.Step] = []) {
        self.context = context
        self.keys = keys
        var end = 0
        self.steps = steps.map { s in
            end += s.consume
            var s = s
            s.lookahead = min(s.lookahead, keys.count - end)
            return s
        }
    }

    /// 对这次询问还能沿用的词：这个词和它后面至少 margin 个键都没变（退格重打、Esc 后另打时，
    /// 定这个词时看过的键可能已经换了）。按键完全相同时全部沿用。
    func reusable(_ keys: String, context: String) -> [Refiner.Step] {
        guard context == self.context else { return [] }
        let same = keys == self.keys
        let common = zip(keys, self.keys).prefix { $0 == $1 }.count
        var out: [Refiner.Step] = [], end = 0
        for s in steps {
            end += s.consume
            guard end <= keys.count, same || (common >= end + Decided.margin && s.lookahead >= Decided.margin) else { break }
            out.append(s)
        }
        return out
    }
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

final class Profile {
    var apple = 0.0, rime = 0.0, model = 0.0, ahead = 0.0
    var hyps: [Int] = []
    var reused = 0
    var line: String {
        String(format: "沿用 %d 个词，苹果 %.0f ms，RIME %.0f ms，模型 %.0f ms（其间预备下一步 %.0f ms），每步候选 %@", reused, apple, rime, model, ahead,
               hyps.map(String.init).joined(separator: "/"))
    }
}
