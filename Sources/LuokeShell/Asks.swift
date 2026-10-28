import Foundation

/// 转问的中转（docs/引擎协议.md#转问）：引擎发来的 `ask` 按引擎说明里的 `asks` 转给个人化组件（以后还有主控），
/// 答复再转回发问的那一代进程。壳只看 `to` 和声明，不看 `method`、`params` 和答复的内容。
///
/// 线程：在各引擎读输出的后台线程上被调用，自己加锁；往引擎写都排进各自的队列，不阻塞。
/// 主线程不参与：主线程按空格等补发时，打字引擎的转问照样能走完。
public final class AskBroker {
    /// 转出去还没答复的转问，最多留多久（发问的引擎自己决定等多久，这里只是不让表无限长）。
    public var expiry: TimeInterval = 30
    public var limit = 1024

    private struct Pending {
        weak var asker: EngineConnection?
        var askerGeneration: Int
        var askerID: Int
        var target: ObjectIdentifier
        var targetGeneration: Int
        var at: TimeInterval
    }

    private let lock = NSLock()
    /// 转问主控的请求在这里并发地发，不挡读引擎输出的线程。
    private let hubQueue = DispatchQueue(label: "luoke-ime.hub", attributes: .concurrent)
    // 以下由 lock 保护
    private var _hub: HubClient?
    /// 主控给的任务参数（GET /tasks 的 params），一分钟内不重取：打分按 batch 分批、前文按 max_chars 截短（V1 §8）。
    private var taskParams: (at: TimeInterval, version: String?, params: [String: JSONValue])?
    private weak var _personal: EngineConnection?
    private var pending: [Int: Pending] = [:]
    /// 壳自己问出去的（联想）：答复交给 done。
    private var shellPending: [Int: ShellPending] = [:]
    private var counter = 0
    private var _personalAllowed = true

    private struct ShellPending {
        var target: ObjectIdentifier
        var targetGeneration: Int
        var at: TimeInterval
        var done: (Reply) -> Void
    }

    public init() {}

    /// 当前的个人化组件（同一时间一个）。换掉时，还在等旧组件的转问一律答 `unavailable`。
    public var personal: EngineConnection? {
        get { locked { _personal } }
        set {
            let old: EngineConnection? = locked {
                let o = _personal
                _personal = newValue
                return o
            }
            if let old, old !== newValue {
                failPending { $0.target == ObjectIdentifier(old) }
                failShellPending { $0.target == ObjectIdentifier(old) }
            }
        }
    }

    /// 现在能不能把引擎的转问交给个人化组件。壳在每次按键、换输入框时按隐私开关算好设进来：安全输入时一律不能；
    /// 个人化组件是第三方的，"禁止记录"的应用里、暂停时、没允许保存到本机记忆时也不能（它可能自己存下来）。
    /// 自带的个人化组件不存转问的内容，这些时候照常给打分。
    public var personalAllowed: Bool {
        get { locked { _personalAllowed } }
        set { locked { _personalAllowed = newValue } }
    }

    /// 引擎能问个人化组件的方法。predict 用的是用户写过的历史，只有壳自己能问。
    public static let engineMethods: Set<String> = ["score", "ping"]

    /// 主控的客户端（to: "hub" 的转问经它转过去）；nil 时这类转问答 unavailable。
    public var hub: HubClient? {
        get { locked { _hub } }
        set { locked { _hub = newValue } }
    }

    /// 接上一个引擎：它发的转问、（个人化组件的）答复和它的退出都经这里。
    public func attach(_ c: EngineConnection) {
        c.onAsk = { [weak self, weak c] a, gen in
            guard let self, let c else { return }
            self.ask(a, from: c, generation: gen)
        }
        c.onReply = { [weak self, weak c] r, gen in
            guard let self, let c else { return }
            self.reply(r, from: c, generation: gen)
        }
        c.onExit = { [weak self, weak c] gen in
            guard let self, let c else { return }
            self.exited(c, generation: gen)
        }
    }

