import Foundation
import Testing
@testable import LuokeShell

// 每个测试对应 docs/设计.md 里的一条规则。

@Suite struct 输入与选词 {
    @Test func 输入键进入输入串并询问() {
        let r = Rig()
        #expect(r.type("wo") == [true, true])
        #expect(r.channel.queries.map(\.input) == ["w", "wo"])
        r.elapse(0.01)
        #expect(r.client.view.marked == "wo")
        #expect(r.client.view.candidates.map(\.text) == ["我", "窝"])
    }

    @Test func 部分选词留在显示串里_整串选完才上屏() {
        let r = Rig()
        r.type("wobuzd")
        r.elapse(0.01)
        r.press(.right) // 高亮移到不是整句的候选
        #expect(r.client.view.candidates.first?.text == "我不知道")
        r.type("2") // 第 2 个是"我"，只用掉 wo
        #expect(r.client.document == "")
        #expect(r.channel.queries.last?.input == "buzd")
        r.elapse(0.01)
        #expect(r.client.view.marked == "我buzd")
        #expect(r.client.view.selectedLength == 1)
        r.press(.space)
        #expect(r.client.document == "我不知道")
        #expect(r.client.view.marked == "")
    }

    @Test func 已选部分算作前文最后一截() {
        let r = Rig(manifest: typingManifest(context: 10))
        r.client.document = "今天"
        r.type("wobuzd")
        r.elapse(0.01)
        r.type("2")
        #expect(r.channel.queries.last?.context == "今天我")
    }

    @Test func 退格先删键_删光后撤销最后一段() {
        let r = Rig()
        r.type("wobu")
        r.elapse(0.01)
        r.type("1") // "我"
        r.elapse(0.01)
        r.press(.backspace)
        r.press(.backspace)
        #expect(r.client.view.marked == "我")
        r.press(.backspace)
        #expect(r.channel.queries.last?.input == "wo")
        r.elapse(0.01)
        #expect(r.client.view.marked == "wo")
        r.press(.backspace)
        r.press(.backspace)
        #expect(!r.session.isComposing)
    }

    @Test func 回车上屏已选部分加原始字母_Esc丢弃() {
        let r = Rig()
        r.type("wobuzd")
        r.elapse(0.01)
        r.type("2")
        r.press(.enter)
        #expect(r.client.document == "我buzd")
        r.type("wo")
        r.press(.escape)
        #expect(r.client.document == "我buzd")
        #expect(!r.session.isComposing)
    }

    @Test func 翻页和数字选当前页() {
        let many = (1...12).map { "字\($0)" }
        var s = ShellSettings()
        s.pageSize = 5
        let r = Rig(settings: s, script: tableScript(["a": many]))
        r.type("a")
        r.elapse(0.01)
        #expect(r.client.view.candidates.count == 5)
        r.type("=")
        #expect(r.client.view.page == 1)
        #expect(r.client.view.candidates.first?.text == "字6")
        r.type("2")
        #expect(r.client.document == "字7")
    }

    @Test func 第一页按减号_拼音串照原样上屏再接减号_不在第一页照旧翻页() {
        // luokelabs/luoke-ime#17：luoke-ime 这类带连字符的词
        let r = Rig(script: tableScript(["wo": ["我", "窝", "握", "卧", "沃", "涡", "斡", "倭", "幄", "肟", "龌"]]))
        r.type("luoke")
        r.elapse(0.01)
        #expect(r.press(.character("-")) == false) // 「-」交给应用
        #expect(r.client.document == "luoke")
        #expect(!r.session.isComposing)
        // 翻到第二页以后，「-」照旧是上一页
        r.type("wo")
        r.elapse(0.1)
        r.press(.character("="))
        #expect(r.press(.character("-")))
        #expect(r.session.isComposing)
    }

    @Test func 没有候选的位置按数字忽略() {
        let r = Rig()
        r.type("wo")
        r.elapse(0.01)
        r.type("7")
        #expect(r.session.isComposing)
        #expect(r.client.document == "")
    }

    @Test func 旧询问的答复丢弃() {
        let r = Rig(script: { m in
            guard case let .query(id, input, _, _) = m else { return [] }
            // 越早的询问答得越慢
            return [(input.count == 1 ? 0.03 : 0.001, .answer(Answer(id: id, candidates: [Candidate(text: input, consume: input.count)])))]
        })
        r.type("ab")
        r.elapse(0.05)
        #expect(r.client.view.candidates.map(\.text) == ["ab"])
    }

    @Test func 连续打字时候选窗和显示串不闪() {
        let r = Rig(script: { m in
            guard case let .query(id, input, _, _) = m else { return [] }
            let display = stride(from: 0, to: input.count, by: 2).map { i -> String in
                let a = input.index(input.startIndex, offsetBy: i)
                return String(input[a..<(input.index(a, offsetBy: 2, limitedBy: input.endIndex) ?? input.endIndex)])
            }.joined(separator: " ")
            return [(0.005, .answer(Answer(id: id, display: display, candidates: [Candidate(text: "候\(input.count)", consume: input.count)])))]
        })
        r.type("wob")
        r.elapse(0.01)
        #expect(r.client.view.marked == "wo b")
        let before = r.client.views.count
        r.type("u")
        r.elapse(0.01)
        let during = r.client.views[before...]
        #expect(during.allSatisfy { !$0.candidates.isEmpty }) // 一直有候选，没有空的那一帧
        #expect(during.first?.marked == "wo bu")              // 答复前：上一次的显示串接上新键
        #expect(r.client.view.candidates.first?.text == "候4")
        r.press(.escape)
        r.type("x")
        #expect(r.client.view.candidates.isEmpty)             // 新的一段输入不带上一段的候选
    }

    @Test func 自动上屏标记() {
        let r = Rig(script: { m in
            guard case let .query(id, input, _, _) = m, input.count == 4 else { return [] }
            return [(0.001, .answer(Answer(id: id, candidates: [Candidate(text: "四码", consume: 4)], autocommit: true)))]
        })
        r.type("abcd")
        r.elapse(0.01)
        #expect(r.client.document == "四码")
    }
}

@Suite struct 先快后好 {
    /// 先快后好的引擎：2 ms 给快的（more），`late` 秒后补发好的。
    static func twoSpeed(late: TimeInterval) -> (ShellMessage) -> [(TimeInterval, EngineMessage)] {
        return { m in
            guard case let .query(id, input, _, _) = m else { return [] }
            return [(0.002, .answer(Answer(id: id, candidates: [Candidate(text: "快", consume: input.count)], more: true))),
                    (late, .answer(Answer(id: id, candidates: [Candidate(text: "好", consume: input.count), Candidate(text: "快", consume: input.count)])))]
        }
    }

    @Test func 五十毫秒内补发到了就直接画好的() {
        let r = Rig(script: Self.twoSpeed(late: 0.03))
        r.type("a")
        r.elapse(0.02)
        #expect(r.client.view.candidates.isEmpty) // 还在等，不画快的
        r.elapse(0.02)
        #expect(r.client.view.candidates.first?.text == "好")
        #expect(!r.client.views.contains { $0.candidates.first?.text == "快" })
    }

    @Test func 补发来晚了先画快的再替换() {
        let r = Rig(script: Self.twoSpeed(late: 0.12))
        r.type("a")
        r.elapse(0.06)
        #expect(r.client.view.candidates.first?.text == "快")
        r.elapse(0.1)
        #expect(r.client.view.candidates.first?.text == "好")
    }

    @Test func 移动高亮后不再替换() {
        let r = Rig(script: { m in
            guard case let .query(id, _, _, _) = m else { return [] }
            return [(0.002, .answer(Answer(id: id, candidates: [Candidate(text: "快", consume: 1), Candidate(text: "慢", consume: 1)], more: true))),
                    (0.2, .answer(Answer(id: id, candidates: [Candidate(text: "好", consume: 1)])))]
        })
        r.type("a")
        r.elapse(0.06)
        r.press(.right)
        r.elapse(0.3)
        #expect(r.client.view.candidates.map(\.text) == ["快", "慢"])
        r.press(.space)
        #expect(r.client.document == "慢")
    }

