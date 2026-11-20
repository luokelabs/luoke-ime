// 小鹤双拼引擎：小鹤按键 → 全拼音节 → 苹果自带的转换引擎和 RIME 出候选；本地模型逐词重排后补发（先快后好）；
// 记住用户改选的词。协议见 docs/引擎协议.md。
import Foundation

func isHan(_ s: String) -> Bool {
    !s.isEmpty && s.unicodeScalars.allSatisfy {
        (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
            || (0xF900...0xFAFF).contains($0.value) || (0x20000...0x3134F).contains($0.value) || $0.value == 0x3007
    }
}

func send(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    do { try FileHandle.standardOutput.write(contentsOf: data + Data([0x0A])) } catch { exit(0) } // 壳那头关了：没人听了
}

func log(_ s: String) { try? FileHandle.standardError.write(contentsOf: Data((s + "\n").utf8)) }

// 子进程（RIME、模型）退出后再往它的管道里写，默认会收到 SIGPIPE 把整个引擎带走；忽略它，写失败按出错处理
signal(SIGPIPE, SIG_IGN)

/// 标准输入上收到、还没处理的消息。单独的线程读，主循环据此知道"后面已经有新的询问了"。
final class Inbox {
    private let cond = NSCondition()
    private var messages: [[String: Any]] = []
    private var closed = false

    /// 读线程放进来一行；不是 JSON 对象的行丢掉。转问的答复直接交给打分器（主循环正在等它）。
    func push(_ line: String) {
        guard let m = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return }
        if m["type"] as? String == "reply" { scorer.deliver(m); return }
        cond.lock(); messages.append(m); cond.signal(); cond.unlock()
        if m["type"] as? String == "query" { scorer.nudge() }
    }
    func close() { cond.lock(); closed = true; cond.broadcast(); cond.unlock() }

    func pop() -> [String: Any]? {
        cond.lock(); defer { cond.unlock() }
        while messages.isEmpty && !closed { cond.wait() }
        return messages.isEmpty ? nil : messages.removeFirst()
    }

    /// 最多等这么久，期间没有新消息就返回 true（用户停下来了）。
    func idle(for seconds: TimeInterval) -> Bool {
        cond.lock(); defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(seconds)
        while messages.isEmpty && !closed && cond.wait(until: deadline) {}
        return messages.isEmpty && !closed
    }

    /// 还有没处理的询问吗。
    func hasQuery() -> Bool {
        cond.lock(); defer { cond.unlock() }
        return messages.contains { $0["type"] as? String == "query" }
    }

    /// 最新的那个还没处理的询问。
    func latestQuery() -> (id: Int, input: String)? {
        cond.lock(); defer { cond.unlock() }
        guard let m = messages.last(where: { $0["type"] as? String == "query" }), let id = m["id"] as? Int, let input = m["input"] as? String else { return nil }
        return (id, input)
    }
}

let mecabra: Mecabra
do {
    mecabra = try Mecabra()
    // 启动自检：苹果的接口若已失效，立刻退出并说明原因，壳会停用这个引擎
    let probe = Scheme.current.isDouble ? "ni'hao" : "nihao"
    guard mecabra.candidates(probe, limit: 5).contains("你好") else { throw EngineFailure("苹果的转换引擎自检没通过：\(probe) 没有给出「你好」") }
    if Scheme.current == .quanpin, mecabra.lookup("nihao", limit: 1, lengths: true).first?.syllableLengths == nil {
        throw EngineFailure("苹果的转换引擎不给音节长度了（可能是系统升级改了接口），全拼没法切分")
    }
} catch {
    log("\(error)")
    exit(1)
}

if CommandLine.arguments.contains("--selftest") {
    let sample = ["xiaohe": "woxliifj", "ziranma": "woxdiifj", "quanpin": "woxiangchifan"][Scheme.current.rawValue]!
    let r = reading(sample)
    if Scheme.current == .xiaohe { // 打错纠正：xl 打成了 zl
        let typo = Array("wozliifj")
        guard Typo.firstBad(typo) == 2, Typo.edits(typo, from: 0, to: 4).contains("woxliifj") else { print("自检没过：打错纠正"); exit(1) }
    }
    print("自检通过（\(Scheme.current.name)）：\(sample) → \(r.display) → \(r.candidates.first?.text ?? "无")")
    exit(0)
}

