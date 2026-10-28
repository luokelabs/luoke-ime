import Foundation

/// 状态机看到的引擎：一条只属于本会话的通道。真实实现见 EngineHost；测试用假的。
public protocol EngineChannel: AnyObject {
    /// 引擎在运行、能答复。为 false 时壳放行按键（等同英文模式）。
    var isAvailable: Bool { get }
    /// 新的询问 / 会话 / 上屏序号，在同一个引擎进程里唯一。
    func nextID() -> Int
    func send(_ message: ShellMessage)
    /// 取出已收到、属于本会话的消息，不阻塞。
    func drain() -> [EngineMessage]
    /// 阻塞到有新消息或到达 `deadline`（时钟时间）。
    func wait(until deadline: TimeInterval)
    /// 一次询问超时没有任何答复：请宿主重启引擎。
    func reportHang()
}

/// 壳所服务的那个输入框，加上画面。macOS 外壳和命令行版各自实现。
public protocol SessionClient: AnyObject {
    /// 光标前最多 `limit` 个字；应用不提供时返回 nil。
    func textBeforeCursor(limit: Int) -> String?
    var appID: String? { get }
    var isSecureInput: Bool { get }
    /// 用户让不让在这里记：暂停了所有记录、或者这个应用设了"禁止记录"时为 false。
    /// 安全输入（密码框等）时状态机自己就不转，不必在这里算。
    var mayRecord: Bool { get }
    /// 这个应用里要不要联想（应用例外里设了"不联想"时为 false）。
    var mayPredict: Bool { get }
    /// 记忆记录开着（设置「通用」里的"记录输入内容到记忆"）：自带的个人化组件默认开，用户关了才是 false；第三方的要用户另外同意。
    var memoryConsented: Bool { get }
    /// 个人化组件是第三方的（不是随输入法发布的）。
    var personalThirdParty: Bool { get }
    /// 上屏。
    func insert(_ text: String)
    func render(_ view: SessionView)
    /// 光标（没有显示串时）在文档里的位置（UTF-16）；应用不提供时 nil。
    func caretLocation() -> Int?
    /// 有的应用（Grok 这类 Electron 应用）在输入法已经接下打开联想的 Tab 之后，自己又插了一个制表符（Grok 里复现过）：
    /// `location` 处要是应用插的制表符，就把选的联想上屏、并把那个制表符去掉，返回 true；不是就什么都不做（照常上屏）。
    /// `text` 为空（收起联想）时可以不做：宿主那边要去掉它得再替换一次，Chromium 里先后不可靠。
    func replaceStrayTab(at location: Int, with text: String) -> Bool
}

extension SessionClient {
    public func caretLocation() -> Int? { nil }
    public func replaceStrayTab(at location: Int, with text: String) -> Bool { false }
    public var mayRecord: Bool { true }
    public var mayPredict: Bool { true }
    public var memoryConsented: Bool { true }
    public var personalThirdParty: Bool { false }
}

/// 某一时刻该画成什么样。
public struct SessionView: Equatable {
    /// 光标处：已选部分 + 显示串，或快捷键引擎推送的显示串。
    public var marked = ""
    /// `marked` 开头属于已选部分的字符数。
    public var selectedLength = 0
    /// 候选窗当前页；为空时不画候选窗。
    public var candidates: [Candidate] = []
    public var highlighted: Int?
    public var page = 0
    public var pageCount = 0
    public var notice: String?
    public var english = false
    /// 画出来的这份候选标了 more：引擎还在算更好的（壳在候选窗里给个轻提示）。
    /// 连续打字、新答复还没画出来时沿用上一份的值，免得提示在每个键之间消失又出现。
    public var pending = false
    /// 这一画是补发换掉了用户已经看到的首选（只在换掉的那一次为 true；壳让新首选淡入）。
    public var topReplaced = false
    /// 刚上屏、有联想，还没按 Tab：`candidates` 是联想，淡淡地直接展示、不高亮；按键照常交给应用，Tab 才能选
    /// （原先只提示"⇥ 联想"）。
    public var predictHint = false
    /// 联想候选打开了：`candidates` 是联想，数字选。
    public var predicting = false

    public init() {}
}

public struct TypingEngine {
    public var manifest: Manifest
    public var channel: EngineChannel
    /// 引擎的标识（文件夹名），转给个人化组件的上屏里写明是谁出的字。
    public var id: String
    public init(manifest: Manifest, channel: EngineChannel, id: String = "") {
        self.manifest = manifest
        self.channel = channel
        self.id = id
    }
}

public struct HotkeyEngine {
    public var manifest: Manifest
    public var channel: EngineChannel
    public var id: String
    public init(manifest: Manifest, channel: EngineChannel, id: String = "") {
        self.manifest = manifest
        self.channel = channel
        self.id = id
    }
}

/// 个人化组件（docs/引擎协议.md#个人化组件）：状态机把所有上屏、上屏后的退格和忘掉转给它。
public struct PersonalEngine {
    public var manifest: Manifest
    public var channel: EngineChannel
    public var id: String
    public init(manifest: Manifest, channel: EngineChannel, id: String = "personal") {
        self.manifest = manifest
        self.channel = channel
        self.id = id
    }
}

/// 一个输入框的状态机：输入串、已选部分、键位规则、先快后好、收尾上屏、反馈、快捷键会话。
/// 所有调用都在同一线程（macOS 外壳的主线程）上进行。
public final class Session {
    public var settings: ShellSettings
    public let timing: Timing
    public var typing: TypingEngine?
    public var hotkeys: [HotkeyEngine] = []
    public var personal: PersonalEngine?
    /// 联想：上屏后宿主经转问去问个人化组件（序号、前文、应用），答复回来后调 `receivePredictions`。
    public var predictor: ((_ id: Int, _ context: String, _ app: String?) -> Void)?
    public private(set) var english = false

    private let clock: Clock
    private unowned let client: SessionClient