    @Test func 空格等补发最多一百五十毫秒() {
        let r = Rig(script: Self.twoSpeed(late: 0.1))
        r.type("a")
        r.elapse(0.06)
        let t0 = r.clock.now
        r.press(.space)
        #expect(r.client.document == "好")
        #expect(r.clock.now - t0 < 0.15)
    }

    @Test func 空格等不到补发就上屏现有首选() {
        let r = Rig(script: Self.twoSpeed(late: 5))
        r.type("a")
        r.elapse(0.06)
        let t0 = r.clock.now
        r.press(.space)
        #expect(r.client.document == "快")
        #expect(abs(r.clock.now - t0 - 0.15) < 0.001)
    }

    @Test func 还没有任何答复时空格也会等() {
        let r = Rig(script: tableScript(["a": ["啊"]], delay: 0.08))
        r.type("a")
        r.press(.space)
        #expect(r.client.document == "啊")
    }

    @Test func 引擎答得慢时空格等到第一份答复_不上屏拼音() {
        // luokelabs/luoke-ime#11：冷启动、换页时第一份答复可能晚过 150 ms
        let r = Rig(script: tableScript(["wo": ["我"]], delay: 0.4))
        r.type("wo")
        r.press(.space)
        #expect(r.client.document == "我")
        #expect(r.channel.hangs == 0)
    }

    @Test func 引擎答得慢时数字和标点也等到第一份答复() {
        let r = Rig(script: tableScript(["ab": ["甲", "乙"], "wo": ["我"]], delay: 0.4))
        r.type("ab")
        r.type("2")
        #expect(r.client.document == "乙")
        r.type("wo")
        r.type(",")
        #expect(r.client.document == "乙我，")
    }

    @Test func 引擎卡死时按数字收尾_数字交给应用不吞掉() {
        let r = Rig(script: { _ in [] })
        r.type("ab")
        let t0 = r.clock.now
        #expect(r.press(.character("2")) == false)
        #expect(r.client.document == "ab")
        #expect(r.channel.hangs == 1)
        #expect(r.clock.now - t0 <= 1.0 + 0.001)
    }

    @Test func 一个候选都没有时空格上屏原始字母() {
        let r = Rig(script: tableScript([:]))
        r.type("xyz")
        r.elapse(0.01)
        r.press(.space)
        #expect(r.client.document == "xyz")
    }
}

@Suite struct 标点与收尾上屏 {
    @Test func 空闲时按标点表上屏() {
        let r = Rig()
        r.type(",")
        #expect(r.client.document == "，")
    }

    @Test func 数字后保持半角() {
        let r = Rig()
        #expect(r.press(.character("3")) == false) // 数字放行
        r.client.document += "3"
        #expect(r.press(.character(".")) == false)
    }

    @Test func 数字后的逗号看下一个键_接数字是半角() {
        // 1,000 照旧是半角
        let r = Rig()
        r.press(.character("1"))
        #expect(r.press(.character(",")))
        #expect(r.client.view.marked == ",") // 先挂在光标处
        #expect(r.client.document.isEmpty)
        #expect(r.press(.character("0")) == false) // 数字照常放行
        #expect(r.client.document == ",")
        #expect(r.client.view.marked.isEmpty)
    }

    @Test func 空闲_组字和挂着的逗号都不算() {
        // 换了新版时输入法挑空闲的时候自己退出（UpgradeWatch），不丢正在打的字
        let r = Rig()
        #expect(r.session.isIdle)
        r.type("wo")
        #expect(!r.session.isIdle)
        r.elapse(0.01)
        r.press(.space)
        #expect(r.session.isIdle)
        r.press(.character("1"))
        r.press(.character(","))
        #expect(!r.session.isIdle)
        r.press(.character("0"))
        #expect(r.session.isIdle)
    }

    @Test func 数字后的逗号接中文是全角() {
        // 27，所以
        let r = Rig()
        r.press(.character("2"))
        r.press(.character("7"))
        r.press(.character(","))
        r.type("wo")
        #expect(r.client.document == "，")
        #expect(r.session.isComposing)
        r.elapse(0.01)
        r.press(.space)
        #expect(r.client.document == "，我")
    }

    @Test func 数字后的逗号_退格就不要了_切走上屏全角() {
        let r = Rig()
        r.press(.character("2"))
        r.press(.character(","))
        #expect(r.press(.backspace))
        #expect(r.client.document.isEmpty)
        #expect(r.client.view.marked.isEmpty)
        r.press(.character(","))
        r.session.focusLost()
        #expect(r.client.document == "，")
    }

    @Test func 数字后的句号冒号照旧半角_不是数字后的逗号照旧全角() {
        let r = Rig()
        r.press(.character("3"))
        #expect(r.press(.character(".")) == false)
        r.press(.character("1"))
        #expect(r.press(.character(":")) == false)
        let r2 = Rig()
        r2.press(.character(","))
        #expect(r2.client.document == "，")
    }

    @Test func 花括号默认打成直角引号_和系统拼音一样_关了就交给应用() {
        let r = Rig()
        r.press(.character("{"))
        r.press(.character("}"))
        r.press(.character("["))
        #expect(r.client.document == "「」【")
        var s = ShellSettings()
        s.cornerBraces = false
        let off = Rig(settings: s)
        #expect(off.press(.character("{")) == false) // 关了：照旧交给应用（打代码用）
    }

    @Test func 引号成对() {
        let r = Rig()
        r.type("\"\"")
        #expect(r.client.document == "“”")
    }

    @Test func 引擎声明的标点表整张替换默认表() {
        var m = typingManifest()
        m.punctuation = PunctuationTable([",": .single(",")])
        let r = Rig(manifest: m)
        r.type(",")
        #expect(r.client.document == ",")
        #expect(r.press(.character(".")) == false) // 表里没有，放行
    }

    @Test func 输入中按标点先收尾上屏再上屏标点() {
        let r = Rig()
        r.type("wobuzd")
        r.elapse(0.01)
        r.type(",")
        #expect(r.client.document == "我不知道，")
    }

    @Test func 收尾上屏时高亮的只用掉一部分就接着用首选选完() {
        let r = Rig()
        r.type("wobuzd")
        r.elapse(0.01)
        r.press(.right) // 高亮"我"
        r.type(",")
        #expect(r.client.document == "我不知道，")
    }

    @Test func 切走时不等待_拿不到答复的部分按原始字母() {
        let r = Rig()
        r.type("wobuzd")
        r.elapse(0.01)
        r.press(.right) // 高亮"我"
        r.session.focusLost()
        #expect(r.client.document == "我buzd")
        guard case let .committed(c)? = r.channel.sent.last(where: { if case .committed = $0 { return true } else { return false } }) else {
            Issue.record("没有发上屏反馈"); return
        }
        #expect(c.auto)
    }

    @Test func 输入中点鼠标先收尾上屏_和切走一样() {
        let r = Rig()
        r.type("wobuzd")
        r.elapse(0.01)
        r.press(.right) // 高亮"我"
        r.session.pointerPressed()
        #expect(r.client.document == "我buzd")
        #expect(r.client.view.marked.isEmpty)
        guard case let .committed(c)? = r.channel.sent.last(where: { if case .committed = $0 { return true } else { return false } }) else {
            Issue.record("没有发上屏反馈"); return
        }
        #expect(c.auto)
        r.session.focusLost() // 之后再失去焦点不会再上屏一遍
        #expect(r.client.document == "我buzd")

        let idle = Rig()
        idle.session.pointerPressed() // 没在输入时点鼠标什么也不上屏
        #expect(idle.client.document.isEmpty)
    }

