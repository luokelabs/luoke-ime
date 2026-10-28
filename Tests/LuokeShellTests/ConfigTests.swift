import Foundation
import Testing
@testable import LuokeShell

/// 设置第 2 版：全局默认、按应用覆盖、记住上次模式、从第 1 版迁移（luokelabs/luoke-ime#1）。
@Suite struct 设置 {
    static func parse(_ json: String) -> ShellConfig {
        ShellConfig.parse(try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
    }

    @Test func 第1版的应用例外换成按应用覆盖_记忆授权和暂停照旧() {
        let c = Self.parse(#"""
        {"app_exceptions": {"com.a": {"no_inline": true, "english": true, "no_record": true, "no_predict": true},
                            "com.b": {"no_inline": false, "english": false, "no_record": false, "no_predict": false}},
         "predict": false, "auto_space": true, "current_engine": "quanpin",
         "recording": {"paused": true, "memory_consent": ["personal"], "memory_asked": ["personal"]}}
        """#)
        #expect(c.migratedFromV1)
        #expect(c.apps["com.a"] == .init(english: true, inline: false, predict: false, noRecord: true))
        #expect(c.apps["com.b"] == nil) // 全是默认值的不留
        #expect(!c.settings.predict && c.settings.autoSpace && c.currentEngine == "quanpin")
        #expect(c.recordingPaused && c.memoryConsent == ["personal"] && c.memoryAsked == ["personal"])
        #expect(!c.defaultEnglish && c.rememberMode && c.inline) // 新的全局默认：中文、记住上次模式、拼音在输入框里
    }

    @Test func 第2版存了再读回来一样_重复读不再迁移() throws {
        var c = ShellConfig()
        c.defaultEnglish = true
        c.inline = false
        c.settings.predict = false
        c.apps["com.a"] = .init(english: false, predict: true)
        c.apps["com.b"] = .init(noRecord: true)
        c.appModes["com.c"] = true
        c.recordingPaused = true
        c.memoryConsent = ["personal"]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("luoke-ime-tests-\(UUID().uuidString)/settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try c.save(url)
        let back = ShellConfig.load(url)
        #expect(back == c)
        #expect(!back.migratedFromV1)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(#""version" : 2"#) && !text.contains("app_exceptions"))
    }

    @Test func 终端里默认不联想_应用设置里能打开() {
        var c = ShellConfig()
        #expect(c.predict(for: "com.apple.TextEdit"))
        #expect(!c.predict(for: "com.apple.Terminal"))
        c.apps["com.apple.Terminal"] = ShellConfig.AppSettings(predict: true)
        #expect(c.predict(for: "com.apple.Terminal"))
    }

    @Test func 菜单里切联想按实际状态反过来_回到跟随时去掉覆盖() {
        var c = ShellConfig()
        // 终端：跟随是关，点一下打开（写显式的 true），再点回到跟随
        c.togglePredict(app: "com.apple.Terminal")
        #expect(c.predict(for: "com.apple.Terminal"))
        #expect(c.app("com.apple.Terminal").predict == true)
        c.togglePredict(app: "com.apple.Terminal")
        #expect(!c.predict(for: "com.apple.Terminal"))
        #expect(c.apps["com.apple.Terminal"] == nil)
        // 普通应用：跟随是开，点一下关（显式的 false），再点回到跟随
        c.togglePredict(app: "com.apple.TextEdit")
        #expect(!c.predict(for: "com.apple.TextEdit"))
        #expect(c.app("com.apple.TextEdit").predict == false)
        c.togglePredict(app: "com.apple.TextEdit")
        #expect(c.predict(for: "com.apple.TextEdit"))
        #expect(c.apps["com.apple.TextEdit"] == nil)
    }

    @Test func 花括号打成直角引号的设置存了再读回来一样() {
        var c = ShellConfig()
        #expect(c.settings.cornerBraces) // 默认开
        c.settings.cornerBraces = false
        #expect(!ShellConfig.parse(c.json).settings.cornerBraces)
    }

    @Test func 不认识的键原样写回_回滚到旧版再换回来不丢() {
        // 新版写下、这一版不认识的键（顶层和 recording 里的）存盘时照写回去（luokelabs/luoke-core#12）
        var c = Self.parse(#"{"version":2,"future":{"a":[1,"x"]},"recording":{"paused":false,"future_flag":true}}"#)
        c.recordingPaused = true
        let back = ShellConfig.parse(c.json)
        #expect(back.unknown["future"] == JSONValue(["a": [1, "x"]]))
        #expect(back.unknownRecording["future_flag"] == .bool(true))
        #expect(back.recordingPaused)
        #expect(back.unknown["recording"] == nil)
    }

    @Test func 应用没写的项跟随全局_按项继承() {
        var c = ShellConfig()
        c.apps["com.a"] = .init(english: true)
        #expect(c.defaultEnglish(for: "com.a") && c.inline(for: "com.a") && c.predict(for: "com.a"))
        c.inline = false
        c.settings.predict = false
        #expect(!c.inline(for: "com.a") && !c.predict(for: "com.a") && c.defaultEnglish(for: "com.a")) // 只覆盖了中英文
        #expect(!c.defaultEnglish(for: "com.other") && !c.defaultEnglish(for: nil))
        c.apps["com.b"] = .init(predict: true)
        #expect(c.predict(for: "com.b")) // 全局关、应用开
    }

    @Test func 恢复跟随全局就删掉整条() {
        var c = ShellConfig()
        c.setApp("com.a") { $0.noRecord = true }
        #expect(c.noRecord(for: "com.a"))
        c.setApp("com.a") { $0 = .init() }
        #expect(c.apps["com.a"] == nil)
    }

    @Test func 记住上次模式_重启以后也记得_和默认一样的不存() {
        var c = ShellConfig()
        #expect(c.englishOnEnter(app: "com.a", lastApp: nil, inMemory: nil) == false)
        c.noteMode(english: true, for: "com.a")
        #expect(c.appModes == ["com.a": true])
        let restarted = Self.parse(String(data: try! JSONSerialization.data(withJSONObject: c.json), encoding: .utf8)!)
        #expect(restarted.englishOnEnter(app: "com.a", lastApp: "com.b", inMemory: nil) == true)
        c.noteMode(english: false, for: "com.a")
        #expect(c.appModes.isEmpty)
    }

    @Test func 不记上次模式_换应用用默认值_同一应用换输入框不变() {
        var c = ShellConfig()
        c.setRememberMode(false)
        c.noteMode(english: true, for: "com.a")
        #expect(c.appModes.isEmpty)
        #expect(c.englishOnEnter(app: "com.a", lastApp: "com.a", inMemory: true) == true) // 同一个应用、换了输入框
        #expect(c.englishOnEnter(app: "com.a", lastApp: "com.b", inMemory: true) == false) // 换回来：用默认值
        c.apps["com.a"] = .init(english: true)
        #expect(c.englishOnEnter(app: "com.a", lastApp: "com.b", inMemory: false) == true)
    }

    @Test func 改全局默认只清跟随全局的应用记着的模式() {
        var c = ShellConfig()
        c.apps["com.own"] = .init(english: false)
        c.noteMode(english: true, for: "com.follow")
        c.noteMode(english: true, for: "com.own")
        c.setDefaultEnglish(true)
        #expect(c.appModes["com.follow"] == nil) // 跟随全局的：下次进去用新的默认（英文）
        #expect(c.appModes["com.own"] == true)   // 自己设了的不动
        #expect(c.englishOnEnter(app: "com.follow", lastApp: nil, inMemory: nil) == true)
    }

    @Test func 改某个应用的默认模式清掉它记着的() {
        var c = ShellConfig()
        c.noteMode(english: true, for: "com.a")
        c.setApp("com.a") { $0.english = false }
        #expect(c.appModes["com.a"] == nil)
        #expect(c.englishOnEnter(app: "com.a", lastApp: nil, inMemory: nil) == false)
    }

    @Test func 关掉记住上次模式时清掉记着的() {
        var c = ShellConfig()
        c.noteMode(english: true, for: "com.a")
        c.setRememberMode(false)
        #expect(c.appModes.isEmpty)
        #expect(!(c.json["app_modes"] as! [String: String]).keys.contains("com.a"))
    }
}