    // 输入中
    private var pieces: [Piece] = []
    private var input = ""
    private var query: Query?
    private var contextBase = ""
    // 壳在这个输入框里见过的文字：上屏的和放行的。读不到前文时用它，也用于"数字后保持半角"。
    private var history = ""
    private var notice: String?
    // 反馈
    /// told：这次上屏告诉了打字引擎（安全输入、暂停、"不记录"时不告诉，之后的退格也不告诉）；recorded：个人化组件那边的序号。
    private var lastCommit: (id: Int, at: TimeInterval, followedBy: String, told: Bool, recorded: Int?)?
    private var backspaceRun = 0
    private var lastBackspaceAt: TimeInterval = 0
    // 中英文之间加空格：自动加的空格在 history 里的位置；用户删掉它之后，紧接着那一下不再加
    private var autoSpaceAt: Int?
    private var suppressAutoSpace = false
    // 成对标点当前是否处于"已开"
    private var pairOpen: [Character: Bool] = [:]
    // 单按 Shift
    private var shiftClean = false
    // 快捷键
    private var pressing: (modifier: KeyEvent.Modifier, since: TimeInterval, clean: Bool)?
    private var hot: HotSession?
    private var lastView: SessionView?
    /// 上一次画出来的候选窗。新询问的答复画出来之前继续显示它，免得每敲一个键候选窗闪一下。
    private var lastDrawn: SessionView?
    /// 补发换掉了已经画出的首选，下一次画面带上 topReplaced。
    private var topReplacedPending = false
    /// 联想：问出去了（items 为空）、提示亮着、或者候选打开了。
    private var prediction: Prediction?
    private var predictCounter = 0
    /// 数字后面按的逗号，还没定是"，"还是","：先挂在光标处，看下一个键（数字就是 1,000 的半角，别的就是"27，所以"的全角）。
    /// 值是打字引擎的标识（记上屏用）。
    private var pendingComma: String?
    /// 按 Tab 打开联想那一刻光标的位置：应用要是自己也插了个制表符（Grok），选词或收起时连它一起换掉。
    private var tabCaret: Int?

    private struct Prediction {
        var id: Int
        var context: String
        /// 还没问出去时是要问的时刻（上屏后 predictDelay），问出去以后是问的时刻。
        var askedAt: TimeInterval
        var sent = false
        var items: [String] = []
        var shownAt: TimeInterval?
        var open = false
        var highlighted = 0
    }

    private struct Query {
        var id: Int
        var sentAt: TimeInterval
        var answer: Answer?
        var drawn = false
        var navigated = false
        var highlighted = 0
        var hangReported = false
        var drawDeadline: TimeInterval
        /// 答复到之前的显示串：上一次的显示串接上新敲的键。
        var interimDisplay: String?
        var input: String?
    }

    private struct HotSession {
        var engine: Int
        var id: Int
        var shown = ""
        var stopSentAt: TimeInterval?
        var context: String?
    }

    public init(client: SessionClient, clock: Clock = SystemClock(), settings: ShellSettings = ShellSettings(), timing: Timing = Timing()) {
        self.client = client
        self.clock = clock
        self.settings = settings
        self.timing = timing
    }

    public var isComposing: Bool { !input.isEmpty || !pieces.isEmpty }
    /// 还在等引擎的答复或补发（命令行版的脚本模式用它判断何时打下一个键）。
    public var isWaitingForEngine: Bool {
        if let p = prediction, p.items.isEmpty { return true } // 联想问出去了还没答
        guard let q = query, engineUp, !q.hangReported else { return false }
        return q.answer == nil || (q.answer!.more && !q.navigated) || !q.drawn
    }
    public var isInHotkeySession: Bool { hot != nil }
    /// 这会儿退出不丢东西：没在组字、没挂着逗号、不在快捷键会话里、联想候选没打开（只亮着提示不算）。
    /// 换了新版时输入法挑这种时候自己退出（UpgradeWatch）。
    public var isIdle: Bool { !isComposing && pendingComma == nil && hot == nil && !(prediction?.open ?? false) }

    private var now: TimeInterval { clock.now }
    private var engineUp: Bool { typing?.channel.isAvailable ?? false }

    // MARK: - 外部入口

    /// 处理一个按键。返回 false 表示放行，交给应用。
    @discardableResult
    public func handle(_ e: KeyEvent) -> Bool {
        // 这一段组字里碰到过安全输入，就整段不学：上屏时安全输入可能已经关了
        if !isComposing { sawSecureInput = false }
        if client.isSecureInput { sawSecureInput = true }
        pump(render: false)
        defer { render() }
        switch e.key {
        case let .modifierDown(m): modifierDown(m, flags: e.flags); return false
        case let .modifierUp(m): modifierUp(m, flags: e.flags); return false
        default: break
        }
        shiftClean = false
        pressing?.clean = false

        if pendingComma != nil, let handled = resolvePendingComma(e) { return handled }
        if hot != nil { return handleInHotkeySession(e) }
        if prediction != nil, let handled = handlePrediction(e) { return handled }
        // 上屏后的退格计数：只算不带修饰键的 ⌫，⌥⌫、⌘⌫ 这些按别的键处理（结束计数）
        if !(e.key == .backspace && !isComposing && e.flags.isDisjoint(with: [.shift, .command, .option, .control])) { flushDeleted() }
        return isComposing ? handleComposing(e) : handleIdle(e)
    }

    /// 取出引擎消息并应用。宿主在有消息到达时调用。
    public func pump() { pump(render: true) }

    /// 处理到期的计时。宿主在 `nextDeadline` 到达时调用。
    public func tick() {
        pump(render: false)
        let t = now
        if var q = query {
            if !q.drawn, q.answer != nil, t >= q.drawDeadline { q.drawn = true }
            if q.answer == nil, !q.hangReported, t >= q.sentAt + timing.hang {
                q.hangReported = true
                notice = "引擎没有响应，正在重启"
                typing?.channel.reportHang()
            }
            query = q
        }
        if let c = lastCommit, t >= (backspaceRun > 0 ? lastBackspaceAt : c.at) + timing.deletedIdle { flushDeleted() }
        if let p = pressing, p.clean, hot == nil, t >= p.since + timing.holdTrigger,
           let i = hotkeyIndex(for: p.modifier), hotkeys[i].manifest.hotkey?.mode == .hold {
            startHotkey(i)
        }
        if let h = hot, let s = h.stopSentAt, t >= s + timing.stopTimeout {
            endHotkey(reason: .timeout, commitShown: true)
        }
        if let p = prediction, let d = predictionDeadline(p), t >= d {
            if p.sent { prediction = nil } else { sendPrediction() }
        }
        render()
    }