    @Test func 组合键先收尾再放行() {
        let r = Rig()
        r.type("wo")
        r.elapse(0.01)
        #expect(r.press(.character("a"), [.command]) == false)
        #expect(r.client.document == "我")
    }
}

@Suite struct 反馈 {
    @Test func 上屏反馈带每一段() {
        let r = Rig(manifest: typingManifest(context: 20))
        r.client.document = "今天"
        r.type("wobuzd")
        r.elapse(0.01)
        r.type("2")
        r.elapse(0.01)
        r.press(.space)
        guard case let .committed(c)? = r.channel.sent.last else { Issue.record("最后一条不是上屏反馈"); return }
        #expect(c.text == "我不知道")
        #expect(c.context == "今天")
        #expect(c.pieces == [Piece(input: "wo", text: "我", index: 1, top: "我不知道"),
                             Piece(input: "buzd", text: "不知道", index: 0, top: "不知道")])
        #expect(!c.auto)
    }

    @Test func 以词定字_方括号取高亮候选的头一个或最后一个字() {
        let r = Rig()
        r.type("wobuzd")
        r.elapse(0.01)
        r.type("[")
        #expect(r.client.document == "我")
        guard case let .committed(c)? = r.channel.sent.last else { Issue.record("最后一条不是上屏反馈"); return }
        #expect(c.pieces == [Piece(input: "wobuzd", text: "我", index: 0, top: "我不知道", char: "first")])
        r.type("wobuzd")
        r.elapse(0.01)
        r.type("]")
        #expect(r.client.document == "我道")
    }

    @Test func 以词定字_没在输入时方括号照常是标点() {
        let r = Rig()
        r.type("[")
        #expect(r.client.document == "【")
    }

    @Test func 上屏后紧接着的退格() {
        let r = Rig()
        r.type("wobuzd")
        r.elapse(0.01)
        r.press(.space)
        #expect(r.press(.backspace) == false)
        #expect(r.press(.backspace) == false)
        r.type("x") // 别的键结束计数
        guard case let .deleted(after, count, followedBy)? = r.channel.sent.last(where: { if case .deleted = $0 { return true } else { return false } }) else {
            Issue.record("没有发退格反馈"); return
        }
        #expect(count == 2)
        #expect(followedBy == "")
        #expect(after > 0)
    }

    @Test func 退格停顿五秒也结束计数() {
        let r = Rig()
        r.type("wo")
        r.elapse(0.01)
        r.press(.space)
        r.press(.backspace)
        r.elapse(6)
        #expect(r.channel.sent.contains { if case .deleted(_, 1, _) = $0 { return true } else { return false } })
    }

    @Test func 标点紧跟上屏时退格反馈带上它() {
        let r = Rig()
        r.type("wo")
        r.elapse(0.01)
        r.type(",")
        r.press(.backspace)
        r.press(.backspace)
        r.elapse(6)
        #expect(r.channel.sent.contains { if case .deleted(_, 2, "，") = $0 { return true } else { return false } })
    }

    @Test func 没声明反馈就不发() {
        let r = Rig(manifest: typingManifest(feedback: false))
        r.type("wo")
        r.elapse(0.01)
        r.press(.space)
        r.press(.backspace)
        r.elapse(6)
        #expect(!r.channel.sent.contains { if case .query = $0 { return false } else { return true } })
    }

    @Test func 忘掉() {
        let r = Rig()
        r.type("wo")
        r.elapse(0.01)
        r.press(.right)
        r.press(.backspace, [.shift])
        #expect(r.channel.sent.contains(.forget(input: "wo", text: "窝", context: nil)))
        #expect(r.channel.queries.count == 3) // 忘掉后重新询问
        #expect(r.session.isComposing)
    }
}

@Suite struct 前文 {
    @Test func 读引擎声明的字数() {
        let r = Rig(manifest: typingManifest(context: 3))
        r.client.document = "一二三四五"
        r.type("w")
        #expect(r.channel.queries.last?.context == "三四五")
    }

    @Test func 声明为零就不读() {
        let r = Rig(manifest: typingManifest(context: 0))
        r.client.document = "秘密"
        r.type("w")
        #expect(r.channel.queries.last?.context == nil)
    }

    @Test func 安全输入时不读() {
        let r = Rig(manifest: typingManifest(context: 10))
        r.client.document = "秘密"
        r.client.isSecureInput = true
        r.type("w")
        #expect(r.channel.queries.last?.context == "")
    }

    @Test func 读不到时用壳在这个输入框里见过的文字() {
        let r = Rig(manifest: typingManifest(context: 10))
        r.client.readable = false
        r.type("wo")
        r.elapse(0.01)
        r.press(.space)
        r.type("w")
        #expect(r.channel.queries.last?.context == "我")
        r.session.focusLost()
        r.press(.escape)
        r.type("w")
        #expect(r.channel.queries.last?.context == "")
    }
}

@Suite struct 大写字母 {
    static let keys = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

    @Test func 开头的大写进组字_后面大小写都收_回车原样上屏() {
        // Shift+字母开头打英文（GitHub），引擎给英文单词候选
        let r = Rig(manifest: typingManifest(keys: Self.keys))
        #expect(r.type("GitHub").allSatisfy { $0 })
        #expect(r.session.isComposing)
        r.press(.enter)
        #expect(r.client.document == "GitHub")
    }

    @Test func 小写开头的组字里按Shift加字母_照旧先上屏再放行() {
        let r = Rig(manifest: typingManifest(keys: Self.keys))
        r.type("wo")
        r.elapse(0.01)
        #expect(r.press(.character("G"), [.shift]) == false)
        #expect(r.client.document == "我")
        #expect(!r.session.isComposing)
    }

    @Test func 引擎没声明大写时_大写照旧直接交给应用() {
        let r = Rig()
        #expect(r.press(.character("G"), [.shift]) == false)
        #expect(!r.session.isComposing)
    }
}

@Suite struct 英文模式与出问题时 {
    @Test func 单按Shift切换英文模式() {
        let r = Rig()
        r.press(.modifierDown(.leftShift))
        r.press(.modifierUp(.leftShift))
        #expect(r.session.english)
        #expect(r.press(.character("w")) == false)
        r.press(.modifierDown(.leftShift))
        r.press(.modifierUp(.leftShift))
        #expect(!r.session.english)
    }

    @Test func Shift加字母不切换() {
        let r = Rig()
        r.press(.modifierDown(.leftShift))
        #expect(r.press(.character("A"), [.shift]) == false)
        r.press(.modifierUp(.leftShift))
        #expect(!r.session.english)
    }

    @Test func 输入中切英文上屏原始字母() {
        let r = Rig()
        r.type("wo")
        r.press(.modifierDown(.rightShift))
        r.press(.modifierUp(.rightShift))
        #expect(r.client.document == "wo")
    }

    @Test func 关掉Shift切换开关() {
        var s = ShellSettings()
        s.shiftToggles = false
        let r = Rig(settings: s)
        r.press(.modifierDown(.leftShift))
        r.press(.modifierUp(.leftShift))
        #expect(!r.session.english)
    }

    @Test func 卡死一秒报告并提示_期间放行_输入串保留() {
        let r = Rig(script: { _ in [] })
        r.type("wo")
        r.elapse(1.1)
        #expect(r.channel.hangs == 1)
        #expect(r.client.view.notice == "引擎没有响应，正在重启")
        #expect(r.client.view.marked == "wo")
        r.press(.enter)
        #expect(r.client.document == "wo")
        #expect(r.press(.character("a")) == false)
    }

