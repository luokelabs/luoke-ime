import Foundation
import Testing
@testable import LuokeShell

@Suite("使用计数") struct UsageTests {
    @Test func 按天合计_写盘再读回_只留90天() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let u = Usage(url: url, now: { clock })
        u.add(.commit, 3)
        clock += 86_400
        u.add(.commit)
        u.add(.predictShown)
        #expect(u.total(lastDays: 1) == [.commit: 1, .predictShown: 1])
        #expect(u.total(lastDays: 2) == [.commit: 4, .predictShown: 1])
        u.flush()
        #expect(Usage(url: url, now: { clock }).total(lastDays: 2) == [.commit: 4, .predictShown: 1])
        clock += 90 * 86_400
        u.add(.commit)
        u.flush()
        #expect(Usage(url: url, now: { clock }).total(lastDays: 200) == [.commit: 1])
        u.reset()
        #expect(Usage(url: url, now: { clock }).total(lastDays: 200).isEmpty)
    }
}