    /// 下一个需要调用 `tick()` 的时刻。
    public var nextDeadline: TimeInterval? {
        var ds: [TimeInterval] = []
        if let q = query {
            if !q.drawn, q.answer != nil { ds.append(q.drawDeadline) }
            if q.answer == nil, !q.hangReported { ds.append(q.sentAt + timing.hang) }
        }
        if let c = lastCommit { ds.append((backspaceRun > 0 ? lastBackspaceAt : c.at) + timing.deletedIdle) }
        if let p = pressing, p.clean, hot == nil, let i = hotkeyIndex(for: p.modifier),
           hotkeys[i].manifest.hotkey?.mode == .hold { ds.append(p.since + timing.holdTrigger) }
        if let s = hot?.stopSentAt { ds.append(s + timing.stopTimeout) }
        if let p = prediction, let d = predictionDeadline(p) { ds.append(d) }
        return ds.min()
    }

    /// 输入框失去焦点或切走：收尾上屏（不等待），快捷键会话结束。
    public func focusLost() {
        pump(render: false)
        settleComma(",", full: true)
        if hot != nil { endHotkey(reason: .focus, commitShown: true) }
        if isComposing { finish(budget: 0, auto: true) }
        flushDeleted()
        forgetHistory()
        prediction = nil
        pairOpen = [:]
        pressing = nil
        shiftClean = false
        render()
    }

    /// 按了鼠标（比如 ⇧ 加点击扩选）：之后松开 Shift 不算单按。
    public func pointerPressed() {
        shiftClean = false
        pressing?.clean = false
        forgetHistory() // 光标可能被点到了别处
        if prediction != nil {
            prediction = nil
            render()
        }
    }

    /// 系统取消组字：丢弃输入串和已选部分，不上屏。
    public func cancelComposition() {
        pump(render: false)
        settleComma(",", full: true)
        if hot != nil { endHotkey(reason: .focus, commitShown: false) }
        reset()
        prediction = nil
        render()
    }

    /// 宿主重启或启动了当前引擎：若正在输入，重新询问。
    public func engineDidStart() {
        notice = nil
        if isComposing, !input.isEmpty { sendQuery() }
        render()
    }

    /// 宿主显示一条提示（比如引擎已停用）；nil 清除。
    public func setNotice(_ text: String?) {
        notice = text
        render()
    }

    /// 宿主设置英文模式（比如应用例外里的"默认英文"）。
    public func setEnglish(_ on: Bool) {
        if on, isComposing { commitRaw() }
        prediction = nil
        english = on
        render()
    }

    /// 这个键进不进组字：引擎声明了它（input_keys）。大写字母另有一条：只在开头、或者已经是大写开头的组字里收（打英文，
    /// 比如 GitHub）；小写开头的组字（拼音）里按 Shift+字母，照旧收尾上屏再放行。
    private func accepts(_ c: Character, _ m: Manifest) -> Bool {
        guard m.inputKeys.contains(c) else { return false }
        guard c.isUppercase else { return true }
        return input.isEmpty || input.first?.isUppercase == true
    }

    // MARK: - 空闲

    private func handleIdle(_ e: KeyEvent) -> Bool {
        guard let engine = typing, engineUp, !english, !e.flags.contains(.capsLock), !e.isChord else {
            return passThrough(e)
        }
        if case let .character(c) = e.key {
            if accepts(c, engine.manifest) {
                contextBase = readContext(limit: max(engine.manifest.context, recordingContext, settings.autoSpace ? 1 : 0))
                input.append(c)
                sendQuery()
                return true
            }
            if c == ",", lastIsDigit, punctuationValue(c, table: engine.manifest.punctuation) != nil {
                pendingComma = engine.id
                return true
            }
            if let text = punctuation(c, table: engine.manifest.punctuation) {
                insert(text)
                record(text, kind: .punctuation, source: engine.id)
                requestPrediction(after: history)
                return true
            }
        }
        if e.key == .backspace, !e.flags.contains(.shift), lastCommit != nil {
            backspaceRun += 1
            lastBackspaceAt = now
        }
        return passThrough(e)
    }

    // MARK: - 输入中