    /// 还没答复的转问有几个（测试用）。
    public var pendingCount: Int { locked { pending.count } }

    // MARK: -

    func ask(_ a: Ask, from c: EngineConnection, generation gen: Int) {
        func fail(_ code: String, _ message: String) {
            c.send(.reply(Reply(id: a.id, error: code, message: message)), toGeneration: gen)
        }
        guard let target = Manifest.AskTarget(rawValue: a.to) else {
            return fail("bad_request", "to 只能是 " + Manifest.AskTarget.allCases.map(\.rawValue).joined(separator: " 或 "))
        }
        guard c.manifest.asks.contains(target) else {
            return fail("not_allowed", "引擎说明里没有声明 \"asks\": [\"\(a.to)\"]")
        }
        switch target {
        case .hub:
            guard let hub else { return fail("unavailable", "主控（luoke-core）还没接上") }
            guard let req = Self.hubRequest(a) else {
                return fail("bad_request", "主控的转问只认 score（params 带 task、context、candidates，task 要是 luoke-ime. 开头）、continue（task、context，可带 k、max_tokens、stop）、predict（task、context）、tasks、warmup")
            }
            hubQueue.async { [weak self] in
                let reply: Reply
                if a.method == "score", let self {
                    reply = self.score(a, hub: hub, request: req)
                } else {
                    reply = Self.hubReply(a.id, hub.request(req.method, req.path, body: req.body, timeout: req.timeout))
                }
                c.send(.reply(reply), toGeneration: gen)
            }
        case .personal:
            guard Self.engineMethods.contains(a.method) else {
                return fail("not_allowed", "引擎只能问个人化组件 " + Self.engineMethods.sorted().joined(separator: "、") + "（联想只有壳能问）")
            }
            guard personalAllowed else { return fail("unavailable", "现在不能把输入交给个人化组件（安全输入、禁止记录的应用、暂停或没允许保存到记忆）") }
            guard let p = personal, p !== c, p.state == .running else { return fail("unavailable", "没有在运行的个人化组件") }
            let now = ProcessInfo.processInfo.systemUptime
            let pg = p.generation
            let sid: Int = locked {
                pending = pending.filter { now - $0.value.at < expiry }
                if pending.count >= limit, let oldest = pending.min(by: { $0.value.at < $1.value.at }) { pending[oldest.key] = nil }
                counter += 1
                pending[counter] = Pending(asker: c, askerGeneration: gen, askerID: a.id, target: ObjectIdentifier(p),
                                           targetGeneration: pg, at: now)
                return counter
            }
            p.send(.ask(id: sid, from: c.id, method: a.method, params: a.params), toGeneration: pg)
        }
    }

    /// 壳自己问个人化组件（比如上屏后要联想）。`done` 在后台线程上调一次：个人化组件的答复，或者壳给的错误
    /// （没有在运行的个人化组件、它中途退出了）。答复的 `id` 没有意义。
    public func askFromShell(method: String, params: JSONValue, done: @escaping (Reply) -> Void) {
        guard let p = personal, p.state == .running else {
            return done(Reply(id: 0, error: "unavailable", message: "没有在运行的个人化组件"))
        }
        let now = ProcessInfo.processInfo.systemUptime
        let pg = p.generation
        let sid: Int = locked {
            shellPending = shellPending.filter { now - $0.value.at < expiry }
            counter += 1
            shellPending[counter] = ShellPending(target: ObjectIdentifier(p), targetGeneration: pg, at: now, done: done)
            return counter
        }
        p.send(.ask(id: sid, from: "shell", method: method, params: params), toGeneration: pg)
    }

