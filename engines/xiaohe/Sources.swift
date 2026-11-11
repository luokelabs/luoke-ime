import Foundation

/// RIME（雾凇词库；小鹤双拼或全拼方案，见 Scheme）出的候选。第一次启动要编译词库，可能要几十秒；编好之前 isReady 为 false。
final class Rime {
    private let process: LineProcess
    private let lock = NSLock()
    private var ready = false
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready && process.isRunning }

    init?(engineDir: URL, dataDir: URL, fuzzy: [[String]] = []) {
        let shared = engineDir.appendingPathComponent("vendor/rime-ice")
        let schema = Scheme.current.rimeSchema
        guard FileManager.default.fileExists(atPath: shared.appendingPathComponent("\(schema).schema.yaml").path) else {
            log("没有雾凇词库（vendor/rime-ice），只用苹果的候选；运行 build.sh 会下载")
            return nil
        }
        let user = dataDir.appendingPathComponent("rime")
        try? FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        // 关掉 RIME 自己的用户词典：学习由引擎的记忆和模型负责
        // 内容没变就不写：RIME 看到补丁变了会重编词库
        let patch = user.appendingPathComponent("\(schema).custom.yaml")
        let text = "patch:\n  translator/enable_user_dict: false\n" + Self.fuzzyPatch(fuzzy)
        if (try? String(contentsOf: patch, encoding: .utf8)) != text { try? text.write(to: patch, atomically: false, encoding: .utf8) }
        var r: Rime?
        do {
            process = try LineProcess(engineDir.appendingPathComponent("rime_helper").path, [shared.path, user.path, schema]) { line in
                if line == "ready" { r?.markReady() } else { log("RIME ⟩ \(line)") }
            }
        } catch {
            log("启动 RIME 失败：\(error)")
            return nil
        }
        r = self
    }

    /// 模糊音的拼写规则：插在方案的 speller/algebra 最前面，这时拼写还是全拼，双拼方案再往下才换成键位。
    /// an/ang 不碰 ian/iang、uan/uang，那两组这次没做。
    static func fuzzyPatch(_ pairs: [[String]]) -> String {
        var rules: [String] = []
        for p in pairs {
            let (a, b) = (p[0], p[1])
            if a.hasSuffix("n") { // 韵母
                let head = a == "an" ? "(^|[^iu])" : "()"
                rules += ["derive/\(head)\(b)$/$1\(a)/", "derive/\(head)\(a)$/$1\(b)/"]
            } else { // 声母
                rules += ["derive/^\(b)/\(a)/", "derive/^\(a)([^h])/\(b)$1/"]
            }
        }
        return rules.enumerated().map { "  speller/algebra/@before \($0.offset): '\($0.element)'\n" }.joined()
    }

    private func markReady() { lock.lock(); ready = true; lock.unlock(); log("RIME 已就绪") }

    /// 答过的。用户词典关着，同一串键的候选不变，可以一直留着。
    private var menus: [String: [String]] = [:]

    /// 第一段的候选（最多 9 个）。
    func menu(_ keys: String) -> [String] {
        if let m = menus[keys] { return m }
        guard isReady, let line = process.ask("menu\t\(keys)\t9", timeout: 0.5) else { return [] }
        let m = line.split(separator: "\t").map(String.init)
        if menus.count > 20000 { menus = [:] }
        menus[keys] = m
        return m
    }
}

/// 模型打分：经壳转问个人化组件（docs/引擎协议.md#转问；第 2 期把打分进程从这里搬到了个人化组件，只加载一份模型）。
/// 个人化组件没装、模型还没加载好时不重排，每隔几秒试一次能不能打分。
final class Scorer {
    /// 选项里关了重排时为 false。
    var enabled = true
    /// 打分的地方说这台机器上打分慢（主控按实测给 rerank 标了 slow，个人化组件随答复带过来）。只在主线程上读写。
    private(set) var slow = false