// 评测用：标准输入每行一串小鹤按键，换成当前方案的按键输出（博客语料的按键一列是小鹤的）。
// 拆不成小鹤音节的那段（英文、标点、末尾半个音节）原样留着。
if CommandLine.arguments.contains("--from-xiaohe") {
    while let line = readLine() {
        let keys = Array(line)
        var out = "", i = 0
        while i < keys.count {
            if i + 1 < keys.count, let s = xiaoheSyllable[String(keys[i...i + 1])] {
                out += Scheme.current.isDouble ? doubleKeys(s, finals: Scheme.current == .ziranma ? ziranmaFinals : xiaoheFinals)! : s
                i += 2
            } else {
                out.append(keys[i])
                i += 1
            }
        }
        print(out)
    }
    exit(0)
}

let engineDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let dataDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUOKE_IME_DATA"] ?? NSTemporaryDirectory())
var memory = Memory.load()
memory.writeForgottenList() // 给壳的设置窗口列"你忘掉过哪些"
let stats = StatsRecorder()
var rime: Rime?
let scorer = Scorer()
var gate = 3.0
/// 选项 budget：auto（主控标了 slow 就用小的那档）、full、small；rounds 单独改一次重排最多几步（评测用）。
var budgetOption = "auto"
var roundsOption: Int?
/// 选项 pause（毫秒，默认 0 = 不等）：键后停顿这么久没有新键才重排，快打时中间的键不占模型（luokelabs/luoke-ime#10，评测用）；
/// pause_when：slow（只在主控标了 slow 的机器上，默认）或 always。
var pauseOption = 0.0
var pauseAlways = false
/// 选项 half（默认关，评测对照用）：双拼末尾只敲了声母的那个键也重排。默认不重排：音节还没打完，下一个键多半就换了，
/// 博客语料逐键测，打分少三四成，按空格时上屏的首选不变（见 README，luokelabs/luoke-ime#10）。
var halfOption = false
var correctOption = true // 选项 correct：打错纠正（Typo.swift），评测对照用
var budget: Budget {
    var b: Budget
    switch budgetOption {
    case "full": b = .full
    case "small": b = .small
    default: b = scorer.slow ? .small : .full
    }
    if let r = roundsOption { b.rounds = r > 0 ? r : .max }
    return b
}
var helpersStarted = false
let profiling = ProcessInfo.processInfo.environment["LUOKE_XIAOHE_PROFILE"] == "1"

/// 启动 RIME（在后台准备，准备好之前只用苹果的候选）；模型在个人化组件里，经壳转问。选项来自壳的 hello。
func startHelpers(_ options: [String: Any]) {
    guard !helpersStarted else { return }
    helpersStarted = true
    gate = options["gate"] as? Double ?? 3
    budgetOption = options["budget"] as? String ?? "auto"
    roundsOption = options["rounds"] as? Int
    pauseOption = (options["pause"] as? Double) ?? Double(options["pause"] as? Int ?? 0)
    pauseAlways = options["pause_when"] as? String == "always"
    halfOption = options["half"] as? Bool ?? false
    correctOption = options["correct"] as? Bool ?? true
    let fuzzy = (options["fuzzy"] as? [String] ?? []).map { $0.components(separatedBy: "_") }.filter { $0.count == 2 }
    mecabra.enableFuzzy(fuzzy)
    fuzzyPairs = Set(fuzzy.map { $0.joined(separator: "_") })
    if options["rime"] as? Bool ?? true { rime = Rime(engineDir: engineDir, dataDir: dataDir, fuzzy: fuzzy) }
    scorer.enabled = options["rerank"] as? Bool ?? true
    _ = scorer.isReady // 先问一次能不能打分，第一个询问来的时候多半已经知道了
}