    /// 转问 → 主控的请求（luoke-core V1 §2）：只转输入法自己的任务。
    static func hubRequest(_ a: Ask) -> (method: String, path: String, body: JSONValue?, timeout: TimeInterval)? {
        func task() -> String? {
            guard case let .string(t)? = a.params["task"], t.hasPrefix("luoke-ime."),
                  t.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
            return t
        }
        switch a.method {
        case "score":
            guard let t = task(), let ctx = a.params["context"], let cands = a.params["candidates"] else { return nil }
            return ("POST", "/tasks/\(t)/v1/score", .object(["context": ctx, "candidates": cands]), 2)
        case "continue":
            // 通用的续写（怎么截、挑哪几个归输入法，主控只续写）：字段原样转，壳不看内容
            guard let t = task(), let ctx = a.params["context"] else { return nil }
            var body: [String: JSONValue] = ["context": ctx]
            for k in ["k", "max_tokens", "stop"] { if let v = a.params[k] { body[k] = v } }
            return ("POST", "/tasks/\(t)/v1/continue", .object(body), 2)
        case "predict": // 老主控（还没有 continue）用
            guard let t = task(), let ctx = a.params["context"] else { return nil }
            var body: [String: JSONValue] = ["context": ctx]
            for k in ["k", "n"] { if let v = a.params[k] { body[k] = v } }
            return ("POST", "/tasks/\(t)/v1/predict", .object(body), 2)
        case "tasks":
            return ("GET", "/tasks", nil, 5)
        case "warmup":
            guard let t = task() else { return nil }
            return ("POST", "/warmup", .object(["task": .string(t)]), 5)
        default:
            return nil
        }
    }

    /// 打分：照任务参数把候选分批（每批不超过 batch 个）、前文截到 max_chars，一批一批问，结果拼起来。
    /// 后面几批的前文和第一批一样，命中主控的前缀缓存。
    private func score(_ a: Ask, hub: HubClient, request req: (method: String, path: String, body: JSONValue?, timeout: TimeInterval)) -> Reply {
        guard case let .string(task)? = a.params["task"], case let .array(cands)? = a.params["candidates"],
              case let .string(context)? = a.params["context"] else { return Reply(id: a.id, error: "bad_request", message: "score 要 task、context、candidates") }
        let params = self.params(for: task, hub: hub)
        let batch = max(1, params["batch"].flatMap { if case let .number(n) = $0 { return Int(n) } else { return nil } } ?? 16)
        let maxChars = params["max_chars"].flatMap { if case let .number(n) = $0 { return Int(n) } else { return nil } } ?? 2000
        let ctx = JSONValue.string(String(context.suffix(maxChars)))
        var logprobs: [JSONValue] = []
        var hit = true, ms = 0.0
        var model: JSONValue = .null
        var start = 0
        repeat {
            let chunk = Array(cands[start..<min(start + batch, cands.count)])
            let raw = hub.request(req.method, req.path, body: .object(["context": ctx, "candidates": .array(chunk)]), timeout: req.timeout)
            if case let .success(resp) = raw { noteTasksVersion(resp.headers["x-luoke-tasks-version"]) }
            let r = Self.hubReply(a.id, raw)
            guard case let .object(o)? = r.result, case let .array(lp)? = o["logprobs"], lp.count == chunk.count else { return r }
            logprobs += lp
            if case let .bool(h)? = o["cache_hit"] { hit = hit && h }
            if case let .number(m)? = o["ms"] { ms += m }
            model = o["model"] ?? model
            start += batch
        } while start < cands.count
        return Reply(id: a.id, result: .object(["logprobs": .array(logprobs), "model": model, "cache_hit": .bool(hit), "ms": .number(ms)]))
    }

    private func params(for task: String, hub: HubClient) -> [String: JSONValue] {
        let now = ProcessInfo.processInfo.systemUptime
        if let t = locked({ taskParams }), now - t.at < 60 { return t.params[task].flatMap { if case let .object(o) = $0 { return o } else { return nil } } ?? [:] }
        var all: [String: JSONValue] = [:]
        var version: String?
        if case let .success(r) = hub.request("GET", "/tasks", timeout: 2), case let .object(tasks)? = r.json?["tasks"] {
            for (name, t) in tasks { if let p = t["params"] { all[name] = p } }
            if case let .string(v)? = r.json?["tasks_version"] { version = v } else { version = r.headers["x-luoke-tasks-version"] }
        }
        locked { taskParams = (now, version, all) }
        return all[task].flatMap { if case let .object(o) = $0 { return o } else { return nil } } ?? [:]
    }