    private let cond = NSCondition()
    // 以下由 cond 保护
    private var ready = false
    private var counter = 0
    private var probing: Int?               // 试试能不能打分的那次转问
    private var probedAt: TimeInterval = -.infinity
    private var waiting: Int?               // 正在等哪一次打分的答复
    private var answer: [String: Any]?
    private var nudged = false              // 等答复的时候来了新询问
    /// 等答复的时候来了新询问：在主线程上调它，先把新询问快的那份答了（慢的机器上一步要算几十毫秒，不让候选窗跟不上按键）。
    var onQuery: () -> Void = {}

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// 能打分吗。不能时过一会儿再问一次（发一个空的打分，答复由读标准输入的线程交给 deliver）。只在主线程上调。
    var isReady: Bool {
        guard enabled else { return false }
        cond.lock()
        defer { cond.unlock() }
        if !ready, uptime - probedAt > 2 { // 上一次没答复（比如壳没转）也算问过了，过一会儿再问
            counter += 1
            probing = counter
            probedAt = uptime
            send(["type": "ask", "id": counter, "to": "personal", "method": "score", "params": ["context": "", "candidates": [String]()]])
        }
        return ready
    }

    /// 读标准输入的线程收到新询问时调。
    func nudge() {
        cond.lock()
        nudged = true
        cond.broadcast()
        cond.unlock()
    }

    /// 读标准输入的线程收到 reply 时调。
    func deliver(_ m: [String: Any]) {
        guard let id = m["id"] as? Int else { return }
        cond.lock()
        defer { cond.unlock() }
        if id == probing {
            probing = nil
            let ok = m["result"] != nil
            if ok != ready { log(ok ? "模型已就绪" : "模型不可用：\((m["error"] as? [String: Any])?["message"] as? String ?? "")") }
            ready = ok
        } else if id == waiting {
            answer = m
            cond.broadcast()
        }
    }

    /// 等一次打分最多多久。引擎一次只做一件事，模型算着的时候新来的询问要等这一步算完才答；
    /// 壳 1 秒收不到答复就当引擎卡死、强行重启（还计入停用次数），所以要留出余量给快的答复。
    static let timeout: TimeInterval = 0.7

    /// 每个候选的对数概率；出错或超时返回 nil。等答复的时候先做 meanwhile 里的事。只在主线程上调。
    func score(_ context: String, _ candidates: [String], meanwhile: () -> Void = {}) -> [Double]? {
        cond.lock()
        guard ready else { cond.unlock(); return nil }
        counter += 1
        let id = counter
        waiting = id
        answer = nil
        cond.unlock()
        send(["type": "ask", "id": id, "to": "personal", "method": "score", "params": ["context": context, "candidates": candidates]])
        meanwhile()
        cond.lock()
        defer { waiting = nil; cond.unlock() }
        let deadline = Date().addingTimeInterval(Scorer.timeout)
        while answer == nil {
            if nudged {
                nudged = false
                cond.unlock()
                onQuery()
                cond.lock()
                continue
            }
            if !cond.wait(until: deadline) { break }
        }
        guard let a = answer else { return nil } // 超时：晚到的答复号对不上，deliver 会丢掉
        if let r = a["result"] as? [String: Any], let lp = r["logprobs"] as? [Double], lp.count == candidates.count {
            if let s = r["slow"] as? Bool, s != slow {
                slow = s
                log(s ? "打分慢（主控标了 slow）：每一步少给模型一半候选" : "打分不慢了：每一步照常给候选")
            }
            return lp
        }
        // 个人化组件不在了、模型没了：先不重排，过一会儿再试
        if let code = (a["error"] as? [String: Any])?["code"] as? String, ["unavailable", "not_ready", "not_allowed"].contains(code) {
            ready = false
            probedAt = uptime
            log("模型不可用：\(code)")
        }
        return nil
    }
}