    private func handleComposing(_ e: KeyEvent) -> Bool {
        guard let engine = typing, engineUp else { return handleComposingWithoutEngine(e) }
        let manifest = engine.manifest
        if e.isChord || e.flags.contains(.capsLock) {
            finish(budget: timing.spaceWait, auto: false)
            return passThrough(e)
        }
        switch e.key {
        case let .character(c):
            if accepts(c, manifest) {
                input.append(c)
                sendQuery()
                return true
            }
            if let d = c.wholeNumberValue, c.isASCII {
                // 还没有任何答复：等到第一份答复再选（打得快的人凭熟悉的顺序按数字）；引擎卡死了才收尾，数字原样交给应用，不吞掉
                if query?.answer == nil {
                    let pressed = now
                    awaitFirstAnswer()
                    if query?.answer == nil {
                        commitRaw()
                        return passThrough(e)
                    }
                    settle(until: pressed + timing.spaceWait) // 和空格一样再等一下补发，过了画出的时刻就照常选
                }
                if revealUndrawn() { return true }
                if (1...9).contains(d), d <= pageSize { select(pageStart + d - 1) }
                return true
            }
            switch (settings.pagingKeys, c) {
            case (.minusEqual, "-") where pageStart == 0:
                // 第一页没有上一页可翻：拼音串照原样字母上屏，再接「-」（luoke-ime、gpt-4、e-mail 这类，
                // luokelabs/luoke-ime#17）。要「北京-上海」就先选好「北京」再按
                commitRaw()
                return passThrough(e)
            case (.minusEqual, "-"), (.commaPeriod, ","): if !revealUndrawn() { turnPage(-1) }; return true
            case (.minusEqual, "="), (.commaPeriod, "."): if !revealUndrawn() { turnPage(1) }; return true
            default: break
            }
            if punctuationValue(c, table: manifest.punctuation) != nil {
                finish(budget: timing.spaceWait, auto: false)
                guard let text = punctuation(c, table: manifest.punctuation) else { return passThrough(e) }
                insert(text)
                record(text, kind: .punctuation, source: engine.id)
                lastCommit?.followedBy = text // 紧跟上屏的标点，退格时会先删到它
                requestPrediction(after: history) // 壳在这个输入框里上屏、放行过的字，刚才那句和这个标点都在里面
                return true
            }
            finish(budget: timing.spaceWait, auto: false)
            return passThrough(e)
        case .space:
            awaitFirstAnswer()
            settle(until: now + timing.spaceWait)
            if let q = query, let a = q.answer, !a.candidates.isEmpty { select(q.highlighted) } else { commitRaw() }
            return true
        case .enter:
            commitRaw()
            return true
        case .escape:
            reset()
            return true
        case .backspace:
            if e.flags.contains(.shift) { forget() } else { deleteBackward() }
            return true
        case .left, .right, .tab, .up, .down, .pageUp, .pageDown:
            if revealUndrawn() { return true }
            let horizontal = settings.orientation == .horizontal
            switch e.key {
            case .left: horizontal ? move(-1) : turnPage(-1)
            case .right, .tab: horizontal ? move(1) : turnPage(1)
            case .up: horizontal ? turnPage(-1) : move(-1)
            case .down: horizontal ? turnPage(1) : move(1)
            case .pageUp: turnPage(-1)
            default: turnPage(1)
            }
            return true
        case .other:
            finish(budget: timing.spaceWait, auto: false)
            return passThrough(e)
        case .modifierDown, .modifierUp:
            return false
        }
    }

    /// 引擎没在运行（卡死重启中、停用）时，已经敲下的输入串保留：输入键照样接上（引擎回来后重新询问），
    /// 回车、空格上屏原始字母，Esc 放弃，退格修改；其余按键先上屏原始字母再放行。
    private func handleComposingWithoutEngine(_ e: KeyEvent) -> Bool {
        switch e.key {
        case .enter, .space: commitRaw(); return true
        case .escape: reset(); return true
        case .backspace:
            if !e.flags.contains(.shift) { deleteBackward() }
            return true
        case let .character(c) where !e.isChord && typing.map({ accepts(c, $0.manifest) }) == true:
            input.append(c)
            query = nil
            return true
        case let .character(c) where !e.isChord && c.isASCII && c.isNumber:
            return true
        default:
            commitRaw()
            return passThrough(e)
        }
    }

    /// 候选还没画出来时按了选词、移动或翻页键：先把它画出来，这个键不再生效，免得选中没见过的候选。
    private func revealUndrawn() -> Bool {
        guard var q = query, !q.drawn else { return false }
        // 等过补发（按数字时最多 150 ms）之后已经到了画出的时刻：当作已经画出，这个键照常生效
        if q.answer != nil, now >= q.drawDeadline {
            q.drawn = true
            query = q
            return false
        }
        if q.answer != nil { q.drawn = true }
        query = q
        return true
    }

    private var pageSize: Int { min(max(settings.pageSize, 1), 9) }

    // MARK: - 选词、上屏

    private var pageStart: Int { ((query?.highlighted ?? 0) / pageSize) * pageSize }

    /// 选中第 `index` 个候选；输入串用完就上屏，否则拿剩下的键再问。
    private func select(_ index: Int) {
        guard choose(index) else { return }
        if input.isEmpty { commitAll(auto: false, predict: true) } else { sendQuery() }
    }

    /// 只把候选并入已选部分，不发询问也不上屏。
    private func choose(_ index: Int) -> Bool {
        guard let a = query?.answer, a.candidates.indices.contains(index) else { return false }
        let c = a.candidates[index]
        pieces.append(Piece(input: String(input.prefix(c.consume)), text: c.text, index: index, top: a.candidates.first?.text))
        input = String(input.dropFirst(c.consume))
        query = nil
        return true
    }

    /// 收尾上屏：先选高亮候选，剩下的用最新答复的首选接着选，拿不到答复的部分按原始字母上屏。
    private func finish(budget: TimeInterval, auto: Bool) {
        if budget > 0 { awaitFirstAnswer() }
        let deadline = now + budget
        if budget > 0 { settle(until: deadline) }
        if let q = query, let a = q.answer, !a.candidates.isEmpty { _ = choose(q.highlighted) }
        while !input.isEmpty, now < deadline, engineUp {
            if query == nil { sendQuery() }
            while query?.answer == nil, now < deadline { waitForMessages(until: deadline) }
            guard let a = query?.answer, !a.candidates.isEmpty, choose(0) else { break }
        }
        if !input.isEmpty { pieces.append(.raw(input)) }
        input = ""
        commitAll(auto: auto)
    }

    /// 回车：已选部分 + 剩余原始字母。
    private func commitRaw() {
        if !input.isEmpty { pieces.append(.raw(input)) }
        input = ""
        commitAll(auto: false)
    }

    /// `predict`：用户选定候选上屏（空格、数字）时接着问联想；回车上屏字母、切走、按别的键收尾时不问。
    private func commitAll(auto: Bool, predict: Bool = false) {
        let text = pieces.map(\.text).joined()
        let before = contextBase
        var inserted = ""
        if !text.isEmpty {
            inserted = insert(text, after: contextBase.last) // 没有打字引擎（比如它的引擎说明刚被改坏）也照样上屏，不能把字吞掉
        }
        if let engine = typing, !text.isEmpty {
            let id = engine.channel.nextID()
            let told = engine.manifest.feedback && mayLearn
            if told {
                let ctx: String? = engine.manifest.context > 0 ? String(contextBase.suffix(engine.manifest.context)) : nil
                engine.channel.send(.committed(.init(id: id, text: text, auto: auto, context: ctx, pieces: pieces)))
            }
            let recorded = record(text, kind: .typing, source: engine.id, auto: auto, context: contextBase, pieces: pieces)
            lastCommit = (id, now, "", told, recorded)
            backspaceRun = 0
        }
        reset()
        if predict, !inserted.isEmpty { requestPrediction(after: before + inserted) }
    }

