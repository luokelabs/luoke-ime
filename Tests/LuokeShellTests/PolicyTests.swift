import Foundation
import Testing
@testable import LuokeShell

/// 什么能交给个人化组件（PersonalPolicy，顶层 ADR 0013）：整张表逐格核对。
@Suite struct 交给个人化组件的规矩 {
    typealias D = PersonalPolicy.Decision
    static func d(third: Bool = false, secure: Bool = false, stopped: Bool = false, on: Bool = true) -> D {
        PersonalPolicy.decide(.init(thirdParty: third, secureInput: secure, userStopped: stopped, enabled: on))
    }

    @Test func 安全输入时什么都不给() {
        #expect(Self.d(secure: true) == .none)
        #expect(Self.d(third: true, secure: true) == .none)
    }

    @Test func 自带的组件() {
        #expect(Self.d() == D(forwardEvents: true, typingFeedback: true, relayAsks: true, predict: true, devRecording: true))
        // 关了记忆记录：不写记忆，打分、联想照常（自带的不存这些请求的内容），引擎照常学改选
        #expect(Self.d(on: false) == D(forwardEvents: false, typingFeedback: true, relayAsks: true, predict: true, devRecording: true))
        // 禁止记录的应用、暂停：哪里都不记，打分、联想照常
        #expect(Self.d(stopped: true) == D(forwardEvents: false, typingFeedback: false, relayAsks: true, predict: true, devRecording: false))
    }

    @Test func 第三方的组件_要同意又能记才给() {
        #expect(Self.d(third: true) == D(forwardEvents: true, typingFeedback: true, relayAsks: true, predict: true, devRecording: true))
        #expect(Self.d(third: true, on: false) == D(forwardEvents: false, typingFeedback: true, relayAsks: false, predict: false, devRecording: true))
        #expect(Self.d(third: true, stopped: true) == D(forwardEvents: false, typingFeedback: false, relayAsks: false, predict: false, devRecording: false))
    }
}

@Suite struct 记忆记录的开关 {
    static func parse(_ json: String) -> ShellConfig {
        ShellConfig.parse(try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
    }

    @Test func 自带的默认开_第三方的要同意() {
        let c = ShellConfig()
        #expect(c.memoryEnabled(key: "personal", bundled: true))
        #expect(!c.memoryEnabled(key: "mine@abc", bundled: false))
    }

    @Test func 以前问过没开的照旧关着_同意过的开着_没问过的开() {
        let asked = Self.parse(#"{"version":2,"recording":{"memory_consent":[],"memory_asked":["personal"]}}"#)
        #expect(!asked.memoryEnabled(key: "personal", bundled: true))
        let yes = Self.parse(#"{"version":2,"recording":{"memory_consent":["personal"],"memory_asked":["personal"]}}"#)
        #expect(yes.memoryEnabled(key: "personal", bundled: true))
        let never = Self.parse(#"{"version":2,"recording":{"memory_consent":[],"memory_asked":[]}}"#)
        #expect(never.memoryEnabled(key: "personal", bundled: true))
    }

    @Test func 关了再开_存回去读得一样() {
        var c = ShellConfig()
        c.setMemory(key: "personal", bundled: true, on: false)
        #expect(!c.memoryEnabled(key: "personal", bundled: true))
        let back = Self.parse(String(data: try! JSONSerialization.data(withJSONObject: c.json), encoding: .utf8)!)
        #expect(!back.memoryEnabled(key: "personal", bundled: true))
        c.setMemory(key: "personal", bundled: true, on: true)
        #expect(c.memoryEnabled(key: "personal", bundled: true))
    }
}