    @Test func 第一次用时的提示留到这一段打完() {
        let r = Rig()
        r.session.setFirstUseNotice("从你打的字里学")
        #expect(r.client.view.notice == "从你打的字里学")
        r.type("wo")
        r.elapse(0.01)
        #expect(r.client.view.candidates.first?.text == "我")
        #expect(r.client.view.notice == "从你打的字里学")
        r.press(.space)
        #expect(r.client.document == "我")
        #expect(r.client.view.notice == nil)
    }

    @Test func 第一次用时的提示打完一段才算提示过_没打字切走不算() {
        let r = Rig()
        var seen = 0
        r.session.onFirstUseNoticeSeen = { seen += 1 }
        r.session.setFirstUseNotice("从你打的字里学")
        r.session.focusLost()
        r.session.cancelComposition()
        #expect(seen == 0)
        r.session.setFirstUseNotice("从你打的字里学") // 下次进输入框宿主再给
        r.type("wo")
        r.elapse(0.01)
        #expect(seen == 0)
        r.press(.space)
        #expect(seen == 1)
        r.type("wo")
        r.elapse(0.01)
        r.press(.space)
        #expect(seen == 1)
    }

    @Test func 第一次用时的提示切走再回来还在() {
        let r = Rig()
        r.session.setFirstUseNotice("从你打的字里学")
        r.session.focusLost()
        r.type("wo")
        r.elapse(0.01)
        #expect(r.client.view.notice == "从你打的字里学")
    }

    @Test func 引擎重新启动后重新询问() {
        let r = Rig(script: { _ in [] })
        r.type("wo")
        r.elapse(1.1)
        r.channel.script = tableScript(["wo": ["我"]])
        r.channel.available = true
        r.session.engineDidStart()
        r.elapse(0.01)
        #expect(r.client.view.notice == nil)
        #expect(r.client.view.candidates.first?.text == "我")
    }

    @Test func 没有引擎时全部放行() {
        let r = Rig()
        r.channel.available = false
        #expect(r.press(.character("w")) == false)
        #expect(r.press(.character(",")) == false)
    }
}

@Suite struct 快捷键引擎 {
    static func rig(mode: Manifest.Hotkey.Mode, arm: Bool = false, microphone: Bool = false) -> (Rig, FakeChannel) {
        let r = Rig()
        let ch = FakeChannel(clock: r.clock)
        var hotkey = Manifest.Hotkey(key: .rightCommand, mode: mode)
        hotkey.arm = arm
        var perms = Manifest.Permissions()
        perms.microphone = microphone
        let m = Manifest(protocolVersion: 1, name: "语音", kind: .hotkey, run: ["x"], inputKeys: [], punctuation: .default,
                         context: 0, app: false, feedback: false, hotkey: hotkey,
                         permissions: perms, options: nil)
        r.session.hotkeys = [HotkeyEngine(manifest: m, channel: ch)]
        return (r, ch)
    }

    @Test func 按住触发_推送显示串_松开停止_引擎上屏() {
        let (r, ch) = Self.rig(mode: .hold)
        r.press(.modifierDown(.rightCommand))
        r.elapse(0.2)
        guard case let .start(id, _, _)? = ch.sent.first else { Issue.record("没有发 start"); return }
        ch.push(.show(id: id, text: "今天"))
        r.elapse(0.01)
        #expect(r.client.view.marked == "今天")
        r.press(.modifierUp(.rightCommand))
        #expect(ch.sent.last == .stop(id: id))
        ch.push(.commit(id: id, text: "今天开会。"), after: 0.3)
        r.elapse(0.5)
        #expect(r.client.document == "今天开会。")
        #expect(!r.session.isInHotkeySession)
    }

    @Test func 按住不够久或期间按了别的键不触发() {
        let (r, ch) = Self.rig(mode: .hold)
        r.press(.modifierDown(.rightCommand))
        r.elapse(0.05)
        r.press(.modifierUp(.rightCommand))
        r.press(.modifierDown(.rightCommand))
        r.press(.character("c"), [.command])
        r.elapse(0.3)
        #expect(ch.sent.isEmpty)
    }

    @Test func Esc取消什么都不上屏() {
        let (r, ch) = Self.rig(mode: .press)
        r.press(.modifierDown(.rightCommand))
        r.press(.modifierUp(.rightCommand))
        guard case let .start(id, _, _)? = ch.sent.first else { Issue.record("没有发 start"); return }
        ch.push(.show(id: id, text: "半句"))
        r.elapse(0.01)
        r.press(.escape)
        #expect(ch.sent.last == .cancel(id: id, reason: .esc))
        #expect(r.client.document == "")
    }

    @Test func 按别的键先上屏已有文字再处理这个键() {
        let (r, ch) = Self.rig(mode: .press)
        r.press(.modifierDown(.rightCommand))
        r.press(.modifierUp(.rightCommand))
        guard case let .start(id, _, _)? = ch.sent.first else { Issue.record("没有发 start"); return }
        ch.push(.show(id: id, text: "半句"))
        r.elapse(0.01)
        r.type(",")
        #expect(r.client.document == "半句，")
        #expect(ch.sent.contains(.cancel(id: id, reason: .key)))
    }

    @Test func 触发时正在输入就先收尾上屏() {
        let (r, ch) = Self.rig(mode: .press)
        r.type("wo")
        r.elapse(0.01)
        r.press(.modifierDown(.rightCommand))
        r.press(.modifierUp(.rightCommand))
        #expect(r.client.document == "我")
        #expect(r.session.isInHotkeySession)
        _ = ch
    }

    @Test func 声明了arm的按下就发arm_确认按住后用同一个号发start() {
        let (r, ch) = Self.rig(mode: .hold, arm: true)
        r.press(.modifierDown(.rightCommand))
        guard case let .arm(id)? = ch.sent.first else { Issue.record("按下没有发 arm"); return }
        r.elapse(0.2)
        #expect(ch.sent.count == 2)
        guard case let .start(sid, _, _)? = ch.sent.last else { Issue.record("没有发 start"); return }
        #expect(sid == id)
        r.press(.modifierUp(.rightCommand))
        #expect(ch.sent.last == .stop(id: id))
    }

    @Test func 发了arm_没按够就松开或按了组合键_取消() {
        let (r, ch) = Self.rig(mode: .hold, arm: true)
        r.press(.modifierDown(.rightCommand))
        r.elapse(0.05)
        r.press(.modifierUp(.rightCommand))
        guard case let .arm(a)? = ch.sent.first else { Issue.record("没有发 arm"); return }
        #expect(ch.sent.last == .cancel(id: a, reason: .short))
        r.press(.modifierDown(.rightCommand))
        guard case let .arm(b)? = ch.sent.last else { Issue.record("第二次没有发 arm"); return }
        r.press(.character("c"), [.command])
        #expect(ch.sent.last == .cancel(id: b, reason: .key))
        r.elapse(0.3)
        #expect(!ch.sent.contains { if case .start = $0 { return true } else { return false } })
    }

    @Test func 同一次按下来了两个按下事件_只发一个arm() {
        let (r, ch) = Self.rig(mode: .hold, arm: true)
        r.press(.modifierDown(.rightCommand))
        r.elapse(0.07)
        r.press(.modifierDown(.rightCommand))
        #expect(ch.sent.count == 1)
        guard case let .arm(id)? = ch.sent.first else { Issue.record("没有发 arm"); return }
        r.elapse(0.2)
        guard case let .start(sid, _, _)? = ch.sent.last else { Issue.record("没有发 start"); return }
        #expect(sid == id)
    }

    @Test func 密码框里不触发_也不发arm() {
        let (r, ch) = Self.rig(mode: .hold, arm: true)
        r.client.isSecureInput = true
        r.press(.modifierDown(.rightCommand))
        r.elapse(0.3)
        r.press(.modifierUp(.rightCommand))
        #expect(ch.sent.isEmpty)
        #expect(!r.session.isInHotkeySession)
    }