/// 苹果的汉字候选和 emoji（文字，用掉的键数），见 Scheme.swift 的 reading。
func appleCandidates(_ input: String) -> [(text: String, consume: Int)] { reading(input).candidates }

/// 拼写跟按键一样的英文单词（不分大小写），苹果和 RIME 都查原始字母，最多 2 个。
/// RIME 还没就绪时查到的不全（只有苹果的），不留，就绪后再查。
var englishCache: [String: [String]] = [:]
func englishWords(_ input: String) -> [String] {
    if let c = englishCache[input] { return c }
    if englishCache.count > 5000 { englishCache = [:] }
    let same = { (w: String) in w.lowercased() == input }
    let rimeReady = rime?.isReady ?? true
    var out: [String] = []
    for w in mecabra.candidates(input, limit: 10) + (rime?.menu(input) ?? []) where same(w) && !out.contains(w) && out.count < 2 {
        out.append(w)
    }
    if rimeReady { englishCache[input] = out }
    return out
}

/// 立刻给出的候选：先放用户改选过的词，再放苹果的（含 emoji，最多 2 个），再放 RIME 补充的；去掉忘掉的。
/// 英文单词：按键读不通时放第一位（改选过的词之后）；读得通时放第二位，且至少 4 个字母
/// （go、no 这类常用的码不给英文）。超过 12 个键不查英文（查原始字母的用时随长度增加，长句每敲一个键都要查）。
func fastAnswer(_ input: String) -> (display: String, candidates: [[String: Any]], remembered: Bool, english: Set<String>) {
    let keys = Array(input)
    let r = reading(input)
    let complete = r.complete
    let english = (complete && keys.count < 4) || keys.count > 12 ? [] : englishWords(input).filter { !memory.isForgotten(input, $0) }
    var seen = Set<String>(english)
    var out: [[String: Any]] = []
    // 记住的词都是用掉整串键的（上屏时那一段的按键），拼不成双拼音节的（apple → Apple）也一样放首位
    for t in memory.remembered(input) where !memory.isForgotten(input, t) {
        seen.insert(t)
        out.append(["text": t, "consume": keys.count])
    }
    let rememberedCount = out.count
    var emoji = 0
    for (t, c) in appleCandidates(input) where !memory.isForgotten(input, t) && seen.insert(t).inserted {
        if !isHan(t) {
            emoji += 1
            if emoji > 2 { continue }
        }
        out.append(["text": t, "consume": c])
    }
    if let rime, complete {
        for t in rime.menu(input) where isHan(t) && !memory.isForgotten(input, t) {
            // 双拼：每个字两个键（末尾半个音节时以整串为限）；全拼：按苹果切出的音节对上
            guard let c = Scheme.current.isDouble ? min(2 * t.count, keys.count) : r.consume(chars: t.count), seen.insert(t).inserted else { continue }
            out.append(["text": t, "consume": c])
        }
    }
    // 日期、时间、星期、农历：打出这个词（用掉整串键）时，值排在它后面（Dates.swift）
    if let i = out.firstIndex(where: { Dates.words.contains($0["text"] as? String ?? "") && $0["consume"] as? Int == keys.count }) {
        let values = Dates.values(for: out[i]["text"] as! String).filter { seen.insert($0).inserted }
        out.insert(contentsOf: values.map { ["text": $0, "consume": keys.count] }, at: i + 1)
    }
    let words = english.filter { w in !out.contains { $0["text"] as? String == w } }
    out.insert(contentsOf: words.map { ["text": $0, "consume": keys.count] }, at: complete && !out.isEmpty ? max(1, rememberedCount) : rememberedCount)
    return (r.display, out, rememberedCount > 0, Set(words))
}

var decided = Decided()

