import Testing
@testable import LuokeShell

@Suite struct 系统按键翻译 {
    let shift: UInt = 1 << 17, command: UInt = 1 << 20, caps: UInt = 1 << 16

    @Test func 普通字符和特殊键() {
        #expect(MacKeys.translate(keyCode: 0, characters: "a", modifierFlags: 0, flagsChanged: false) == .char("a"))
        #expect(MacKeys.translate(keyCode: 0, characters: "A", modifierFlags: shift, flagsChanged: false) == .char("A", flags: .shift))
        #expect(MacKeys.translate(keyCode: 49, characters: " ", modifierFlags: 0, flagsChanged: false) == KeyEvent(.space))
        #expect(MacKeys.translate(keyCode: 36, characters: "\r", modifierFlags: 0, flagsChanged: false) == KeyEvent(.enter))
        #expect(MacKeys.translate(keyCode: 51, characters: "\u{7f}", modifierFlags: shift, flagsChanged: false) == KeyEvent(.backspace, flags: .shift))
        #expect(MacKeys.translate(keyCode: 124, characters: "\u{F703}", modifierFlags: 0, flagsChanged: false) == KeyEvent(.right))
        #expect(MacKeys.translate(keyCode: 122, characters: "\u{F704}", modifierFlags: 0, flagsChanged: false) == KeyEvent(.other)) // F1
        #expect(MacKeys.translate(keyCode: 8, characters: "c", modifierFlags: command, flagsChanged: false) == .char("c", flags: .command))
        #expect(MacKeys.translate(keyCode: 43, characters: "，", modifierFlags: 0, flagsChanged: false) == .char("，"))
    }

    @Test func 单独按下和松开修饰键() {
        // 左 Shift 按下：设备无关位 + 设备相关位 0x02
        #expect(MacKeys.translate(keyCode: 56, characters: nil, modifierFlags: shift | 0x02, flagsChanged: true) == KeyEvent(.modifierDown(.leftShift), flags: .shift))
        #expect(MacKeys.translate(keyCode: 56, characters: nil, modifierFlags: 0, flagsChanged: true) == KeyEvent(.modifierUp(.leftShift)))
        // 按住左 Shift 时按下右 Shift，再松开右 Shift
        #expect(MacKeys.translate(keyCode: 60, characters: nil, modifierFlags: shift | 0x02 | 0x04, flagsChanged: true)?.key == .modifierDown(.rightShift))
        #expect(MacKeys.translate(keyCode: 60, characters: nil, modifierFlags: shift | 0x02, flagsChanged: true)?.key == .modifierUp(.rightShift))
        #expect(MacKeys.translate(keyCode: 54, characters: nil, modifierFlags: command | 0x10, flagsChanged: true)?.key == .modifierDown(.rightCommand))
        #expect(MacKeys.translate(keyCode: 57, characters: nil, modifierFlags: caps, flagsChanged: true)?.key == .modifierDown(.capsLock))
        #expect(MacKeys.translate(keyCode: 99, characters: nil, modifierFlags: 0, flagsChanged: true) == nil)
    }

    @Test func 合成事件没有设备位时看设备无关位() {
        // 屏幕共享、远程桌面、辅助工具合成的 Shift：只有设备无关的 Shift 位
        #expect(MacKeys.translate(keyCode: 56, characters: nil, modifierFlags: shift, flagsChanged: true)?.key == .modifierDown(.leftShift))
        #expect(MacKeys.translate(keyCode: 56, characters: nil, modifierFlags: 0, flagsChanged: true)?.key == .modifierUp(.leftShift))
        #expect(MacKeys.translate(keyCode: 54, characters: nil, modifierFlags: command, flagsChanged: true)?.key == .modifierDown(.rightCommand))
    }
}
