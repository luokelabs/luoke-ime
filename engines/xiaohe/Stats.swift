import Foundation

/// 本机统计：模型（✦）在真实输入里帮了多少。只记次数，不记任何文字；存在引擎数据目录的 stats.json，不外传。
/// 每一段上屏按"选的时候首选是什么"分到下面几类里（切走时的自动上屏、按回车原样上屏的字母不算）。
struct Stats: Codable {
    var since = ISO8601DateFormatter().string(from: Date())
    /// 用户确认上屏的段数
    var pieces = 0
    /// 选的时候首选带 ✦（模型换掉了先给的首选）：直接用了它 / 改选回先给的首选 / 选了别的
    var starAccepted = 0
    var starReverted = 0
    var starOther = 0
    /// 模型会换首选，但选的时候 ✦ 还没到（补发没赶上，或已经移动了高亮）；其中最后选的正是模型那句
    var starLate = 0
    var starLateModelRight = 0
    /// 首选没带 ✦（模型没改，或这串键没让模型重排）：用了首选 / 选了别的
    var plainTop = 0
    var plainOther = 0
    /// 上屏后紧接着按了退格：这次上屏用了 ✦ 的首选 / 没用
    var deletedAfterStar = 0
    var deletedAfterPlain = 0

    static var file: URL? {
        ProcessInfo.processInfo.environment["LUOKE_IME_DATA"].map { URL(fileURLWithPath: $0).appendingPathComponent("stats.json") }
    }

    static func load() -> Stats {
        guard let url = file, let data = try? Data(contentsOf: url),
              let s = try? Self.decoder.decode(Stats.self, from: data) else { return Stats() }
        return s
    }

    func save() {
        guard let url = Stats.file, let data = try? Self.encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

/// 最近答过的询问：先给的首选、模型补发的整句。上屏时据此判断用户选的时候看到的是什么。
final class StatsRecorder {
    private(set) var stats = Stats.load()
    private var answers: [String: (fastTop: String?, refined: String?)] = [:]
    /// 最近一次上屏：反馈里的 id，和它是否用了 ✦ 的首选（等退格反馈来对上）
    private var lastCommit: (id: Int, usedStar: Bool)?

    func answered(_ input: String, fastTop: String?) {
        if answers.count > 512 { answers = [:] }
        answers[input] = (fastTop, nil)
    }

    func refined(_ input: String, sentence: String) {
        answers[input]?.refined = sentence
    }

    /// committed 反馈：每一段对应它当时那次询问（这一段和它后面所有段的键）。
    func committed(_ m: [String: Any]) {
        guard m["auto"] as? Bool != true, let pieces = m["pieces"] as? [[String: Any]] else { return }
        let inputs = pieces.map { $0["input"] as? String ?? "" }
        var usedStar = false
        for (i, p) in pieces.enumerated() {
            guard p["raw"] as? Bool != true, let text = p["text"] as? String else { continue }
            stats.pieces += 1
            let top = p["top"] as? String
            let r = answers[inputs[i...].joined()]
            let changed = r?.refined != nil && r?.refined != r?.fastTop
            if changed, top == r?.refined {
                if text == top {
                    stats.starAccepted += 1
                    usedStar = true
                } else if text == r?.fastTop {
                    stats.starReverted += 1
                } else {
                    stats.starOther += 1
                }
            } else if changed, top == r?.fastTop {
                stats.starLate += 1
                if text == r?.refined { stats.starLateModelRight += 1 }
            } else if (p["index"] as? Int ?? 0) == 0 {
                stats.plainTop += 1
            } else {
                stats.plainOther += 1
            }
        }
        lastCommit = (m["id"] as? Int).map { ($0, usedStar) }
        stats.save()
    }

    /// deleted 反馈：上屏后紧接着按了几次退格。
    func deleted(_ m: [String: Any]) {
        guard let c = lastCommit, m["after"] as? Int == c.id, (m["count"] as? Int ?? 0) > 0 else { return }
        if c.usedStar { stats.deletedAfterStar += 1 } else { stats.deletedAfterPlain += 1 }
        lastCommit = nil
        stats.save()
    }
}
