import Foundation
import Testing
@testable import LuokeShell

/// 改后对比（Revision.swift，引擎协议「revised」）：上屏的字后来在输入框里被改了。
@Suite struct 改后对比 {
    static func rig(personal: Bool = false) -> (Rig, FakeChannel?) {
        let r = Rig()
        r.client.revisable = true
        r.client.document = "前面的字："
        guard personal else { return (r, nil) }
        let p = FakeChannel(clock: r.clock)
        r.session.personal = PersonalEngine(manifest: 上屏转给个人化组件.personalManifest(), channel: p)
        return (r, p)
    }

    static func revised(_ ch: FakeChannel) -> [(Int, String, String)] {
        ch.sent.compactMap { if case let .revised(a, b, t) = $0 { return (a, b, t) } else { return nil } }
    }

    /// 打 wobuzd 上屏「我不知道」，等它定位。
    static func commit(_ r: Rig) {
        r.type("wobuzd")
        r.elapse(0.01)
        r.press(.space)
        r.elapse(0.3)
    }

    @Test func 改了中间的字_下一次开始输入时转给引擎和个人化组件() {
        let (r, p) = Self.rig(personal: true)
        Self.commit(r)
        #expect(r.client.document == "前面的字：我不知道")
        r.client.document = "前面的字：我不明白"
        r.type("w")
        let sent = Self.revised(r.channel)
        #expect(sent.count == 1)
        #expect(sent.first?.1 == "我不知道")
        #expect(sent.first?.2 == "我不明白")
        let toPersonal = Self.revised(p!)
        #expect(toPersonal.count == 1)
        #expect(toPersonal.first?.2 == "我不明白")
        // 转过一次就不再盯
        r.elapse(0.01)
        r.press(.escape)
        r.type("w")
        #expect(Self.revised(r.channel).count == 1)
    }

    @Test func 没改就什么都不发() {
        let (r, _) = Self.rig()
        Self.commit(r)
        r.type("w")
        #expect(Self.revised(r.channel).isEmpty)
    }

    @Test func 退格后重打_在这一段里面上屏的仍然对比原来那一段() {
        let (r, _) = Self.rig()
        Self.commit(r)
        r.press(.backspace); r.press(.backspace)
        r.client.document = "前面的字：我不"     // 应用删掉了「知道」
        r.type("wo"); r.elapse(0.01); r.press(.space); r.elapse(0.3)
        r.type("wo"); r.elapse(0.01); r.press(.space); r.elapse(0.3)
        #expect(r.client.document == "前面的字：我不我我")
        #expect(Self.revised(r.channel).isEmpty)
        r.type("w")
        let sent = Self.revised(r.channel)
        #expect(sent.count == 1)
        #expect(sent.first?.1 == "我不知道")
        #expect(sent.first?.2 == "我不我我")
    }

    @Test func 接着往后打的不算改动() {
        let (r, _) = Self.rig()
        Self.commit(r)
        r.type("wo"); r.elapse(0.01); r.press(.space); r.elapse(0.3)
        r.type("w")
        #expect(r.client.document == "前面的字：我不知道我")
        #expect(Self.revised(r.channel).isEmpty)
    }

    @Test func 前面的字增删了_位置挪了也找得到() {
        let (r, _) = Self.rig()
        Self.commit(r)
        r.client.document = "加了几个字前面的字：我不明白"
        r.type("w")
        #expect(Self.revised(r.channel).first?.2 == "我不明白")
    }

    @Test func 后面有字时靠后面的字定位_长短可以变() {
        let (r, _) = Self.rig()
        r.client.document = "前面的字："
        Self.commit(r)
        r.client.document = "前面的字：我不知道。后面"
        r.elapse(0.01)
        // 上屏时后面还没有字：按原来的长度取，后面加了字不算改动
        r.type("w")
        #expect(Self.revised(r.channel).isEmpty)
        // 只看纯函数：上屏时后面有字的，按后面的字定位
        let w = Revision.Watch(text: "我不知道", start: 5, before: "前面的字：", after: "。后面", told: 1, recorded: nil, at: 0)
        #expect(Revision.current(of: w, window: "前面的字：我真的不知道。后面", windowStart: 0) == "我真的不知道")
        #expect(Revision.current(of: w, window: "完全不一样的一段", windowStart: 0) == nil)
    }

    @Test(arguments: ["secure", "paused", "unreadable"])
    func 密码框_禁止记录_读不到的应用里不读(_ how: String) {
        let (r, _) = Self.rig()
        Self.commit(r)
        r.client.document = "前面的字：我不明白"
        switch how {
        case "secure": r.client.isSecureInput = true
        case "paused": r.client.mayRecord = false
        default: r.client.revisable = false
        }
        r.type("w")
        #expect(Self.revised(r.channel).isEmpty)
    }

    @Test func 切走前也看一次() {
        let (r, _) = Self.rig()
        Self.commit(r)
        r.client.document = "前面的字：我不明白"
        r.session.focusLost()
        #expect(Self.revised(r.channel).count == 1)
    }

    // 同一个客户端里换了输入框（网页里点到另一个框，系统不切走）：别的框里原有的字不能当成改动

    @Test func 空框里打的一段不盯_点到别的框接着打也不发() {
        let (r, p) = Self.rig(personal: true)
        r.client.document = ""             // 上屏那段前后都没有字，读回时认不出是不是同一个框
        Self.commit(r)
        #expect(r.client.document == "我不知道")
        r.session.pointerPressed()
        r.client.document = "他说明天来开会"   // 另一个框里原有的字
        r.type("w")
        #expect(Self.revised(r.channel).isEmpty)
        #expect(Self.revised(p!).isEmpty)
        // 切走时也不发
        r.session.focusLost()
        #expect(Self.revised(r.channel).isEmpty)
    }

    @Test func 光标离那一段太远就不读() {
        let (r, _) = Self.rig()
        Self.commit(r)                     // 「前面的字：我不知道」
        r.session.pointerPressed()
        // 另一个框开头碰巧一样，光标在很后面（在那里接着打字）
        r.client.document = "前面的字：我不明白" + String(repeating: "，后面还有很多字", count: 6)
        r.type("w")
        #expect(Self.revised(r.channel).isEmpty)
    }

    @Test func 光标在那一段附近_照常对比() {
        let (r, _) = Self.rig()
        Self.commit(r)
        r.client.document = "加了几个字前面的字：我不明白" // 前面增删了字，光标仍在这一段后面
        r.type("w")
        #expect(Self.revised(r.channel).first?.2 == "我不明白")
    }

    @Test func 消息的写法() {
        let m = ShellMessage.revised(after: 3, before: "日历例假", text: "日历里加").json
        #expect(m["type"] as? String == "revised")
        #expect(m["after"] as? Int == 3)
        #expect(m["before"] as? String == "日历例假")
        #expect(m["text"] as? String == "日历里加")
    }
}