    @Test func 用麦克风的按住时一直提示正在听_松开后显示整理中() {
        let (r, ch) = Self.rig(mode: .hold, arm: true, microphone: true)
        r.press(.modifierDown(.rightCommand))
        r.elapse(0.2)
        #expect(r.client.view.notice == "录音中")
        #expect(r.client.view.voice == .listening)
        guard case let .start(id, _, _)? = ch.sent.last else { Issue.record("没有发 start"); return }
        ch.push(.show(id: id, text: "今天"))
        r.elapse(0.01)
        #expect(r.client.view.notice == "录音中") // 出了草稿也一直提示
        r.press(.modifierUp(.rightCommand))
        #expect(r.client.view.notice == "整理中…")
        #expect(r.client.view.voice == .working)
        ch.push(.commit(id: id, text: "今天开会。"), after: 0.3)
        r.elapse(0.5)
        #expect(r.client.view.notice == nil)
        #expect(r.client.view.voice == nil)
        #expect(r.client.document == "今天开会。")
    }

    @Test func 开了中英文加空格_一整句里面的交界也加() {
        for on in [true, false] {
            let (r, ch) = Self.rig(mode: .hold, arm: true, microphone: true)
            r.session.settings.autoSpace = on
            r.press(.modifierDown(.rightCommand))
            r.elapse(0.2)
            guard case let .start(id, _, _)? = ch.sent.last else { Issue.record("没有发 start"); return }
            ch.push(.show(id: id, text: "把PR发到GitHub上"))
            r.elapse(0.01)
            #expect(r.client.view.marked == (on ? "把 PR 发到 GitHub 上" : "把PR发到GitHub上"))
            r.press(.modifierUp(.rightCommand))
            ch.push(.commit(id: id, text: "把PR发到GitHub上，3点开会。"), after: 0.1)
            r.elapse(0.3)
            #expect(r.client.document == (on ? "把 PR 发到 GitHub 上，3 点开会。" : "把PR发到GitHub上，3点开会。"))
        }
    }

    @Test func 引擎给了提示就显示它() {
        let (r, ch) = Self.rig(mode: .hold, arm: true, microphone: true)
        r.press(.modifierDown(.rightCommand))
        r.elapse(0.2)
        guard case let .start(id, _, _)? = ch.sent.last else { Issue.record("没有发 start"); return }
        r.press(.modifierUp(.rightCommand))
        #expect(r.client.view.notice == "整理中…")
        ch.push(.show(id: id, text: "我们周四见面", hint: "音量过低，未识别到语音"))
        r.elapse(0.01)
        #expect(r.client.view.notice == "音量过低，未识别到语音")
    }

    @Test func 话筒还没开始收音时显示准备中_开始收音后变成正在听() {
        let (r, ch) = Self.rig(mode: .hold, arm: true, microphone: true)
        r.press(.modifierDown(.rightCommand))
        r.elapse(0.2)
        guard case let .start(id, _, _)? = ch.sent.last else { Issue.record("没有发 start"); return }
        #expect(r.client.view.voice == .listening) // 引擎没说，照在听算
        ch.push(.show(id: id, text: "", listening: false))
        r.elapse(0.01)
        #expect(r.client.view.voice == .preparing && r.client.view.notice == "准备中…")
        ch.push(.show(id: id, text: "", listening: true))
        r.elapse(0.01)
        #expect(r.client.view.voice == .listening && r.client.view.notice == "录音中")
        ch.push(.show(id: id, text: "", listening: false))
        r.elapse(0.01)
        r.press(.modifierUp(.rightCommand))
        #expect(r.client.view.voice == .working && r.client.view.notice == "整理中…") // 松开了就不再是准备中
    }

    @Test func 在听时画引擎报的音量_松开后不画() {
        let (r, ch) = Self.rig(mode: .hold, arm: true, microphone: true)
        r.press(.modifierDown(.rightCommand))
        r.elapse(0.2)
        guard case let .start(id, _, _)? = ch.sent.last else { Issue.record("没有发 start"); return }
        #expect(r.client.view.voiceLevel == nil, "没报过音量：照旧画红点")
        ch.push(.level(id: id, level: 0.6))
        r.elapse(0.01)
        #expect(r.client.view.voice == .listening && r.client.view.voiceLevel == 0.6)
        ch.push(.level(id: id + 1, level: 0.9)) // 别的会话的：不要
        r.elapse(0.01)
        #expect(r.client.view.voiceLevel == 0.6)
        r.press(.modifierUp(.rightCommand))
        #expect(r.client.view.voice == .working && r.client.view.voiceLevel == nil)
    }

    @Test func 停止后迟迟没有结果按超时结束() {
        let (r, ch) = Self.rig(mode: .press)
        r.press(.modifierDown(.rightCommand))
        r.press(.modifierUp(.rightCommand))
        guard case let .start(id, _, _)? = ch.sent.first else { Issue.record("没有发 start"); return }
        ch.push(.show(id: id, text: "说了一半"))
        r.elapse(0.01)
        r.press(.modifierDown(.rightCommand))
        r.press(.modifierUp(.rightCommand))
        r.elapse(11)
        #expect(ch.sent.last == .cancel(id: id, reason: .timeout))
        #expect(r.client.document == "说了一半")
    }
}

/// 代码审查发现的问题，修好后的回归测试。
@Suite struct 审查回归 {
    @Test func 按住快捷键期间引擎自己结束了会话_不会再自动开始() {
        let (r, ch) = 快捷键引擎.rig(mode: .hold)
        r.press(.modifierDown(.rightCommand))
        r.elapse(0.2)
        guard case let .start(id, _, _)? = ch.sent.first else { Issue.record("没有发 start"); return }
        ch.push(.end(id: id))
        r.elapse(0.5) // 仍然按着
        #expect(ch.sent.filter { if case .start = $0 { return true } else { return false } }.count == 1)
        r.press(.modifierUp(.rightCommand))
        #expect(!ch.sent.contains { if case .stop = $0 { return true } else { return false } })
    }

    @Test func 快捷键引擎上屏后的退格不算打字引擎的() {
        let (r, ch) = 快捷键引擎.rig(mode: .press)
        r.type("wo")
        r.elapse(0.01)
        r.press(.space) // 上屏"我"
        r.press(.modifierDown(.rightCommand))
        r.press(.modifierUp(.rightCommand))
        guard case let .start(id, _, _)? = ch.sent.first else { Issue.record("没有发 start"); return }
        ch.push(.commit(id: id, text: "今天开会"))
        r.elapse(0.01)
        r.press(.backspace)
        r.press(.backspace)
        r.type("x")
        #expect(!r.channel.sent.contains { if case .deleted = $0 { return true } else { return false } })
    }

    @Test func 候选还没画出来时按数字不会选中没见过的候选() {
        let r = Rig(script: { m in
            guard case let .query(id, input, _, _) = m else { return [] }
            let cands = input.count == 1 ? [Candidate(text: "好a", consume: 1)] : [Candidate(text: "甲ab", consume: 2), Candidate(text: "乙ab", consume: 2)]
            return [(0.002, .answer(Answer(id: id, candidates: cands, more: input.count > 1)))]
        })
        r.type("a")
        r.elapse(0.01)
        r.type("b")
        r.elapse(0.01) // 快的答复到了但标了 more，还没画；屏幕上仍是上一份 [好a]
        #expect(r.client.view.candidates.map(\.text) == ["好a"])
        r.type("2")
        #expect(r.client.document == "")                              // 没有上屏没见过的"乙ab"
        #expect(r.client.view.candidates.map(\.text) == ["甲ab", "乙ab"]) // 而是先画出来
        r.type("2")
        #expect(r.client.document == "乙ab")
    }