    private func deleteBackward() {
        if !input.isEmpty {
            input.removeLast()
        } else if let p = pieces.popLast() {
            input = p.input
        }
        if !isComposing { reset(); return }
        if input.isEmpty { query = nil } else { sendQuery() }
    }

    private func forget() {
        guard let engine = typing, let q = query, q.drawn, let a = q.answer, a.candidates.indices.contains(q.highlighted) else { return }
        let text = a.candidates[q.highlighted].text
        if engine.manifest.feedback, mayLearn {
            engine.channel.send(.forget(input: input, text: text, context: queryContext(engine.manifest)))
        }
        if let p = personal, mayForward {
            let ctx: String? = p.manifest.context > 0 ? String((contextBase + pieces.map(\.text).joined()).suffix(p.manifest.context)) : nil
            p.channel.send(.forget(input: input, text: text, context: ctx, source: engine.id))
        }
        sendQuery()
    }

    private func reset() {
        lastDrawn = nil
        pieces = []
        input = ""
        query = nil
        contextBase = ""
        notice = nil
    }

    private func move(_ delta: Int) {
        guard var q = query, let a = q.answer, !a.candidates.isEmpty else { return }
        q.highlighted = min(max(q.highlighted + delta, 0), a.candidates.count - 1)
        q.navigated = true
        q.drawn = true
        query = q
    }

    private func turnPage(_ delta: Int) {
        guard var q = query, let a = q.answer, !a.candidates.isEmpty else { return }
        let size = pageSize
        let lastPage = (a.candidates.count - 1) / size
        let page = min(max(q.highlighted / size + delta, 0), lastPage)
        q.highlighted = page * size
        q.navigated = true
        q.drawn = true
        query = q
    }

    // MARK: - 询问与答复

    private func sendQuery() {
        guard let engine = typing, engineUp, !input.isEmpty else { query = nil; return }
        let id = engine.channel.nextID()
        engine.channel.send(.query(id: id, input: input, context: queryContext(engine.manifest),
                                   app: engine.manifest.app ? client.appID : nil))
        let t = now
        var interim: String?
        if let old = query, let display = old.answer?.display ?? old.interimDisplay, let oldInput = old.input, input.hasPrefix(oldInput) {
            interim = display + input.dropFirst(oldInput.count)
        }
        query = Query(id: id, sentAt: t, drawDeadline: t + timing.drawDelay, interimDisplay: interim, input: input)
    }

    private func queryContext(_ m: Manifest) -> String? {
        guard m.context > 0 else { return nil }
        return String((contextBase + pieces.map(\.text).joined()).suffix(m.context))
    }

    private func readContext(limit: Int) -> String {
        guard limit > 0, !client.isSecureInput else { return "" }
        return client.textBeforeCursor(limit: limit) ?? String(history.suffix(limit))
    }

    /// 等补发：直到答复不再标 more、用户已移动高亮，或到时。
    private func settle(until deadline: TimeInterval) {
        while let q = query, !q.navigated, q.answer?.more ?? true, now < deadline, engineUp {
            waitForMessages(until: deadline)
        }
    }

    /// 按空格、数字、标点收尾时一份答复都还没有（引擎冷启动、系统在换页、主控在加载模型）：等到第一份答复，最多等到判定卡死的时刻，
    /// 不上屏原样拼音（luokelabs/luoke-ime#11）。补发照旧只等 `spaceWait`。引擎真卡死了就照 tick 的做法报告，调用方再按原始字母收尾。
    private func awaitFirstAnswer() {
        guard var q = query, q.answer == nil, !q.hangReported, engineUp else { return }
        let deadline = q.sentAt + timing.hang
        while query?.id == q.id, query?.answer == nil, now < deadline, engineUp { waitForMessages(until: deadline) }
        guard query?.id == q.id, query?.answer == nil, engineUp, now >= deadline else { return }
        q.hangReported = true
        query = q
        notice = "引擎没有响应，正在重启"
        typing?.channel.reportHang()
    }

    private func waitForMessages(until deadline: TimeInterval) {
        guard let engine = typing else { return }
        engine.channel.wait(until: deadline)
        pump(render: false)
    }

    private func pump(render shouldRender: Bool) {
        if let engine = typing {
            for m in engine.channel.drain() {
                if case let .answer(a) = m { apply(a) }
            }
        }
        for (i, h) in hotkeys.enumerated() {
            for m in h.channel.drain() { applyHotkey(m, engine: i) }
        }
        if shouldRender { render() }
    }

    private func apply(_ answer: Answer) {
        guard var q = query, answer.id == q.id else { return } // 旧询问的答复一律丢弃
        notice = nil
        var a = answer
        a.candidates = a.candidates.filter { $0.consume >= 1 && $0.consume <= input.count && !$0.text.isEmpty }
        if q.navigated {
            // 用户已经移动高亮或翻页：不在手指底下换词，只记下不必再等。
            q.answer?.more = false
        } else {
            let shownTop = q.drawn ? q.answer?.candidates.first?.text : nil
            q.answer = a
            q.highlighted = 0
            if !a.more || now >= q.drawDeadline { q.drawn = true }
            if let shownTop, q.drawn, a.candidates.first?.text != shownTop { topReplacedPending = true }
        }
        query = q
        if a.autocommit, !q.navigated, !a.candidates.isEmpty { select(0) }
    }

    // MARK: - 标点

    /// 这个键在中文模式下上屏什么：设置里开了「」就先看 { }，再看引擎的标点表。
    private func punctuationValue(_ c: Character, table: PunctuationTable) -> PunctuationTable.Value? {
        if settings.cornerBraces, c == "{" { return .single("「") }
        if settings.cornerBraces, c == "}" { return .single("」") }
        return table.entries[c]
    }