/// 快的那份答复（苹果和 RIME 的候选）。refine：要不要让模型重排（至少两个音节、全部读得通、用户没在这串键上改选过；
/// 双拼末尾只敲了声母时不重排，除非开了 half）；
/// correct：要不要纠错（双拼、整串读不通、至少 4 个键、用户没在这串键上改选过，见 Typo.swift）。
typealias Fast = (display: String, candidates: [[String: Any]], remembered: Bool, english: Set<String>, refine: Bool, correct: Bool)
func sendFast(id: Int, input: String) -> Fast {
    memory.reloadIfChanged()
    let f = fastAnswer(input)
    stats.answered(input, fastTop: f.candidates.first?["text"] as? String)
    let half = Scheme.current.isDouble && input.count % 2 == 1 // 双拼每个音节两个键：单数个键时末尾只有声母
    let refine = scorer.isReady && reading(input).refinable && !f.remembered && (halfOption || !half)
    let correct = correctOption && scorer.isReady && Scheme.current.isDouble && input.count >= 4 && !reading(input).complete && !f.remembered
    send(["type": "answer", "id": id, "display": f.display, "candidates": f.candidates, "more": refine || correct])
    return (f.display, f.candidates, f.remembered, f.english, refine, correct)
}

/// 模型算着的时候先答了快的那份的询问（scorer.onQuery），轮到它时不再答一遍。
var early: (id: Int, fast: Fast)?
scorer.onQuery = {
    guard let q = inbox.latestQuery(), early?.id != q.id else { return }
    early = (q.id, sendFast(id: q.id, input: q.input))
}

/// 大写字母开头：打英文（壳只在开头收大写，见引擎协议）。候选是拼写一样的英文单词（不分大小写查，比如 Github → GitHub）
/// 和原样的字母；词典里全是小写的词照用户的大小写（Hello 不变成 hello）。不出中文，不重排。
func answerEnglish(id: Int, input: String) {
    let lower = input.lowercased()
    var out: [String] = memory.remembered(input).filter { !memory.isForgotten(input, $0) }
    for w in mecabra.candidates(lower, limit: 10) + (rime?.menu(lower) ?? []) where w.lowercased() == lower && w != lower {
        if !out.contains(w), !memory.isForgotten(input, w), out.count < 3 { out.append(w) }
    }
    if !out.contains(input) { out.append(input) }
    stats.answered(input, fastTop: out.first)
    send(["type": "answer", "id": id, "display": input, "candidates": out.map { ["text": $0, "consume": input.count] }])
}

/// 英文单词要比模型选的整句的对数概率高出多少才放第一位。没有前文时实测：拼不成话的整句差 11～46（compression 对「挫灭热送戳你」46、
/// number 对「怒敏儿」20、game 对「噶么」11），真有人这么打的词差得少（code 对「错的」9、make 对「马克」6、name 对「那么」2），
/// 这些照旧给汉字；有中文前文时汉字本来就更像（「我觉得」后面「那么」比 name 高 7）。
let englishMargin = 10.0

