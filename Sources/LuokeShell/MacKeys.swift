import Foundation

/// 把 macOS 的按键事件翻译成 KeyEvent。只用到事件里的数值（keyCode、字符、modifierFlags 原始值），
/// 不依赖 AppKit，所以能单独测试；macOS 外壳从 NSEvent 取出这些值再调用。
public enum MacKeys {
    // 与设备无关的修饰键位（NSEvent.ModifierFlags）
    static let capsLockFlag: UInt = 1 << 16
    static let shiftFlag: UInt = 1 << 17
    static let controlFlag: UInt = 1 << 18
    static let optionFlag: UInt = 1 << 19
    static let commandFlag: UInt = 1 << 20
    static let functionFlag: UInt = 1 << 23

    /// 修饰键的 keyCode → (哪个键, 判断按下的设备相关位, 对应的设备无关位)。
    static let modifiers: [UInt16: (KeyEvent.Modifier, UInt, UInt)] = [
        56: (.leftShift, 0x02, shiftFlag), 60: (.rightShift, 0x04, shiftFlag),
        55: (.leftCommand, 0x08, commandFlag), 54: (.rightCommand, 0x10, commandFlag),
        58: (.leftOption, 0x20, optionFlag), 61: (.rightOption, 0x40, optionFlag),
        59: (.leftControl, 0x01, controlFlag), 62: (.rightControl, 0x2000, controlFlag),
        57: (.capsLock, capsLockFlag, capsLockFlag), 63: (.function, functionFlag, functionFlag),
    ]
    /// 所有左右修饰键的设备相关位。
    static let deviceBits: UInt = 0x01 | 0x02 | 0x04 | 0x08 | 0x10 | 0x20 | 0x40 | 0x2000

    static let special: [UInt16: KeyEvent.Key] = [
        36: .enter, 76: .enter, 48: .tab, 49: .space, 51: .backspace, 53: .escape,
        123: .left, 124: .right, 125: .down, 126: .up, 116: .pageUp, 121: .pageDown,
        117: .other, 115: .other, 119: .other, 114: .other, // 向前删除、Home、End、Help
    ]

    /// - Parameters:
    ///   - flagsChanged: 是 flagsChanged 事件（单独按下 / 松开修饰键）而不是 keyDown。
    ///   - characters: NSEvent.characters（已按键盘布局和 Shift 处理过）。
    public static func translate(keyCode: UInt16, characters: String?, modifierFlags raw: UInt, flagsChanged: Bool) -> KeyEvent? {
        var flags: KeyEvent.Flags = []
        if raw & shiftFlag != 0 { flags.insert(.shift) }
        if raw & controlFlag != 0 { flags.insert(.control) }
        if raw & optionFlag != 0 { flags.insert(.option) }
        if raw & commandFlag != 0 { flags.insert(.command) }
        if raw & capsLockFlag != 0 { flags.insert(.capsLock) }

        if flagsChanged {
            guard let (m, device, independent) = modifiers[keyCode] else { return nil }
            // 真实键盘会带上区分左右的设备位；屏幕共享、远程桌面、辅助工具合成的事件常常没有，
            // 这时退回看设备无关位（分不清左右，但足以判断按下还是松开）。
            let down = raw & deviceBits != 0 || device == independent ? raw & device != 0 : raw & independent != 0
            return KeyEvent(down ? .modifierDown(m) : .modifierUp(m), flags: flags)
        }
        if let k = special[keyCode] { return KeyEvent(k, flags: flags) }
        // 功能键 F1–F20 等的字符落在私有区 U+F700–U+F8FF
        guard let s = characters, let c = s.first, s.count == 1,
              !(0xF700...0xF8FF).contains(c.unicodeScalars.first!.value) else { return KeyEvent(.other, flags: flags) }
        if c == " " { return KeyEvent(.space, flags: flags) }
        if c.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) { return KeyEvent(.other, flags: flags) }
        return KeyEvent(.character(c), flags: flags)
    }
}