    private var lastIsDigit: Bool { history.last.map { $0.isASCII && $0.isNumber } ?? false }

    private func punctuation(_ c: Character, table: PunctuationTable) -> String? {
        guard let v = punctuationValue(c, table: table) else { return nil }
        // 数字后的 . : 保持半角：3.14、12:30（逗号先挂着看下一个键，见 pendingComma）
        if ".,:".contains(c), lastIsDigit { return nil }
        switch v {
        case let .single(s): return s
        case let .pair(open, close):
            let isOpen = pairOpen[c] ?? false
            pairOpen[c] = !isOpen
            return isOpen ? close : open
        }
    }

    /// 挂着的逗号碰到下一个键：数字就上屏半角（1,000），退格就不要了，别的键上屏全角（27，所以）再照常处理这个键。
    /// 返回 nil 表示这个键接着照常处理。
    private func resolvePendingComma(_ e: KeyEvent) -> Bool? {
        if case let .character(c) = e.key, !e.isChord, c.isASCII, c.isNumber {
            settleComma(",", full: false)
            return nil
        }
        if e.key == .backspace, e.flags.isDisjoint(with: [.shift, .command, .option, .control]) {
            pendingComma = nil
            return true
        }
        settleComma(",", full: true)
        return nil
    }

    /// 把挂着的逗号上屏：full 为 true 时是全角"，"。
    private func settleComma(_ half: String, full: Bool) {
        guard let source = pendingComma else { return }
        pendingComma = nil
        let text = full ? "，" : half
        insert(text)
        record(text, kind: .punctuation, source: source)
    }

    // MARK: - 放行、上屏

    private func passThrough(_ e: KeyEvent) -> Bool {
        switch e.key {
        case let .character(c) where !e.isChord:
            // 中文后面直接敲字母、数字（英文模式，或中文模式下的数字）：补一个空格再上屏。
            // 只信壳自己记得的前文，读到的不算：比如终端里的 vim，前文是中文也不该往命令前面插空格
            if autoSpaceAllowed(), Self.isLatin(c), let p = history.last, Self.isCJK(p) {
                autoSpaceAt = history.count
                client.insert(" " + String(c))
                history += " " + String(c)
                trimHistory()
                return true
            }
            history.append(c)
        case .space: history.append(" ")
        case .enter: history.append("\n")
        case .backspace:
            if !history.isEmpty { history.removeLast() }
            if let a = autoSpaceAt, history.count <= a { // 删到了自动加的空格：用户不要它
                autoSpaceAt = nil
                suppressAutoSpace = true
            }
        case .tab, .left, .right, .up, .down, .pageUp, .pageDown, .other, .escape: forgetHistory() // 光标可能动了
        default: if e.isChord { forgetHistory() }
        }
        trimHistory()
        return false
    }

    /// 上屏，返回实际上屏的文字。`after` 是光标前的那个字（知道时），用来决定要不要在中英文之间补空格。
    @discardableResult
    private func insert(_ text: String, after prev: Character? = nil) -> String {
        var out = text
        if autoSpaceAllowed(), let p = prev, let f = text.first, Self.needsSpace(p, f) {
            autoSpaceAt = history.count
            out = " " + text
        }
        client.insert(out)
        history += out
        trimHistory()
        return out
    }

    private func forgetHistory() {
        history = ""
        autoSpaceAt = nil
        suppressAutoSpace = false
    }

    private func trimHistory() {
        if history.count > 512 {
            history = String(history.suffix(256))
            autoSpaceAt = nil
        }
    }

    // MARK: - 联想

    /// 上屏后问个人化组件接着写什么（docs/设计.md#联想的界面）。只在能转给它的时候问（安全输入、暂停、"不记录"的应用都不问）。
    private func requestPrediction(after context: String) {
        prediction = nil
        guard settings.predict, client.mayPredict, let predictor, let p = personal, personalUp, policy.predict, !isComposing, hot == nil else { return }
        predictCounter += 1
        let ctx = String(context.suffix(max(p.manifest.context, 20)))
        prediction = Prediction(id: predictCounter, context: ctx, askedAt: now + timing.predictDelay)
        if timing.predictDelay <= 0 { sendPrediction() }
    }

    /// 上屏后停够了 predictDelay（期间按了键，handlePrediction 已经把它清掉）：问出去。这时再看一遍能不能问。
    private func sendPrediction() {
        guard var q = prediction, !q.sent else { return }
        guard settings.predict, client.mayPredict, let predictor, let p = personal, personalUp, policy.predict, !isComposing, hot == nil else {
            prediction = nil
            return
        }
        q.sent = true
        q.askedAt = now
        prediction = q
        predictor(q.id, q.context, p.manifest.app ? client.appID : nil)
    }

    /// 宿主收到联想的答复后在主线程上调。来晚了（用户已经接着打了，或者等了太久）就不要。
    public func receivePredictions(id: Int, items: [String]) {
        guard var p = prediction, p.id == id, p.sent, p.items.isEmpty, now <= p.askedAt + timing.predictWait,
              !isComposing, hot == nil else { return }
        var seen = Set<String>()
        let list = items.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(pageSize)
        if list.isEmpty {
            prediction = nil
        } else {
            p.items = Array(list)
            p.shownAt = now
            prediction = p
        }
        render()
    }

    /// 问出去还没答复的，到 predictWait 不要了；亮着的提示到 predictHint 收起；打开了的候选一直在，等用户选或按别的键。
    private func predictionDeadline(_ p: Prediction) -> TimeInterval? {
        if !p.sent { return p.askedAt }
        if p.items.isEmpty { return p.askedAt + timing.predictWait }
        if !p.open, let s = p.shownAt { return s + timing.predictHint }
        return nil
    }