func answerQuery(id: Int, input: String, context: String) {
    if input.first?.isUppercase == true { return answerEnglish(id: id, input: input) }
    let fast: Fast
    if let e = early, e.id == id { fast = e.fast } else { fast = sendFast(id: id, input: input) }
    early = nil
    let keys = Array(input)
    guard fast.refine || fast.correct else { return }
    // 快打时先不重排：停顿够久（期间没有新消息）才算；等的时候来了新询问，这一个作废（壳只要最新的答复）
    if pauseOption > 0, pauseAlways || scorer.slow, !inbox.idle(for: pauseOption / 1000), inbox.hasQuery() { return }
    if fast.correct { return answerCorrected(id: id, input: input, context: context, fast: fast) }
    /// 补发整句；用户在这串键上忘掉过它（Shift+⌫）就不发，返回 false。
    func answer(_ s: String) -> Bool {
        guard !memory.isForgotten(input, s) else { return false }
        // 整句放第一位，英文单词仍在第二位。模型换掉了先给的首选时，在后面标个 ✦（注释，灰色小字），
        // 让用户知道这一下是模型按前文改的，不是闪了一下
        // 英文单词：引擎查到的（fast.english），和苹果自己给的拼写一样的词
        let isEnglish = { (c: [String: Any]) -> Bool in
            let t = c["text"] as? String ?? ""
            return fast.english.contains(t) || (!isHan(t) && t.lowercased() == input)
        }
        let rest = fast.candidates.filter { $0["text"] as? String != s }
        let english = rest.filter(isEnglish)
        let others = rest.filter { !isEnglish($0) }
        var top: [String: Any] = ["text": s, "consume": keys.count]
        // 模型只在汉字之间挑，整串键读得通时它总能拼出一句（compression →「挫灭热送戳你」）。有拼写一样的英文单词时，
        // 让模型比一比整句和英文单词哪个更像接在前文后面：英文单词明显更像（对数概率高 englishMargin 以上），它放第一位，整句排第二、不标 ✦
        if let w = english.first?["text"] as? String, let lp = scorer.score(context, [s, w]), lp[1] >= lp[0] + englishMargin {
            send(["type": "answer", "id": id, "display": fast.display, "candidates": english + [top] + others])
            return true
        }
        if fast.candidates.first?["text"] as? String != s { top["note"] = "✦" }
        send(["type": "answer", "id": id, "display": fast.display, "candidates": [top] + english + others])
        stats.refined(input, sentence: s)
        return true
    }
    /// 标了 more 之后总要有一份最终答复：没有更好的，快的那份就是最终的。
    func settleFast() { send(["type": "answer", "id": id, "display": fast.display, "candidates": fast.candidates]) }
    /// 从 start 接着选；返回整句（被取消或出错时为 nil）和到那时定下的词。whole：不限步数（停下来以后那一遍）。
    func run(from start: [Refiner.Step], whole: Bool = false) -> (String?, [Refiner.Step]) {
        var b = budget
        if whole { b.rounds = .max }
        var refiner = Refiner(apple: appleCandidates, wordConsume: { reading($0).consume(chars: $1) }, rime: rime, scorer: scorer,
                              gate: gate, budget: b, cancelled: { inbox.hasQuery() })
        if profiling { refiner.profile = Profile() }
        refiner.profile?.reused = start.count
        let started = now()
        var steps = start
        let s = refiner.sentence(input, context: context, start: start) { steps.append($0) }
        if let p = refiner.profile { log(String(format: "重排 %@：%.0f ms（%@）%@", input, now() - started, p.line, s == nil ? "，作废" : "")) }
        return (s, steps)
    }
    let start = decided.reusable(input, context: context)
    let (s, steps) = run(from: start)
    if s != nil || !steps.isEmpty { decided = Decided(context: context, keys: input, steps: steps) } // 被取消时也留下已经定下的词，下一次询问接着用
    guard let s else {
        if !inbox.hasQuery() { settleFast() } // 模型出错（被新询问取消时不必答：壳只要最新询问的答复）
        return
    }
    if !answer(s) { settleFast() } // 选出来的整句被忘掉过
    // 沿用了之前定下的词（那时后面的键还没打完），或者限了步数、末尾几个词是整句一起定的：
    // 用户停下来以后从头不限步数再选一遍，不同就再补发一次。
    // 刚才那份没标 more，按空格不必等这一份；还在打字时不做，免得占着模型、拖慢下一个键。
    let capped = s != steps.map(\.word).joined()
    guard !start.isEmpty || capped, inbox.idle(for: 0.3) else { return }
    let (again, fresh) = run(from: [], whole: true)
    guard let again else { return } // 又打字了：留着刚才定下的词
    decided = Decided(context: context, keys: input, steps: fresh)
    if again != s { _ = answer(again) }
}