    @Test func 还没有答复时按数字会等答复再选() {
        let r = Rig(script: tableScript(["ab": ["甲", "乙"]], delay: 0.03))
        r.type("ab")
        r.type("2") // 答复 30 ms 后才到
        #expect(r.client.document == "乙")
    }

    @Test func 快打时显示串接着上一次的临时显示串() {
        let r = Rig(script: { m in
            guard case let .query(id, input, _, _) = m else { return [] }
            return [(0.05, .answer(Answer(id: id, display: "wo bu", candidates: [Candidate(text: "我不", consume: input.count)])))]
        })
        r.type("wobu")
        r.elapse(0.06)
        #expect(r.client.view.marked == "wo bu")
        r.type("z")
        #expect(r.client.view.marked == "wo buz")
        r.type("d")
        #expect(r.client.view.marked == "wo buzd")
    }

    @Test func 引擎不在时输入串保留_输入键接上_ShiftBackspace不放行() {
        let r = Rig(script: { _ in [] })
        r.type("wo")
        r.elapse(1.1) // 卡死，引擎不可用
        #expect(r.press(.character("b")) == true)
        #expect(r.press(.backspace, [.shift]) == true)
        #expect(r.client.view.marked == "wob")
        r.channel.script = tableScript(["wob": ["我不"]])
        r.channel.available = true
        r.session.engineDidStart()
        r.elapse(0.01)
        #expect(r.channel.queries.last?.input == "wob")
        #expect(r.client.view.candidates.first?.text == "我不")
    }

    @Test func 每页个数为零也不会崩() {
        var s = ShellSettings()
        s.pageSize = 0
        let r = Rig(settings: s)
        r.type("wo")
        r.elapse(0.01)
        #expect(r.client.view.candidates.count == 1)
        r.type("=")
        r.type("1")
        #expect(r.client.document == "窝")
    }
}

