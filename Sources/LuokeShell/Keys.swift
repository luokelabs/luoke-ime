import Foundation

/// 壳收到的一个按键事件。macOS 外壳和命令行版都把各自的事件翻译成它再交给状态机。
public struct KeyEvent: Equatable {
    public enum Key: Equatable {
        /// 键盘布局产生的字符（字母、数字、标点），不含空格。
        case character(Character)
        case space, enter, backspace, escape, tab
        case left, right, up, down, pageUp, pageDown
        /// 功能键、Home/End、向前删除等壳不关心的键。
        case other
        /// 单独按下 / 松开修饰键（macOS 的 flagsChanged）。
        case modifierDown(Modifier)
        case modifierUp(Modifier)
    }

    public enum Modifier: String {
        case leftShift, rightShift, leftCommand, rightCommand, leftOption, rightOption, leftControl, rightControl, capsLock, function

        var isShift: Bool { self == .leftShift || self == .rightShift }
    }

    public struct Flags: OptionSet, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Flags(rawValue: 1)
        public static let command = Flags(rawValue: 2)
        public static let option = Flags(rawValue: 4)
        public static let control = Flags(rawValue: 8)
        public static let capsLock = Flags(rawValue: 16)
    }

    public var key: Key
    public var flags: Flags

    public init(_ key: Key, flags: Flags = []) {
        self.key = key
        self.flags = flags
    }

    public static func char(_ c: Character, flags: Flags = []) -> KeyEvent { KeyEvent(.character(c), flags: flags) }

    /// 带 ⌘ ⌃ ⌥ 的组合键：壳不解释，按需收尾上屏后放行。
    var isChord: Bool { !flags.isDisjoint(with: [.command, .control, .option]) }
}

/// 壳的用户设置里影响状态机的部分（docs/设计.md#键位）。
public struct ShellSettings: Equatable {
    public enum PagingKeys: String { case minusEqual = "-=", commaPeriod = ",." }
    public enum Orientation: String { case horizontal, vertical }

    public var pageSize = 9
    public var pagingKeys = PagingKeys.minusEqual
    public var shiftToggles = true
    /// 中文模式下 { } 打成「」：和系统简体拼音一样（Shift 加中括号是「」，中括号本身是【】），默认开。
    /// 在中文模式下也要打代码花括号的可以关掉。开着时不管引擎的标点表怎么写。
    public var cornerBraces = true
    public var orientation = Orientation.horizontal
    /// 汉字和半角字母、数字挨着时，中间自动补一个半角空格。
    public var autoSpace = false
    /// 上屏后问个人化组件接着写什么，有就提示"⇥ 联想"（docs/设计.md#联想的界面）。
    public var predict = true

    public init() {}
}

/// 时间参数（docs/引擎协议.md#时间参数），单位秒。
public struct Timing: Equatable {
    public var drawDelay = 0.05
    public var spaceWait = 0.15
    public var hang = 1.0
    public var deletedIdle = 5.0
    public var holdTrigger = 0.15
    public var stopTimeout = 10.0
    /// 上屏后停这么久没有按键才问联想：快打时接连的短词不一个个去问，免得和下一个键的重排抢模型、卡一下。
    public var predictDelay = 0.25
    /// 问出去以后多久没等到联想就不要了（用户多半已经接着打了）。
    public var predictWait = 1.0
    /// 联想提示亮多久：过了就收起，Tab 照常交给应用。
    public var predictHint = 4.0

    public init() {}
}

/// 单调时钟。测试时注入假的。
public protocol Clock: AnyObject {
    var now: TimeInterval { get }
}

public final class SystemClock: Clock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

// MARK: - 输入记录里的按键

extension KeyEvent {
    private static let names: [(String, Key)] = [
        ("space", .space), ("enter", .enter), ("backspace", .backspace), ("escape", .escape), ("tab", .tab),
        ("left", .left), ("right", .right), ("up", .up), ("down", .down), ("pageUp", .pageUp), ("pageDown", .pageDown),
        ("other", .other),
    ]

    /// 写进输入记录的形式，例如 {"char":"a"}、{"key":"space","flags":1}、{"down":"rightCommand"}。
    public var json: [String: Any] {
        var m: [String: Any] = [:]
        switch key {
        case let .character(c): m["char"] = String(c)
        case let .modifierDown(x): m["down"] = x.rawValue
        case let .modifierUp(x): m["up"] = x.rawValue
        default: m["key"] = Self.names.first { $0.1 == key }!.0
        }
        if flags.rawValue != 0 { m["flags"] = flags.rawValue }
        return m
    }

    public init?(json m: [String: Any]) {
        let flags = Flags(rawValue: m["flags"] as? Int ?? 0)
        if let c = (m["char"] as? String)?.first {
            self.init(.character(c), flags: flags)
        } else if let d = (m["down"] as? String).flatMap(Modifier.init(rawValue:)) {
            self.init(.modifierDown(d), flags: flags)
        } else if let u = (m["up"] as? String).flatMap(Modifier.init(rawValue:)) {
            self.init(.modifierUp(u), flags: flags)
        } else if let k = m["key"] as? String, let key = Self.names.first(where: { $0.0 == k })?.1 {
            self.init(key, flags: flags)
        } else {
            return nil
        }
    }
}