/// 打错纠正：改一处后读得通的各种整句交模型按前文挑（Typo.swift），挑出的放第一位、标 ✎（和模型重排的 ✦ 分开：一个是改了你按的键，一个是按前文换了词），英文单词仍在它前面。
/// 没有读得通的改法、模型出错时，快的那份就是最终的。
func answerCorrected(id: Int, input: String, context: String, fast: Fast) {
    func settleFast() { send(["type": "answer", "id": id, "display": fast.display, "candidates": fast.candidates]) }
    let cands = Typo.candidates(input, limit: budget.apple + budget.rime)
    guard !cands.isEmpty, !inbox.hasQuery() else { return cands.isEmpty ? settleFast() : () }
    guard let lp = scorer.score(context, cands.map(\.text)) else {
        if !inbox.hasQuery() { settleFast() }
        return
    }
    let best = cands[lp.indices.max { lp[$0] < lp[$1] }!].text
    let english = fast.candidates.filter { fast.english.contains($0["text"] as? String ?? "") }
    let others = fast.candidates.filter { !fast.english.contains($0["text"] as? String ?? "") && $0["text"] as? String != best }
    let top: [String: Any] = ["text": best, "consume": input.count, "note": "✎"]
    send(["type": "answer", "id": id, "display": fast.display, "candidates": english + [top] + others])
    stats.refined(input, sentence: best)
}

let inbox = Inbox()
Thread.detachNewThread {
    while let line = readLine() { inbox.push(line) }
    inbox.close()
}

while let m = inbox.pop() {
    guard let type = m["type"] as? String else { continue }
    switch type {
    case "hello":
        startHelpers(m["options"] as? [String: Any] ?? [:])
    case "query":
        guard let id = m["id"] as? Int, let input = m["input"] as? String else { continue }
        if inbox.hasQuery() { continue } // 后面已经有新的询问：这个作废了，不必算
        startHelpers([:])
        answerQuery(id: id, input: input, context: m["context"] as? String ?? "")
        if profiling { log("答完 \(id)") }
    case "committed":
        decided = Decided() // 上屏后前文变了，之前定下的词不再沿用
        stats.committed(m)
        // 切走时的自动上屏不是用户确认的，不学
        // 以词定字取的一个字（piece 带 char）不是这串键的意思，不学；带着它拼起来的一段也不学
        guard m["auto"] as? Bool != true, let pieces = m["pieces"] as? [[String: Any]], !pieces.contains(where: { $0["char"] != nil }) else { continue }
        var changed = false
        for piece in pieces {
            guard let index = piece["index"] as? Int, index > 0, let keys = piece["input"] as? String, let text = piece["text"] as? String else { continue }
            memory.choose(keys: keys, text: text)
            changed = true
        }
        // 分几次选出来的一段（比如先翻页选"史"，再选"高"）：整串键也记住拼起来的词，下次整串打出来它就在最前面
        //（用户自己造的词）。只记全是汉字、不太长的；只有每一段都用掉一样多的键才拼得对，所以按段拼。
        if changed, pieces.count > 1 {
            let parts = pieces.compactMap { p -> (String, String)? in
                guard let k = p["input"] as? String, let t = p["text"] as? String else { return nil }
                return (k, t)
            }
            let keys = parts.map(\.0).joined(), text = parts.map(\.1).joined()
            if parts.count == pieces.count, isHan(text), text.count <= 8 { memory.choose(keys: keys, text: text) }
        }
        if changed { memory.persist() }
    case "forget":
        decided = Decided() // 忘掉的可能正是定下的词拼成的整句：从头再选
        guard let keys = m["input"] as? String, let text = m["text"] as? String else { continue }
        memory.forget(keys: keys, text: text)
        memory.persist()
    case "unforget": // 用户在设置窗口里撤销忘掉（引擎协议「forget_all」）
        guard let keys = m["input"] as? String, let text = m["text"] as? String else { continue }
        decided = Decided()
        memory.unforget(keys: keys, text: text)
        memory.persist()
    case "forget_all": // 用户在菜单里要清掉学到的词：改选过的全清掉，忘掉的名单留着（免得忘掉的词又冒出来）
        decided = Decided()
        memory.chosen = [:]
        memory.persist()
        log("清掉了学到的词")
    case "deleted":
        stats.deleted(m)
    default:
        break // 不认识的：按协议忽略
    }
}
