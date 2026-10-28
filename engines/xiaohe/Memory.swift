import CryptoKit
import Foundation

/// 引擎记住的东西：用户改选过的词（下次放首位），和要求忘掉的词（不再出现）。
/// 存在引擎数据目录（LUOKE_IME_DATA）的 memory.json 里。忘掉的词存原文（顶层 ADR 0013）：设置窗口里列得出
/// "你忘掉过哪些"、能撤销；壳读同目录的 forgotten.json（引擎协议「forget_all」）。早先的版本只存了哈希的，
/// 还原不出原文，留着当拦截名单（legacy），列表里只报个数。
struct Memory {
    /// 按键 → 选过的词 → 次数
    var chosen: [String: [String: Int]] = [:]
    /// 按键 → 不再出现的词（原文）
    var forgotten: [String: Set<String>] = [:]
    /// 以前只存了哈希的忘掉的词：Memory.hash(按键, 词)
    var legacy: Set<String> = []

    /// 前 16 字节的十六进制。每次询问要对几百个候选算，不用 String(format:)（慢 20 倍，一次 8 µs）
    static func hash(_ keys: String, _ text: String) -> String {
        var out = [UInt8]()
        out.reserveCapacity(32)
        for b in SHA256.hash(data: Data((keys + "\u{1F}" + text).utf8)).prefix(16) {
            out.append(hexDigits[Int(b >> 4)])
            out.append(hexDigits[Int(b & 15)])
        }
        return String(decoding: out, as: UTF8.self)
    }
    private static let hexDigits = Array("0123456789abcdef".utf8)

    static var file: URL? {
        ProcessInfo.processInfo.environment["LUOKE_IME_DATA"].map { URL(fileURLWithPath: $0).appendingPathComponent("memory.json") }
    }

    /// 上次读入时记忆文件的修改时间；文件被删了或改了（比如 agent 直接编辑），下次询问前重新读。
    var loadedStamp: Date?

    static func stamp() -> Date? {
        file.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
    }

    mutating func reloadIfChanged() {
        if Memory.stamp() != loadedStamp { self = Memory.load() }
    }

    static func load() -> Memory {
        var m = Memory()
        m.loadedStamp = stamp()
        guard let url = file, let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return m }
        m.chosen = obj["chosen"] as? [String: [String: Int]] ?? [:]
        m.forgotten = (obj["forgotten"] as? [String: [String]] ?? [:]).mapValues(Set.init)
        m.legacy = Set(obj["forgotten_hashes"] as? [String] ?? [])
        return m
    }

    func save() {
        guard let url = Memory.file else { return }
        var obj: [String: Any] = ["chosen": chosen, "forgotten": forgotten.mapValues { $0.sorted() }]
        if !legacy.isEmpty { obj["forgotten_hashes"] = legacy.sorted() }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        // 先写临时文件再改名，写到一半退出也不会坏
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".memory.json.tmp")
        do {
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    /// 存盘，并记下新的修改时间（免得下次询问把自己刚写的又读一遍）；同时更新给壳看的 forgotten.json。
    mutating func persist() {
        save()
        writeForgottenList()
        loadedStamp = Memory.stamp()
    }

    /// 壳的设置窗口列"你忘掉过哪些"用：{"forgotten": [{"input", "text"}], "older": 只存了哈希、列不出来的个数}。
    func writeForgottenList() {
        guard let dir = Memory.file?.deletingLastPathComponent() else { return }
        let items = forgotten.keys.sorted().flatMap { k in forgotten[k]!.sorted().map { ["input": k, "text": $0] } }
        let obj: [String: Any] = ["forgotten": items, "older": legacy.count]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        let url = dir.appendingPathComponent("forgotten.json"), tmp = dir.appendingPathComponent(".forgotten.json.tmp")
        if (try? data.write(to: tmp)) != nil { _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp) }
    }

    /// 用户选了不是首位的词：记一次。
    mutating func choose(keys: String, text: String) {
        chosen[keys, default: [:]][text, default: 0] += 1
        unforget(keys: keys, text: text)
    }

    mutating func forget(keys: String, text: String) {
        chosen[keys]?[text] = nil
        if chosen[keys]?.isEmpty == true { chosen[keys] = nil }
        forgotten[keys, default: []].insert(text)
    }

    /// 撤销忘掉（用户在设置窗口里点了撤销，或者又选了它）。
    mutating func unforget(keys: String, text: String) {
        forgotten[keys]?.remove(text)
        if forgotten[keys]?.isEmpty == true { forgotten[keys] = nil }
        if !legacy.isEmpty { legacy.remove(Memory.hash(keys, text)) }
    }

    /// 这串键选过的词，次数多的在前。
    func remembered(_ keys: String) -> [String] {
        (chosen[keys] ?? [:]).sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.map(\.key)
    }

    func isForgotten(_ keys: String, _ text: String) -> Bool {
        forgotten[keys]?.contains(text) == true || (!legacy.isEmpty && legacy.contains(Memory.hash(keys, text)))
    }
}