@Suite struct 协议与引擎说明 {
    @Test func 字段为null当作没写() throws {
        let m = try EngineMessage.parse(#"{"type":"answer","id":3,"display":null,"more":null,"autocommit":null,"candidates":[{"text":"好","consume":1,"note":null}]}"#)
        #expect(m == .answer(Answer(id: 3, candidates: [Candidate(text: "好", consume: 1)])))
    }

    @Test func 音量消息_超出范围的夹到0到1_不是数的报错() throws {
        #expect(try EngineMessage.parse(#"{"type":"level","id":3,"level":0.25}"#) == .level(id: 3, level: 0.25))
        #expect(try EngineMessage.parse(#"{"type":"level","id":3,"level":7}"#) == .level(id: 3, level: 1))
        #expect(try EngineMessage.parse(#"{"type":"level","id":3,"level":-1}"#) == .level(id: 3, level: 0))
        #expect(throws: ProtocolError.self) { try EngineMessage.parse(#"{"type":"level","id":3,"level":true}"#) }
        #expect(throws: ProtocolError.self) { try EngineMessage.parse(#"{"type":"level","id":3}"#) }
    }

    @Test func 不认识的类型() throws {
        #expect(try EngineMessage.parse(#"{"type":"log","text":"x"}"#) == .unknown(type: "log"))
    }

    @Test func 格式错误给出说明() {
        #expect(throws: ProtocolError.self) { try EngineMessage.parse("starting up...") }
        #expect(throws: ProtocolError.self) { try EngineMessage.parse(#"{"type":"answer","id":1,"candidates":[{"text":"x","consume":"2"}]}"#) }
    }

    static func manifest(_ extra: String) -> Data {
        Data(#"{"protocol":1,"name":"x","kind":"typing","run":["x"],"input_keys":"ab"\#(extra)}"#.utf8)
    }

    @Test(arguments: [#","permissions":{"write":["."]}"#, #","permissions":{"write":["~"]}"#,
                      #","permissions":{"write":["~/.luoke"]}"#, #","permissions":{"write":["~/.luoke/ime/engines/x"]}"#,
                      #","context":5000"#, #","punctuation":{",":3}"#, #","context":true"#,
                      #","permissions":{"network":"local","local_ports":[true]}"#, #","permissions":{"local_ports":[8080]}"#])
    func 不合法的引擎说明(extra: String) {
        #expect(throws: ManifestError.self) { try Manifest.parse(Self.manifest(extra)) }
    }

    @Test func 读写记忆的同意存在设置里() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var c = ShellConfig()
        c.memoryConsent = ["personal"]
        c.memoryAsked = ["personal", "other"]
        try c.save(url)
        let back = ShellConfig.load(url)
        #expect(back.memoryConsent == ["personal"])
        #expect(back.memoryAsked == ["personal", "other"])
        #expect(ShellConfig().memoryConsent.isEmpty) // 默认没同意
    }

    @Test func 快捷键的arm只用于hold() throws {
        let hotkey = { (h: String) in Data(#"{"protocol":1,"name":"x","kind":"hotkey","run":["x"],"hotkey":\#(h)}"#.utf8) }
        #expect(try Manifest.parse(hotkey(#"{"key":"right_option","mode":"hold","arm":true}"#)).hotkey?.arm == true)
        #expect(try Manifest.parse(hotkey(#"{"key":"right_option","mode":"hold"}"#)).hotkey?.arm == false)
        #expect(throws: ManifestError.self) { try Manifest.parse(hotkey(#"{"key":"right_option","mode":"press","arm":true}"#)) }
        #expect(throws: ManifestError.self) { try Manifest.parse(hotkey(#"{"key":"right_option","mode":"hold","arm":1}"#)) }
    }

    @Test func 合法的额外可写位置() throws {
        let m = try Manifest.parse(Self.manifest(#","permissions":{"write":["~/Documents/notes"],"network":"local"}"#))
        #expect(m.permissions.write == ["~/Documents/notes"])
        #expect(m.permissions.network == .local)
    }
}

/// review 里发现的状态机问题。
@Suite struct 状态机的漏洞 {
    @Test func 按住别的修饰键时单按Shift不切换() {
        let r = Rig()
        r.press(.modifierDown(.leftCommand), [.command])
        r.press(.modifierDown(.leftShift), [.command, .shift])
        r.press(.modifierUp(.leftShift), [.command])
        r.press(.modifierUp(.leftCommand))
        #expect(!r.session.english)
        // 先按住 Shift，中间按了一下 ⌘
        r.press(.modifierDown(.leftShift), [.shift])
        r.press(.modifierDown(.leftCommand), [.shift, .command])
        r.press(.modifierUp(.leftCommand), [.shift])
        r.press(.modifierUp(.leftShift))
        #expect(!r.session.english)
        // 真的单按仍然切换
        r.press(.modifierDown(.leftShift), [.shift])
        r.press(.modifierUp(.leftShift))
        #expect(r.session.english)
    }

    @Test func Shift加鼠标点击不切换() {
        let r = Rig()
        r.press(.modifierDown(.leftShift), [.shift])
        r.session.pointerPressed()
        r.press(.modifierUp(.leftShift))
        #expect(!r.session.english)
    }

    @Test func 没有打字引擎时上屏不吞字() {
        let r = Rig()
        r.type("wo")
        r.elapse(0.01)
        r.session.typing = nil // 比如引擎说明刚被改坏
        r.press(.enter)
        #expect(r.client.document == "wo")
    }

    @Test func 等过补发后按数字照常选词() {
        let r = Rig(script: { m in
            guard case let .query(id, input, _, _) = m else { return [] }
            let c = [Candidate(text: "甲", consume: input.count), Candidate(text: "乙", consume: input.count)]
            return [(0.002, .answer(Answer(id: id, candidates: c, more: true))), (0.3, .answer(Answer(id: id, candidates: c)))]
        })
        r.type("ab")
        r.type("2") // 快的答复还没到：等到它，再等补发到 150 ms；那时已过了 50 ms 的画出时刻
        #expect(r.client.document == "乙")
    }

    @Test func 带修饰键的退格结束上屏后的退格计数() {
        let r = Rig()
        r.type("wo")
        r.elapse(0.01)
        r.press(.space)
        r.press(.backspace)
        r.press(.backspace, [.option])
        #expect(r.channel.sent.contains { if case .deleted(_, 1, _) = $0 { return true } else { return false } })
    }

    @Test func 系统取消组字时丢弃() {
        let r = Rig()
        r.type("wo")
        r.elapse(0.01)
        r.session.cancelComposition()
        #expect(!r.session.isComposing)
        #expect(r.client.document == "")
    }
}

@Suite struct 先快后好的提示 {
    static func script(final: TimeInterval) -> (ShellMessage) -> [(TimeInterval, EngineMessage)] {
        { m in
            guard case let .query(id, input, _, _) = m else { return [] }
            let c = [Candidate(text: "甲", consume: input.count), Candidate(text: "乙", consume: input.count)]
            return [(0.002, .answer(Answer(id: id, candidates: c, more: true))),
                    (final, .answer(Answer(id: id, candidates: [Candidate(text: "丙", consume: input.count)] + c)))]
        }
    }

    @Test func 等补发时标出还在算_补发到了就不标() {
        let r = Rig(script: Self.script(final: 0.3))
        r.type("ab")
        r.elapse(0.06) // 过了 50 ms 先画快的
        #expect(r.client.view.candidates.first?.text == "甲")
        #expect(r.client.view.pending)
        r.elapse(0.3)
        #expect(r.client.view.candidates.first?.text == "丙")
        #expect(!r.client.view.pending)
    }

    @Test func 只有补发换掉了已经看到的首选才淡入_敲新键不算() {
        let r = Rig(script: Self.script(final: 0.3))
        r.type("ab")
        r.elapse(0.06) // 画出快的"甲"
        r.elapse(0.3)  // 补发"丙"换掉了已经看到的"甲"：淡入一次
        #expect(r.client.views.filter(\.topReplaced).count == 1)
        r.type("c")    // 新键：屏幕上先留着"丙"，新询问的快答复"甲"画出来时首选变了，但这不是补发
        r.elapse(0.06)
        #expect(r.client.view.candidates.first?.text == "甲")
        #expect(r.client.views.filter(\.topReplaced).count == 1)
        r.elapse(0.3)  // 这一次的补发又换掉了"甲"
        #expect(r.client.views.filter(\.topReplaced).count == 2)
    }

    @Test func 连续打字时还在算的提示不在键之间消失() {
        let r = Rig(script: Self.script(final: 0.3))
        r.type("ab")
        r.elapse(0.06)
        #expect(r.client.view.pending)
        r.type("c") // 新答复还没到：沿用上一份的提示
        #expect(r.client.view.pending)
    }

    @Test func 移动了高亮就不再提示() {
        let r = Rig(script: Self.script(final: 0.3))
        r.type("ab")
        r.elapse(0.06)
        r.press(.right)
        #expect(!r.client.view.pending) // 不会再换了
    }
}

@Suite struct 中英文之间加空格 {
    static func rig() -> Rig {
        var s = ShellSettings()
        s.autoSpace = true
        return Rig(settings: s, script: tableScript(["wo": ["我", "窝"], "hello": ["hello"]]))
    }

    static func toggleEnglish(_ r: Rig) {
        r.press(.modifierDown(.leftShift), [.shift])
        r.press(.modifierUp(.leftShift))
    }

    @Test func 字母后面上屏汉字_汉字后面上屏字母都补空格() {
        let r = Self.rig()
        r.client.document = "iPhone"
        r.type("wo")
        r.elapse(0.01)
        r.press(.space)
        #expect(r.client.document == "iPhone 我")
        r.type("hello")
        r.elapse(0.01)
        r.press(.space)
        #expect(r.client.document == "iPhone 我 hello")
        r.type("wo")
        r.press(.enter) // 原始字母上屏
        #expect(r.client.document == "iPhone 我 hellowo")
    }

    @Test func 反馈里的上屏文字不含自动加的空格() {
        let r = Self.rig()
        r.client.document = "abc"
        r.type("wo")
        r.elapse(0.01)
        r.press(.space)
        #expect(r.client.document == "abc 我")
        let c = r.channel.sent.compactMap { if case let .committed(c) = $0 { return c } else { return nil } }.first
        #expect(c?.text == "我")
    }

    @Test func 汉字后面直接敲字母或数字_壳补上空格() {
        let r = Self.rig()
        r.type("wo")
        r.elapse(0.01)
        r.press(.space)
        #expect(r.session.handle(.char("3"))) // 中文模式下的数字
        #expect(r.client.document == "我 3")
        let r2 = Self.rig()
        r2.type("wo")
        r2.elapse(0.01)
        r2.press(.space)
        Self.toggleEnglish(r2)
        #expect(r2.session.english)
        #expect(r2.session.handle(.char("C")))  // 第一个字母：补空格，由壳上屏
        #expect(!r2.session.handle(.char("l"))) // 之后照常放行
        #expect(r2.client.document == "我 C")
    }

    @Test func 标点和空格旁不加() {
        let r = Self.rig()
        r.type("wo")
        r.elapse(0.01)
        r.press(.space)
        r.type(",")
        Self.toggleEnglish(r)
        #expect(!r.session.handle(.char("a")))
        #expect(r.client.document == "我，")
    }

    @Test func 删掉自动加的空格后紧接着那一下不再加() {
        let r = Self.rig()
        r.type("wo")
        r.elapse(0.01)
        r.press(.space)
        Self.toggleEnglish(r)
        #expect(r.session.handle(.char("a")))
        r.press(.backspace) // 删 a
        r.press(.backspace) // 删自动加的空格
        #expect(!r.session.handle(.char("a")))  // 这一下照用户的意思，不加
        r.press(.backspace)
        #expect(r.session.handle(.char("a")))   // 之后照常
    }

    @Test func 放行的键只信壳自己记得的前文() {
        let r = Self.rig()
        r.client.document = "中文" // 读得到，但不是壳上屏的（比如终端里的 vim）
        Self.toggleEnglish(r)
        #expect(!r.session.handle(.char("d")))
    }

    @Test func 开关关着什么都不加() {
        let r = Rig()
        r.client.document = "iPhone"
        r.type("wo")
        r.elapse(0.01)
        r.press(.space)
        r.session.handle(.char("3"))
        #expect(r.client.document == "iPhone我")
    }
}

@Suite struct 联想 {
    /// 装好个人化组件和联想的假宿主：记下问了什么，答复由测试给。
    final class Predictor {
        var asked: [(id: Int, context: String)] = []
    }

    /// delay：上屏后停多久才问；默认 0（下面这些用例只看问出去以后的事）。
    static func rig(predict: Bool = true, delay: TimeInterval = 0) -> (Rig, Predictor, FakeChannel) {
        var s = ShellSettings()
        s.predict = predict
        var t = Timing()
        t.predictDelay = delay
        let r = Rig(settings: s, timing: t)
        let p = FakeChannel(clock: r.clock)
        r.session.personal = PersonalEngine(manifest: 上屏转给个人化组件.personalManifest(context: 20), channel: p)
        let pr = Predictor()
        r.session.predictor = { id, ctx, _ in pr.asked.append((id, ctx)) }
        return (r, pr, p)
    }

    static func commitWo(_ r: Rig) {
        r.type("wo")
        r.elapse(0.01)
        r.press(.space)
    }

    @Test func 选定候选上屏后问联想_有就提示_Tab打开_数字选() {
        let (r, pr, p) = Self.rig()
        r.client.document = "今天"
        Self.commitWo(r)
        #expect(pr.asked.map(\.context) == ["今天我"])
        r.session.receivePredictions(id: pr.asked[0].id, items: ["们", "觉得"])
        // 直接展示、不高亮、不放显示串；按 Tab 才能选
        #expect(r.client.view.predictHint)
        #expect(r.client.view.candidates.map(\.text) == ["们", "觉得"])
        #expect(r.client.view.highlighted == nil)
        #expect(r.client.view.marked.isEmpty)
        #expect(r.press(.tab))
        #expect(r.client.view.predicting)
        #expect(r.client.view.candidates.map(\.text) == ["们", "觉得"])
        #expect(r.client.view.marked == "们") // 高亮的联想放在光标处：Chromium 里 Tab 才不会再交给网页
        r.press(.right)
        #expect(r.client.view.marked == "觉得")
        r.press(.left)
        #expect(r.press(.character("2")))
        #expect(r.client.document == "今天我觉得")
        #expect(!r.client.view.predicting)
        // 选了联想也算一次上屏，转给个人化组件；接着再问
        let kinds = p.sent.compactMap { if case let .committed(c) = $0 { return c.kind } else { return nil } }
        #expect(kinds == [.typing, .predict])
        #expect(pr.asked.last?.context == "今天我觉得")
    }

    @Test func 使用计数_只记次数_密码框和禁止记录时不记() {
        let (r, pr, _) = Self.rig()
        let usage = Usage(url: nil)
        r.session.usage = usage
        Self.commitWo(r)
        r.session.receivePredictions(id: pr.asked[0].id, items: ["们", "觉得"])
        r.press(.tab)
        r.press(.character("2"))
        r.press(.backspace)
        r.press(.backspace)  // 同一次上屏后的退格只算一次
        let t = usage.total(lastDays: 1)
        #expect(t == [.commit: 1, .pickFirst: 1, .predictShown: 1, .predictOpened: 1, .predictPicked: 1, .predictChars: 2, .backspaceAfterCommit: 1])
        r.type("x")
        r.client.mayRecord = false
        Self.commitWo(r)
        r.client.mayRecord = true
        r.client.isSecureInput = true
        Self.commitWo(r)
        #expect(usage.total(lastDays: 1)[.commit] == 1)
    }

    @Test func 上屏后停够了才问_期间接着打就不问() {
        // 快打时接连上屏的短词不一个个去问
        let (r, pr, _) = Self.rig(delay: 0.25)
        r.client.document = "今天"
        Self.commitWo(r)
        #expect(pr.asked.isEmpty)
        r.elapse(0.1)
        r.type("bu") // 0.25 秒内接着打：这一次不问
        r.elapse(0.01)
        r.press(.space)
        #expect(pr.asked.isEmpty)
        r.elapse(0.24)
        #expect(pr.asked.isEmpty)
        r.elapse(0.02)
        #expect(pr.asked.map(\.context) == ["今天我不"])
        // 从问出去算 predictWait：停的那 0.25 秒不算进去
        r.elapse(r.session.timing.predictWait - 0.1)
        r.session.receivePredictions(id: pr.asked[0].id, items: ["是"])
        #expect(r.client.view.predictHint)
    }

    @Test func 还没问出去时Tab照常交给应用_来的答复也不要() {
        let (r, pr, _) = Self.rig(delay: 0.25)
        Self.commitWo(r)
        #expect(!r.press(.tab))
        r.session.receivePredictions(id: 1, items: ["们"])
        #expect(!r.client.view.predictHint)
        r.elapse(0.3)
        #expect(pr.asked.isEmpty) // 按过 Tab：这一次不问了
    }

    @Test func 应用自己又插了制表符_选联想时连它一起换掉() {
        // Grok（Electron）：输入法接下了打开联想的 Tab，应用照样插了个制表符
        let (r, pr, _) = Self.rig()
        r.client.supportsReplace = true
        r.client.document = "祝你"
        Self.commitWo(r)
        r.session.receivePredictions(id: pr.asked[0].id, items: ["们", "觉得"])
        #expect(r.press(.tab))
        r.client.document += "\t" // 应用自己插的
        r.press(.space)
        #expect(r.client.document == "祝你我们")
    }

    @Test func 应用自己又插了制表符_收起联想时宿主可以不动_没插就照旧() {
        let (r, pr, _) = Self.rig()
        r.client.supportsReplace = true
        Self.commitWo(r)
        r.session.receivePredictions(id: pr.asked[0].id, items: ["们"])
        r.press(.tab)
        r.client.document += "\t"
        r.press(.escape)
        #expect(r.client.document == "我\t") // 收起时不去掉（宿主那边做不可靠），按一下退格就行
        // 没插制表符的应用：照旧
        r.client.document = ""
        Self.commitWo(r)
        r.session.receivePredictions(id: pr.asked.last!.id, items: ["们"])
        r.press(.tab)
        r.press(.space)
        #expect(r.client.document == "我们")
    }

    @Test func 提示亮着时按别的键_提示收起_这个键照常处理() {
        let (r, pr, _) = Self.rig()
        Self.commitWo(r)
        r.session.receivePredictions(id: pr.asked[0].id, items: ["们"])
        #expect(r.client.view.predictHint)
        r.type("bu")
        #expect(!r.client.view.predictHint)
        #expect(r.session.isComposing)
    }

    @Test func 没有提示时Tab照常交给应用() {
        let (r, _, _) = Self.rig()
        Self.commitWo(r)
        #expect(!r.press(.tab))
    }

    @Test func 打开后空格选高亮的_Esc收起不上屏() {
        let (r, pr, _) = Self.rig()
        Self.commitWo(r)
        r.session.receivePredictions(id: pr.asked[0].id, items: ["们", "觉得"])
        r.press(.tab)
        r.press(.right)
        r.press(.space)
        #expect(r.client.document == "我觉得")
        r.session.receivePredictions(id: pr.asked.last!.id, items: ["很好"])
        r.press(.tab)
        #expect(r.press(.escape))
        #expect(r.client.document == "我觉得")
        #expect(!r.client.view.predicting && !r.client.view.predictHint)
        #expect(r.client.view.marked.isEmpty)
        // 回车、退格也只收起，不交给应用
        r.type("wo")
        r.elapse(0.01)
        r.press(.space)
        r.session.receivePredictions(id: pr.asked.last!.id, items: ["们"])
        r.press(.tab)
        #expect(r.press(.enter))
        #expect(r.client.document == "我觉得我")
        #expect(!r.client.view.predicting)
    }

    @Test func 提示过一会儿自己收起_来晚的答复不要() {
        let (r, pr, _) = Self.rig()
        Self.commitWo(r)
        r.session.receivePredictions(id: pr.asked[0].id, items: ["们"])
        r.elapse(r.session.timing.predictHint + 0.1)
        #expect(!r.client.view.predictHint)
        #expect(!r.press(.tab))
        Self.commitWo(r)
        r.elapse(r.session.timing.predictWait + 0.1)
        r.session.receivePredictions(id: pr.asked.last!.id, items: ["们"])
        #expect(!r.client.view.predictHint)
    }

    @Test func 回车上屏字母_关了联想_安全输入时都不问() {
        let (r, pr, _) = Self.rig()
        r.type("wo")
        r.press(.enter)
        #expect(pr.asked.isEmpty)
        let (r2, pr2, _) = Self.rig(predict: false)
        Self.commitWo(r2)
        #expect(pr2.asked.isEmpty)
        let (r3, pr3, _) = Self.rig()
        r3.client.isSecureInput = true
        Self.commitWo(r3)
        #expect(pr3.asked.isEmpty)
        let (r4, pr4, _) = Self.rig()
        r4.client.mayPredict = false // 这个应用设了"不联想"
        Self.commitWo(r4)
        #expect(pr4.asked.isEmpty)
    }

    @Test func 标点上屏后也问() {
        let (r, pr, _) = Self.rig()
        Self.commitWo(r)
        r.type(",")
        #expect(pr.asked.last?.context == "我，")
    }
}
