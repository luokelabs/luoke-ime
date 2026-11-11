import Foundation
import LuokeShell

/// `luoke-ime check`：自动检查一个引擎，输出写引擎的 agent 能直接读的报告（docs/设计.md#命令行版-luoke-ime）。
struct CheckReport {
    enum Status: String { case pass = "✓", warn = "⚠", fail = "✗" }
    struct Item { var status: Status; var name: String; var detail: String }

    var items: [Item] = []
    mutating func add(_ s: Status, _ name: String, _ detail: String) { items.append(Item(status: s, name: name, detail: detail)) }
    var failed: Bool { items.contains { $0.status == .fail } }
}

private func ms(_ t: TimeInterval) -> String {
    t < 0.001 ? String(format: "%.2f ms", t * 1000) : t < 0.01 ? String(format: "%.1f ms", t * 1000) : String(format: "%.0f ms", t * 1000)
}

private func percentile(_ xs: [TimeInterval], _ p: Double) -> TimeInterval {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}

/// 一个只给检查用的会话无关客户端：直接收发协议消息。
private final class Probe {
    let conn: EngineConnection
    let channel: EngineChannel
    var protocolErrors: [String] = []
    var stderr: [String] = []
    var exits: [Int32] = []
    var replies: [Reply] = []
    let lock = NSLock()

    init(_ conn: EngineConnection) {
        self.conn = conn
        channel = conn.makeChannel()
        conn.onReply = { [weak self] r, _ in
            guard let self else { return }
            self.lock.lock()
            self.replies.append(r)
            self.lock.unlock()
        }
        conn.onEvent = { [weak self] e in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            switch e {
            case let .protocolError(m): self.protocolErrors.append(m)
            case let .stderr(l): self.stderr.append(l)
            case let .exited(status, _): self.exits.append(status)
            default: break
            }
        }
    }

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var disabled: Bool { if case .disabled = conn.state { return true } else { return false } }

    /// 收消息直到 `done` 返回 true、超时，或引擎被停用。
    func collect(timeout: TimeInterval, _ done: (EngineMessage) -> Bool) -> Bool {
        let end = now + timeout
        while now < end, !disabled {
            for m in channel.drain() where done(m) { return true }
            channel.wait(until: min(end, now + 0.05))
        }
        for m in channel.drain() where done(m) { return true }
        return false
    }

    private var askCounter = 0

    /// 像壳转问那样问个人化组件一次，返回号。
    func sendAsk(method: String, params: JSONValue = .object([:])) -> Int {
        askCounter += 1
        conn.send(.ask(id: askCounter, from: "luoke-check", method: method, params: params))
        return askCounter
    }

    /// 等号为 `id` 的答复，最多到 `deadline`。
    func reply(_ id: Int, until deadline: TimeInterval) -> Reply? {
        while true {
            lock.lock()
            let r = replies.first { $0.id == id }
            lock.unlock()
            if let r { return r }
            if now >= deadline || disabled { return nil }
            usleep(5000)
        }
    }

    /// 问一次并等答复（最多 `timeout` 秒）。
    func ask(method: String, params: JSONValue = .object([:]), timeout: TimeInterval = 2) -> (reply: Reply, latency: TimeInterval)? {
        let t = now
        let id = sendAsk(method: method, params: params)
        return reply(id, until: t + timeout).map { ($0, now - t) }
    }
}