    /// 主控答复里的任务版本变了（配方、任务参数、引擎版本……）：下一次重读 GET /tasks。
    private func noteTasksVersion(_ v: String?) {
        guard let v else { return }
        locked { if let t = taskParams, t.version != v { taskParams = nil } }
    }

    /// 主控的答复 → 转问的答复：成功时原样给 result；拒绝时 error 带主控的 code、message、retry_after；连不上答 unavailable。
    static func hubReply(_ id: Int, _ r: Result<HubClient.Response, HubClient.Failure>) -> Reply {
        switch r {
        case let .success(resp) where resp.status < 400:
            guard let j = resp.json else { return Reply(id: id, error: "engine_failed", message: "主控的答复看不懂") }
            return Reply(id: id, result: j)
        case let .success(resp):
            var e: [String: JSONValue] = ["code": .string("engine_failed"), "message": .string("主控答 \(resp.status)")]
            if case let .object(o)? = resp.json {
                for k in ["code", "message", "retry_after"] { if let v = o[k] { e[k] = v } }
            }
            return Reply(id: id, result: nil, error: .object(e))
        case let .failure(f):
            let why: String
            switch f {
            case let .unreachable(s), let .broken(s): why = s
            }
            return Reply(id: id, error: "unavailable", message: "主控不可用：\(why)")
        }
    }

    func reply(_ r: Reply, from c: EngineConnection, generation gen: Int) {
        let mine: ShellPending? = locked {
            guard let e = shellPending[r.id], e.target == ObjectIdentifier(c), e.targetGeneration == gen else { return nil }
            shellPending[r.id] = nil
            return e
        }
        if let mine { return mine.done(r) }
        // 只认转给它的那一代进程、还在等的号；别的（晚到的、伪造的、别的引擎发的）一律丢掉
        let entry: Pending? = locked {
            guard let e = pending[r.id], e.target == ObjectIdentifier(c), e.targetGeneration == gen else { return nil }
            pending[r.id] = nil
            return e
        }
        guard let e = entry, let asker = e.asker else { return }
        var back = r
        back.id = e.askerID
        asker.send(.reply(back), toGeneration: e.askerGeneration)
    }

    private func exited(_ c: EngineConnection, generation gen: Int) {
        let id = ObjectIdentifier(c)
        // 个人化组件退出：还在等它的答 unavailable，发问的引擎不必干等；发问的引擎退出：它的转问不用再转回
        failPending { $0.target == id && $0.targetGeneration == gen }
        failShellPending { $0.target == id && $0.targetGeneration == gen }
        locked { pending = pending.filter { !($0.value.asker === c && $0.value.askerGeneration == gen) } }
    }

    private func failPending(_ match: (Pending) -> Bool) {
        let failed: [Pending] = locked {
            let hit = pending.filter { match($0.value) }
            for k in hit.keys { pending[k] = nil }
            return Array(hit.values)
        }
        for e in failed {
            e.asker?.send(.reply(Reply(id: e.askerID, error: "unavailable", message: "个人化组件退出了")), toGeneration: e.askerGeneration)
        }
    }

    private func failShellPending(_ match: (ShellPending) -> Bool) {
        let failed: [ShellPending] = locked {
            let hit = shellPending.filter { match($0.value) }
            for k in hit.keys { shellPending[k] = nil }
            return Array(hit.values)
        }
        for e in failed { e.done(Reply(id: 0, error: "unavailable", message: "个人化组件退出了")) }
    }

    private func locked<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }
}
