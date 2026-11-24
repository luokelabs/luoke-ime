import Foundation
@testable import LuokeShell

final class FakeClock: Clock {
    var now: TimeInterval = 1000
    func advance(_ dt: TimeInterval) { now += dt }
}

/// 假引擎：收到消息时按脚本安排若干条带延迟的回复；`wait` 推进假时钟。
final class FakeChannel: EngineChannel {
    let clock: FakeClock
    var available = true
    var sent: [ShellMessage] = []
    var hangs = 0
    /// 收到一条消息后要回什么：[(多久之后, 消息)]
    var script: (ShellMessage) -> [(TimeInterval, EngineMessage)] = { _ in [] }
    private var pending: [(at: TimeInterval, message: EngineMessage)] = []
    private var counter = 0

    init(clock: FakeClock) { self.clock = clock }

    var isAvailable: Bool { available }
    func nextID() -> Int { counter += 1; return counter }
    func send(_ message: ShellMessage) {
        sent.append(message)
        for (dt, m) in script(message) { pending.append((clock.now + dt, m)) }
        pending.sort { $0.at < $1.at }
    }
    func drain() -> [EngineMessage] {
        let due = pending.filter { $0.at <= clock.now }
        pending.removeAll { $0.at <= clock.now }
        return due.map(\.message)
    }
    func wait(until deadline: TimeInterval) {
        if let next = pending.first?.at, next <= deadline { clock.now = max(clock.now, next) } else { clock.now = max(clock.now, deadline) }
    }
    func reportHang() { hangs += 1; available = false }

    /// 让引擎在 dt 之后推送一条消息（不对应任何收到的消息）。
    func push(_ m: EngineMessage, after dt: TimeInterval = 0) {
        pending.append((clock.now + dt, m))
        pending.sort { $0.at < $1.at }
    }

    var queries: [(id: Int, input: String, context: String?)] {
        sent.compactMap { if case let .query(id, input, context, _) = $0 { return (id, input, context) } else { return nil } }
    }
}

final class FakeClient: SessionClient {
    var document = ""
    var readable = true
    var isSecureInput = false
    var mayRecord = true
    var mayPredict = true
    var memoryConsented = true
    var appID: String? = "com.example.app"
    var views: [SessionView] = []
    var view: SessionView { views.last ?? SessionView() }

    func textBeforeCursor(limit: Int) -> String? { readable ? String(document.suffix(limit)) : nil }
    /// 模拟 Grok 这类应用：输入法接下 Tab 以后自己又插了个制表符（测试里手动往 document 里加）。
    var supportsReplace = false
    func caretLocation() -> Int? { supportsReplace || revisable ? (document as NSString).length : nil }
    /// 读得到文档里的字（改后对比）：测试里直接改 document 当作用户在输入框里改了字。
    var revisable = false
    func text(at location: Int, length: Int) -> String? {
        let d = document as NSString
        guard revisable, location >= 0, location <= d.length else { return nil }
        return d.substring(with: NSRange(location: location, length: min(length, d.length - location)))
    }
    func replaceStrayTab(at location: Int, with text: String) -> Bool {
        let d = document as NSString
        guard supportsReplace, !text.isEmpty, location < d.length, d.substring(with: NSRange(location: location, length: 1)) == "\t" else { return false }
        document = d.substring(to: location) + text + d.substring(from: location + 1)
        return true
    }
    func insert(_ text: String) { document += text }
    func render(_ view: SessionView) { views.append(view) }
}

/// 一个查表的假引擎：输入串的每个前缀查表，长的在前。
func tableScript(_ table: [String: [String]], delay: TimeInterval = 0.002) -> (ShellMessage) -> [(TimeInterval, EngineMessage)] {
    return { m in
        guard case let .query(id, input, _, _) = m else { return [] }
        var cands: [Candidate] = []
        for n in stride(from: input.count, through: 1, by: -1) {
            for t in table[String(input.prefix(n))] ?? [] { cands.append(Candidate(text: t, consume: n)) }
        }
        return [(delay, .answer(Answer(id: id, candidates: cands)))]
    }
}

func typingManifest(context: Int = 0, feedback: Bool = true, keys: String = "abcdefghijklmnopqrstuvwxyz") -> Manifest {
    Manifest(protocolVersion: 1, name: "测试", kind: .typing, run: ["x"], inputKeys: Set(keys), punctuation: .default,
             context: context, app: false, feedback: feedback, hotkey: nil, permissions: .init(), options: nil)
}

/// 一套装好的被测对象。
struct Rig {
    let clock = FakeClock()
    let client = FakeClient()
    let channel: FakeChannel
    let session: Session

    init(manifest: Manifest = typingManifest(), settings: ShellSettings = ShellSettings(), timing: Timing = Timing(),
         script: @escaping (ShellMessage) -> [(TimeInterval, EngineMessage)] = tableScript(["wo": ["我", "窝"], "bu": ["不", "步"], "zd": ["知道"], "buzd": ["不知道"], "wobuzd": ["我不知道"]])) {
        channel = FakeChannel(clock: clock)
        channel.script = script
        session = Session(client: client, clock: clock, settings: settings, timing: timing)
        session.typing = TypingEngine(manifest: manifest, channel: channel)
    }

    @discardableResult
    func type(_ s: String) -> [Bool] { s.map { session.handle(.char($0)) } }

    @discardableResult
    func press(_ k: KeyEvent.Key, _ flags: KeyEvent.Flags = []) -> Bool { session.handle(KeyEvent(k, flags: flags)) }

    /// 推进时间，期间按宿主的方式 pump / tick。
    func elapse(_ dt: TimeInterval) {
        let end = clock.now + dt
        while true {
            let next = min(session.nextDeadline ?? end, end)
            channel.wait(until: next)
            session.tick()
            if clock.now >= end { break }
        }
    }
}