    /// 联想提示亮着或候选开着时的按键：提示亮着时 Tab 打开；开着时数字选、空格选高亮的、方向键和 Tab 移动，
    /// Esc、回车、退格收起（开着时光标处有显示串，这几个键交给应用会被 Chromium 吞掉或删到显示串，所以只收起）。
    /// 返回 nil 表示联想收起了、这个键照常处理。
    private func handlePrediction(_ e: KeyEvent) -> Bool? {
        guard var p = prediction, !p.items.isEmpty, !e.isChord else { prediction = nil; return nil }
        if p.open {
            switch e.key {
            case let .character(c) where c.isASCII && c.isNumber:
                if let d = c.wholeNumberValue, (1...9).contains(d), d <= p.items.count { pick(d - 1) }
                return true
            case .space:
                pick(p.highlighted)
                return true
            case .left, .up, .right, .down, .tab:
                let delta = [.left, .up].contains(e.key) ? -1 : 1
                p.highlighted = min(max(p.highlighted + delta, 0), p.items.count - 1)
                prediction = p
                return true
            case .escape, .enter, .backspace:
                dropStrayTab()
                prediction = nil
                return true
            default:
                dropStrayTab()
            }
        } else if e.key == .tab, !e.flags.contains(.shift) {
            tabCaret = client.caretLocation() // 还没放显示串：这就是光标的位置
            p.open = true
            prediction = p
            return true
        }
        prediction = nil
        return nil
    }

    /// 联想收起（没选）：应用自己插的那个制表符连同显示串一起去掉。
    private func dropStrayTab() {
        if let c = tabCaret { _ = client.replaceStrayTab(at: c, with: "") }
        tabCaret = nil
    }

    /// 选了一个联想：上屏（也算一次上屏，转给个人化组件），再接着问。
    private func pick(_ i: Int) {
        guard let p = prediction, p.items.indices.contains(i) else { return }
        prediction = nil
        let text = p.items[i]
        let inserted: String
        if let c = tabCaret, client.replaceStrayTab(at: c, with: text) {
            history += text
            trimHistory()
            inserted = text
        } else {
            inserted = insert(text, after: history.last ?? p.context.last)
        }
        tabCaret = nil
        record(text, kind: .predict, source: personal?.id ?? "personal", context: p.context)
        requestPrediction(after: p.context + inserted)
    }

    // MARK: - 中英文之间加空格

    /// 开关开着，而且用户刚才没删掉自动加的空格（删掉后紧接着那一下不加，之后照常）。
    private func autoSpaceAllowed() -> Bool {
        let suppressed = suppressAutoSpace
        suppressAutoSpace = false
        return settings.autoSpace && !suppressed
    }

    /// 汉字和假名。只看字的类别，不懂语言（和"数字后保持半角"一样是壳的排版规则）。
    static func isCJK(_ c: Character) -> Bool {
        guard let u = c.unicodeScalars.first else { return false }
        return u.properties.isIdeographic || (0x3040...0x30FF).contains(u.value)
    }

    /// 半角字母和数字。
    static func isLatin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

    static func needsSpace(_ a: Character, _ b: Character) -> Bool {
        (isCJK(a) && isLatin(b)) || (isLatin(a) && isCJK(b))
    }

    private func flushDeleted() {
        if let c = lastCommit, backspaceRun > 0 {
            if let engine = typing, engine.manifest.feedback, c.told {
                engine.channel.send(.deleted(after: c.id, count: backspaceRun, followedBy: c.followedBy))
            }
            if let r = c.recorded, let p = personal, mayForward {
                p.channel.send(.deleted(after: r, count: backspaceRun, followedBy: c.followedBy))
            }
        }
        lastCommit = nil
        backspaceRun = 0
    }

    // MARK: - 个人化组件

    /// 这一刻什么能交给个人化组件、打字引擎能不能学：照 PersonalPolicy 那张表（顶层 ADR 0013）。
    private var policy: PersonalPolicy.Decision {
        PersonalPolicy.decide(.init(thirdParty: client.personalThirdParty, secureInput: client.isSecureInput || sawSecureInput,
                                    userStopped: !client.mayRecord, enabled: client.memoryConsented))
    }
    private var sawSecureInput = false

    /// 打字引擎能不能收反馈（学改选过的词）。
    private var mayLearn: Bool { policy.typingFeedback }

    private var personalUp: Bool { personal?.channel.isAvailable == true }

    /// 能不能把上屏、删改、忘掉转给个人化组件。
    private var mayForward: Bool { personalUp && policy.forwardEvents }

    /// 个人化组件要多少字前文（不转给它时为 0）。读前文时按打字引擎和它中较大的读，各自截取。
    private var recordingContext: Int { mayForward ? personal?.manifest.context ?? 0 : 0 }

    /// 把一次上屏转给个人化组件，返回它那边的上屏序号（`deleted` 用）；没转时为 nil。
    @discardableResult
    private func record(_ text: String, kind: ShellMessage.Committed.Kind, source: String, auto: Bool = false,
                        context: String? = nil, pieces: [Piece] = []) -> Int? {
        guard let p = personal, mayForward, !text.isEmpty else { return nil }
        let id = p.channel.nextID()
        let limit = p.manifest.context
        let ctx: String? = limit > 0 ? context.map { String($0.suffix(limit)) } : nil
        p.channel.send(.committed(.init(id: id, text: text, auto: auto, context: ctx, pieces: pieces,
                                        source: source, kind: kind, app: p.manifest.app ? client.appID : nil)))
        return id
    }

    // MARK: - 修饰键：单按 Shift、快捷键引擎

    /// 单按 Shift：按下时没有别的修饰键，松开前也没按过别的键、别的修饰键或鼠标。
    private static let otherModifiers: KeyEvent.Flags = [.command, .control, .option]

    private func modifierDown(_ m: KeyEvent.Modifier, flags: KeyEvent.Flags) {
        if m.isShift {
            shiftClean = flags.isDisjoint(with: Self.otherModifiers)
        } else {
            shiftClean = false
        }
        if let p = pressing, p.modifier != m { pressing?.clean = false } // 快捷键的修饰键按着时又按了别的修饰键：是组合键
        if hotkeyIndex(for: m) != nil { pressing = (m, now, true) }
    }