func runCheck(engineDir: URL, sandboxed: Bool, json: Bool) -> Int32 {
    var report = CheckReport()
    let name = engineDir.standardizedFileURL.lastPathComponent
    defer { output(report, engine: name, dir: engineDir, json: json) }

    // 1. 引擎说明
    let manifest: Manifest
    do {
        manifest = try Manifest.load(from: engineDir)
    } catch {
        report.add(.fail, "引擎说明", "\(error)")
        return 1
    }
    var desc: String
    switch manifest.kind {
    case .typing:
        desc = "打字引擎「\(manifest.name)」，输入键 \(manifest.inputKeys.count) 个，前文 \(manifest.context) 字，反馈\(manifest.feedback ? "要" : "不要")"
    case .hotkey:
        desc = "快捷键引擎「\(manifest.name)」，\(manifest.hotkey!.key.rawValue)（\(manifest.hotkey!.mode.rawValue)）"
    case .personal:
        desc = "个人化组件「\(manifest.name)」，前文 \(manifest.context) 字，应用\(manifest.app ? "要" : "不要")"
    }
    if !manifest.asks.isEmpty { desc += "，转问 " + manifest.asks.map(\.rawValue).sorted().joined(separator: "、") }
    let p = manifest.permissions
    var perms: [String] = []
    if p.network != .none { perms.append("联网：\(p.network.rawValue)") }
    if !p.write.isEmpty { perms.append("额外可写：" + p.write.joined(separator: "、")) }
    if p.microphone { perms.append("麦克风") }
    if p.camera { perms.append("摄像头") }
    if p.screen { perms.append("屏幕录制") }
    if p.gpu { perms.append("GPU") }
    if p.memory { perms.append("读写记忆") }
    desc += "；所需权限：" + (perms.isEmpty ? "无" : perms.joined(separator: "，"))
    report.add(.pass, "引擎说明", desc)

    // 2. 启动（用一次性的数据目录，不弄脏真的）
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("luoke-ime-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    // 记忆也用一次性的：检查发的假上屏不能写进真的记忆
    let conn = EngineConnection(id: name, dir: engineDir, manifest: manifest,
                                paths: Paths(root: root.appendingPathComponent("ime"), memory: root.appendingPathComponent("mem.db")))
    conn.sandboxed = sandboxed
    conn.protectedPaths = Paths()
    conn.memoryGranted = true // 检查用的是一次性的记忆
    // 沙盒拦截：从系统日志里认领这个引擎被拦的操作
    let monitor = SandboxMonitor()
    let denialLock = NSLock()
    var denials: [SandboxDenial] = []
    monitor.onDenial = { d in
        guard d.engine == conn.sandboxTag else { return }
        denialLock.lock(); denials.append(d); denialLock.unlock()
    }
    let monitoring = sandboxed && monitor.start()
    defer { monitor.stop() }
    let probe = Probe(conn)
    let t0 = probe.now
    do {
        try conn.start()
    } catch {
        report.add(.fail, "启动", "\(error)")
        return 1
    }

    switch manifest.kind {
    case .typing: checkTyping(probe, manifest, startedAt: t0, &report)
    case .hotkey: checkHotkey(probe, &report)
    case .personal: checkPersonal(probe, manifest, &report)
    }

    // 不认识的消息
    conn.sendRaw(["type": "x-luoke-check", "note": "不认识的消息类型，引擎应当忽略"])
    if manifest.kind == .typing, !probe.disabled {
        let id = probe.channel.nextID()
        let first = manifest.inputKeys.sorted().first.map(String.init) ?? "a"
        probe.channel.send(.query(id: id, input: first, context: manifest.context > 0 ? "" : nil, app: nil))
        let ok = probe.collect(timeout: 2) { $0.id == id }
        report.add(ok ? .pass : .fail, "不认识的消息", ok ? "忽略了，之后照常答复" : "收到不认识的消息类型后不再答复（协议要求忽略不认识的 type 和字段）")
    }
    if manifest.kind == .personal, !probe.disabled {
        let ok = probe.ask(method: "x-luoke-check") != nil
        report.add(ok ? .pass : .fail, "不认识的消息", ok ? "忽略了，之后照常答复转问" : "收到不认识的消息类型后不再答复转问（协议要求忽略不认识的 type 和字段）")
    }

    // 标准输出 / 标准错误
    usleep(300_000) // 刚发的取消、不认识的消息若让引擎崩了，退出记录要过一会儿才到
    probe.lock.lock()
    let perrs = probe.protocolErrors, errs = probe.stderr, exits = probe.exits
    probe.lock.unlock()
    if perrs.isEmpty {
        report.add(.pass, "标准输出", "只有协议消息")
    } else {
        let sample = Array(Set(perrs)).prefix(3).joined(separator: "；")
        report.add(.fail, "标准输出", "\(perrs.count) 行不是合法的协议消息，例如：\(sample)。日志请写标准错误。")
    }
    if !exits.isEmpty, !probe.disabled {
        report.add(.fail, "崩溃", "检查过程中引擎退出了 \(exits.count) 次（状态 \(exits.map(String.init).joined(separator: "、"))）" +
                   (errs.isEmpty ? "" : "，错误输出最后几行：\n" + errs.suffix(5).joined(separator: "\n")))
    }
    if !errs.isEmpty, exits.isEmpty {
        report.add(.pass, "标准错误", "\(errs.count) 行（只做参考），最后一行：\(errs.last!)")
    }

    // 退出（放在沙盒拦截之前：引擎退出时保存数据，这时被拦的也要算上）
    if probe.disabled {
        report.add(.fail, "停用", "检查过程中引擎反复崩溃，被停用了（退出状态 \(exits.map(String.init).joined(separator: "、"))）" +
                   (errs.isEmpty ? "" : "，错误输出最后几行：\n" + errs.suffix(5).joined(separator: "\n")))
        return 1
    }
    let t1 = probe.now
    let exited = conn.stopAndWait(timeout: 1)
    report.add(exited ? .pass : .fail, "退出", exited ? "关闭标准输入后 \(ms(probe.now - t1)) 退出" : "关闭标准输入后 1 秒内没有退出（应在读到输入结束时退出）")
    // 沙盒
    if !sandboxed {
        report.add(.warn, "沙盒拦截", "用了 --no-sandbox，没有检查沙盒")
    } else if !monitoring {
        report.add(.warn, "沙盒拦截", "读不了系统日志（log stream），没有检查沙盒拦截；可能需要管理员账户")
    } else {
        usleep(300_000) // 等最后几条日志到达
        denialLock.lock()
        let all = denials
        denialLock.unlock()
        var seen = Set<String>()
        let hard = all.filter { $0.severity == .hard && seen.insert("\($0.category) \($0.operation) \($0.detail)").inserted }
        let softCount = all.filter { $0.severity == .soft }.count
        let softNote = softCount > 0 ? "（另有 \(softCount) 次可以忽略的，如名称解析、字节码缓存）" : ""
        if hard.isEmpty {
            report.add(.pass, "沙盒拦截", "没有被拦下需要处理的操作" + softNote)
        } else {
            let lines = hard.prefix(8).map { "\($0.process)：\($0.suggestion)" }
            report.add(.fail, "沙盒拦截", "\(hard.count) 种操作被沙盒拦下" + softNote + "\n" + lines.joined(separator: "\n"))
        }
    }

    return report.failed ? 1 : 0
}

private func checkTyping(_ probe: Probe, _ m: Manifest, startedAt t0: TimeInterval, _ report: inout CheckReport) {
    let keys = Array(m.inputKeys).sorted()
    var rng = SystemRandomNumberGenerator()
    func word(_ n: Int) -> String { String((0..<n).map { _ in keys.randomElement(using: &rng)! }) }
    let ctx: String? = m.context > 0 ? String("今天我们一起去".suffix(m.context)) : nil

    // 首次答复（含启动时间）
    let id0 = probe.channel.nextID()
    probe.channel.send(.query(id: id0, input: word(2), context: ctx, app: nil))
    var firstAnswerAt: TimeInterval?
    _ = probe.collect(timeout: 5) { msg in
        if msg.id == id0 { firstAnswerAt = probe.now; return true }
        return false
    }
    guard let fa = firstAnswerAt else {
        report.add(.fail, "启动", "启动后 5 秒内没有答复第一次询问")
        return
    }
    report.add(fa - t0 <= 5 ? .pass : .fail, "启动", "启动后 \(ms(fa - t0)) 给出第一次答复")

    // 逐个询问：像打字一样每次多一个键，每个都等到最终答复
    var inputs: [Int: String] = [:]
    var first: [TimeInterval] = []
    var final: [TimeInterval] = []
    var problems: [String] = []
    var usedMore = false
    var unresolvedMore = 0
    var noAnswer = 0
    var candidateCount = 0
    var answered = 0
    func problem(_ s: String) { if problems.count < 8, !problems.contains(s) { problems.append(s) } }

    var plan: [String] = []
    for _ in 0..<12 {
        let w = word(Int.random(in: 4...12))
        for n in 1...w.count { plan.append(String(w.prefix(n))) }
    }
    var silentInARow = 0
    for input in plan {
        if probe.disabled || silentInARow >= 3 { break }
        let id = probe.channel.nextID()
        inputs[id] = input
        let sent = probe.now
        probe.channel.send(.query(id: id, input: input, context: ctx, app: nil))
        var gotFirst = false
        var settled = false
        _ = probe.collect(timeout: 2) { msg in
            guard case let .answer(a) = msg else {
                if msg.id != nil { problem("答复询问时发来了 \(msg)") }
                return false
            }
            guard let asked = inputs[a.id] else { problem("答复了一个不存在的 id \(a.id)"); return false }
            guard a.id == id else { return false } // 旧询问的迟到答复，壳会丢弃，不算错
            if !gotFirst { gotFirst = true; first.append(probe.now - sent) }
            if a.more { usedMore = true }
            for c in a.candidates {
                if c.consume < 1 || c.consume > asked.count { problem("询问 \(asked) 的候选「\(c.text)」consume=\(c.consume)，应在 1 到 \(asked.count) 之间") }
                if c.text.isEmpty { problem("询问 \(asked) 有空的候选文字") }
            }
            if !a.more {
                settled = true
                final.append(probe.now - sent)
                candidateCount += a.candidates.count
                answered += 1
            }
            return settled
        }
        if !gotFirst { noAnswer += 1; silentInARow += 1 } else { silentInARow = 0; if !settled { unresolvedMore += 1 } }
    }
    if case let .disabled(reason) = probe.conn.state {
        report.add(.fail, "崩溃", "引擎反复崩溃，被停用了：\(reason)")
        return
    }

    // 连续快打：不等答复连发，最后一个必须答到
    let burst = word(10)
    var lastID = 0
    for n in 1...burst.count {
        lastID = probe.channel.nextID()
        inputs[lastID] = String(burst.prefix(n))
        probe.channel.send(.query(id: lastID, input: String(burst.prefix(n)), context: ctx, app: nil))
    }
    let burstOK = probe.collect(timeout: 3) { if case let .answer(a) = $0 { return a.id == lastID && !a.more } else { return false } }

    let total = plan.count
    if silentInARow >= 3 {
        report.add(.fail, "答复", "连续 3 次询问 2 秒内都没有任何答复，提前结束检查（壳 1 秒没答复就当卡死重启）")
        return
    } else if noAnswer > 0 {
        report.add(.fail, "答复", "\(total) 次询问里有 \(noAnswer) 次 2 秒内没有任何答复（壳 1 秒没答复就当卡死重启）")
    } else if problems.isEmpty {
        report.add(.pass, "答复", "\(total) 次询问都答复了，格式正确，平均每次 \(answered > 0 ? candidateCount / answered : 0) 个候选")
    }
    if !problems.isEmpty { report.add(.fail, "答复格式", problems.joined(separator: "\n")) }
    if candidateCount == 0 { report.add(.warn, "候选", "随机输入下一个候选都没给，确认一下输入键和词表是否对得上") }

    let p50 = percentile(first, 0.5), p95 = percentile(first, 0.95)
    let speed = "首个答复 p50 \(ms(p50))，p95 \(ms(p95))"
    if p95 <= 0.05 {
        report.add(.pass, "速度", speed)
    } else if p95 <= 0.5 {
        report.add(.warn, "速度", speed + "。超过 50 ms 时候选窗要等；慢的计算请先给快的答复（more: true）再补发")
    } else {
        report.add(.fail, "速度", speed + "。太慢：壳 1 秒没答复就当卡死；先给快的答复，慢的计算放到补发里")
    }
    if usedMore {
        let f95 = percentile(final, 0.95)
        if unresolvedMore > 0 {
            report.add(.fail, "补发", "\(unresolvedMore) 次标了 more: true 之后 2 秒内没有给最终答复")
        } else {
            report.add(f95 <= 0.15 ? .pass : .warn, "补发", "最终答复 p95 \(ms(f95))" + (f95 <= 0.15 ? "" : "，超过 150 ms 时用户按空格等不到，会上屏快的那份"))
        }
    } else {
        report.add(.pass, "补发", "没有用到（每次只答复一次）")
    }
    report.add(burstOK ? .pass : .fail, "连续快打", burstOK ? "不等答复连发 10 次，最后一次正常答复" : "连发询问后，最新的那次 3 秒内没有最终答复")

    // 反馈
    if m.feedback {
        let cid = probe.channel.nextID()
        probe.channel.send(.committed(.init(id: cid, text: "测试", auto: false, context: ctx,
                                            pieces: [Piece(input: word(2), text: "测试", index: 0, top: "测试")])))
        probe.channel.send(.deleted(after: cid, count: 1, followedBy: ""))
        probe.channel.send(.forget(input: word(2), text: "测试", context: ctx))
        probe.channel.send(.committed(.init(id: probe.channel.nextID(), text: "ab", auto: true, context: nil, pieces: [.raw("ab")])))
        let id = probe.channel.nextID()
        probe.channel.send(.query(id: id, input: word(2), context: ctx, app: nil))
        let ok = probe.collect(timeout: 2) { $0.id == id }
        report.add(ok ? .pass : .fail, "反馈", ok ? "收到上屏、退格、忘掉之后照常答复" : "收到反馈消息之后不再答复")
    }
}

/// 个人化组件：发一组像真的一样的上屏、退格、忘掉，再转问几次，看它是否答复、答复的号对不对。
private func checkPersonal(_ probe: Probe, _ m: Manifest, _ report: inout CheckReport) {
    let ctx: String? = m.context > 0 ? "今天" : nil
    let app: String? = m.app ? "com.example.check" : nil
    let c = probe.conn
    c.send(.committed(.init(id: 1, text: "我不知道", auto: false, context: ctx,
                            pieces: [Piece(input: "wo", text: "我", index: 0, top: "我"), Piece(input: "buzd", text: "不知道", index: 1, top: "不只道")],
                            source: "luoke-check", kind: .typing, app: app)))
    c.send(.committed(.init(id: 2, text: "，", auto: false, context: nil, pieces: [], source: "luoke-check", kind: .punctuation, app: app)))
    c.send(.deleted(after: 1, count: 2, followedBy: "，"))
    c.send(.forget(input: "xkyy", text: "行云", context: ctx, source: "luoke-check"))
    c.send(.committed(.init(id: 3, text: "今天下午三点开会。", auto: false, context: ctx, pieces: [], source: "luoke-check-voice", kind: .hotkey, app: app)))
    c.send(.committed(.init(id: 4, text: "ab", auto: true, context: nil, pieces: [.raw("ab")], source: "luoke-check", kind: .typing, app: app)))
    guard let (r, latency) = probe.ask(method: "ping") else {
        report.add(.fail, "转问", "收到上屏、退格、忘掉之后，转问 ping 2 秒内没有答复（每个 ask 都要用同一个 id 答一条 reply）")
        return
    }
    report.add(.pass, "上屏和转问", "收到上屏、退格、忘掉之后，转问 ping 在 \(ms(latency)) 内答复" + (r.errorCode.map { "（错误 \($0)）" } ?? ""))
    if let (r2, _) = probe.ask(method: "x-luoke-check-unknown-method") {
        report.add(r2.error != nil ? .pass : .warn, "不认识的方法", r2.error != nil ? "答复了错误 \(r2.errorCode ?? "")" : "答复了 result；不认识的方法建议答 error（code 写 unknown_method）")
    } else {
        report.add(.fail, "不认识的方法", "转问一个不认识的方法，2 秒内没有答复：不认识的方法也要答一条带 error 的 reply")
    }
    // 连发：不等答复连问 10 次，每个号都要答
    let t = probe.now
    let ids = (0..<10).map { _ in probe.sendAsk(method: "ping") }
    let missing = ids.filter { probe.reply($0, until: t + 3) == nil }.count
    report.add(missing == 0 ? .pass : .fail, "连续转问",
               missing == 0 ? "不等答复连问 10 次，都按号答复了（共 \(ms(probe.now - t))）" : "不等答复连问 10 次，\(missing) 次 3 秒内没有答复")
}

private func checkHotkey(_ probe: Probe, _ report: inout CheckReport) {
    let id = probe.channel.nextID()
    probe.channel.send(.start(id: id, context: nil, app: nil))
    var shows = 0
    _ = probe.collect(timeout: 0.5) { if case .show = $0 { shows += 1 }; return false }
    probe.channel.send(.stop(id: id))
    var result: String?
    let t = probe.now
    _ = probe.collect(timeout: 10) { msg in
        switch msg {
        case let .show(i, _, _, _) where i == id: shows += 1; return false
        case let .commit(i, text) where i == id: result = "上屏「\(text)」"; return true
        case let .end(i) where i == id: result = "结束，没有上屏"; return true
        default: return false
        }
    }
    if let r = result {
        report.add(.pass, "快捷键会话", "start 后推送了 \(shows) 次显示串；stop 后 \(ms(probe.now - t)) \(r)")
    } else {
        report.add(.fail, "快捷键会话", "stop 之后 10 秒内没有 commit 或 end（壳会按超时取消）")
    }
    let id2 = probe.channel.nextID()
    probe.channel.send(.start(id: id2, context: nil, app: nil))
    probe.channel.send(.cancel(id: id2, reason: .esc))
    report.add(.pass, "取消", "发了 start 后立刻 cancel")
}

private func output(_ report: CheckReport, engine: String, dir: URL, json: Bool) {
    if json {
        let obj: [String: Any] = [
            "engine": engine, "dir": dir.path, "ok": !report.failed,
            "checks": report.items.map { ["status": $0.status == .pass ? "pass" : $0.status == .warn ? "warn" : "fail", "name": $0.name, "detail": $0.detail] },
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
        return
    }
    print("检查「\(engine)」（\(dir.path)）\n")
    for item in report.items {
        let lines = item.detail.components(separatedBy: "\n")
        print("\(item.status.rawValue) \(item.name)：\(lines[0])")
        for l in lines.dropFirst() { print("    \(l)") }
    }
    let fails = report.items.filter { $0.status == .fail }.count
    let warns = report.items.filter { $0.status == .warn }.count
    print("\n结论：\(fails == 0 ? "通过" : "没有通过")（\(fails) 个问题，\(warns) 个提醒）")
}

func runList() -> Int32 {
    let paths = Paths()
    let dirs = (try? FileManager.default.contentsOfDirectory(at: paths.engines, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    let engines = dirs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.sorted { $0.path < $1.path }
    if engines.isEmpty {
        print("\(paths.engines.path) 里还没有引擎。把引擎文件夹放进去就会出现在这里。")
        return 0
    }
    for dir in engines {
        do {
            let m = try Manifest.load(from: dir)
            let kind: String
            switch m.kind {
            case .typing: kind = "打字"
            case .hotkey: kind = "快捷键 \(m.hotkey!.key.rawValue)"
            case .personal: kind = "个人化组件"
            }
            print("\(dir.lastPathComponent)\t\(m.name)\t\(kind)")
        } catch {
            print("\(dir.lastPathComponent)\t不可用：\(error)")
        }
    }
    return 0
}