    private func modifierUp(_ m: KeyEvent.Modifier, flags: KeyEvent.Flags) {
        if m.isShift {
            if shiftClean, flags.isDisjoint(with: Self.otherModifiers), settings.shiftToggles, hot == nil { toggleEnglish() }
            shiftClean = false
        }
        guard let p = pressing, p.modifier == m else { return }
        pressing = nil
        guard let i = hotkeyIndex(for: m), let mode = hotkeys[i].manifest.hotkey?.mode else { return }
        switch mode {
        case .hold:
            if let h = hot, h.engine == i, h.stopSentAt == nil { sendStop() }
        case .press:
            guard p.clean else { return }
            if let h = hot, h.engine == i {
                if h.stopSentAt == nil { sendStop() }
            } else if hot == nil {
                startHotkey(i)
            }
        }
    }

    private func toggleEnglish() {
        if !english, isComposing { commitRaw() }
        english.toggle()
    }

    private func hotkeyIndex(for m: KeyEvent.Modifier) -> Int? {
        let key: Manifest.Hotkey.Key
        switch m {
        case .rightCommand: key = .rightCommand
        case .rightOption: key = .rightOption
        case .rightControl: key = .rightControl
        default: return nil
        }
        return hotkeys.firstIndex { $0.manifest.hotkey?.key == key && $0.channel.isAvailable }
    }

    private func startHotkey(_ i: Int) {
        if isComposing { finish(budget: timing.spaceWait, auto: false) }
        prediction = nil
        flushDeleted()         // 之后的退格删的是快捷键引擎的文字，不算打字引擎上屏后的修改
        pressing?.clean = false // 按住期间引擎自己结束了会话，也不能再自动开始一次
        let engine = hotkeys[i]
        let limit = max(engine.manifest.context, recordingContext, settings.autoSpace ? 1 : 0)
        let read: String? = limit > 0 ? readContext(limit: limit) : nil
        let ctx = engine.manifest.context > 0 ? read.map { String($0.suffix(engine.manifest.context)) } : nil
        let id = engine.channel.nextID()
        engine.channel.send(.start(id: id, context: ctx, app: engine.manifest.app ? client.appID : nil))
        hot = HotSession(engine: i, id: id, context: read)
    }

    private func sendStop() {
        guard var h = hot else { return }
        hotkeys[h.engine].channel.send(.stop(id: h.id))
        h.stopSentAt = now
        hot = h
    }

    private func endHotkey(reason: ShellMessage.CancelReason, commitShown: Bool) {
        guard let h = hot else { return }
        hot = nil
        if commitShown, !h.shown.isEmpty {
            insert(h.shown, after: h.context?.last)
            // 按了别的键：和收尾上屏一样算用户要的；切走、超时没等到最终结果，算自动上屏
            record(h.shown, kind: .hotkey, source: hotkeys[h.engine].id, auto: reason != .key, context: h.context)
        }
        hotkeys[h.engine].channel.send(.cancel(id: h.id, reason: reason))
    }

    private func handleInHotkeySession(_ e: KeyEvent) -> Bool {
        if e.key == .escape {
            endHotkey(reason: .esc, commitShown: false)
            return true
        }
        endHotkey(reason: .key, commitShown: true)
        return isComposing ? handleComposing(e) : handleIdle(e)
    }

    private func applyHotkey(_ m: EngineMessage, engine i: Int) {
        guard var h = hot, h.engine == i, m.id == h.id else { return }
        switch m {
        case let .show(_, text):
            h.shown = text
            hot = h
        case let .commit(_, text):
            hot = nil
            let inserted = insert(text, after: h.context?.last)
            record(text, kind: .hotkey, source: hotkeys[i].id, context: h.context)
            requestPrediction(after: (h.context ?? "") + inserted)
        case .end:
            hot = nil
        default:
            break
        }
    }

    // MARK: - 画面

    private func render() {
        var v = SessionView()
        v.english = english
        v.notice = notice
        if let h = hot {
            v.marked = h.shown
        } else if pendingComma != nil {
            v.marked = ","
        } else if isComposing {
            let selected = pieces.map(\.text).joined()
            v.marked = selected + (query?.answer?.display ?? query?.interimDisplay ?? input)
            v.selectedLength = selected.count
            if let q = query, q.drawn, let a = q.answer {
                if !a.candidates.isEmpty {
                    let size = pageSize
                    let start = (q.highlighted / size) * size
                    v.candidates = Array(a.candidates[start..<min(start + size, a.candidates.count)])
                    v.highlighted = q.highlighted - start
                    v.page = start / size
                    v.pageCount = (a.candidates.count + size - 1) / size
                    v.pending = a.more && !q.navigated
                    v.topReplaced = topReplacedPending
                }
                topReplacedPending = false
                lastDrawn = v
                lastDrawn?.topReplaced = false
            } else if let q = query, !q.hangReported, let d = lastDrawn {
                // 新答复还没画：先留着上一份候选
                v.candidates = d.candidates
                v.highlighted = d.highlighted
                v.page = d.page
                v.pageCount = d.pageCount
                v.pending = d.pending
            }
        } else if let p = prediction, !p.items.isEmpty {
            if p.open {
                v.candidates = p.items.map { Candidate(text: $0, consume: 0) }
                v.highlighted = p.highlighted
                v.pageCount = 1
                v.predicting = true
                // 高亮的联想放在光标处当显示串：Chromium、Electron 里输入法吞掉一个键却没有显示串时，它会把这个键再交给网页
                // （Tab 就把焦点移走了）；有显示串它才知道是输入法在处理。也顺便让用户在光标处看到要上屏的字
                v.marked = p.items[p.highlighted]
            } else {
                // 直接展示、不高亮，也不放显示串：还没激活，按键照常交给应用；按 Tab 才高亮第一个、能选。
                // 最多列 3 个，免得挡住界面（比打字时的候选窗大就挡 UI）；Tab 打开后全列出来
                v.candidates = p.items.prefix(3).map { Candidate(text: $0, consume: 0) }
                v.highlighted = nil
                v.pageCount = 1
                v.predictHint = true
            }
        }
        if v != lastView {
            lastView = v
            client.render(v)
        }
    }
}
