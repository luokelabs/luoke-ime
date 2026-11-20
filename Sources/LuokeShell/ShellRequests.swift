import Foundation

/// 设置页（`luoke-ime mcp`，一个请求一个进程）要正在运行的输入法做的事：清除已学词语、恢复已忘记的词语、清零使用统计。
/// 这几样只有输入法进程做得了（要经运行中的打字引擎，使用计数也攒在它的内存里），所以在 `~/.luoke/ime/requests/`
/// 放一个请求文件；输入法每秒看一次，取走（删掉请求文件）、做完，写回 `<编号>.done`。设置页等答复，等不到就取回请求、
/// 答「输入法没在运行」，免得输入法之后才做、用户已经看到失败。
public enum ShellRequests {
    public struct Request: Equatable {
        public var id: String
        public var op: String
        public var args: [String: String]
    }

    /// 请求放了这么久还没被取走就作废（输入法刚起来时不做很早以前的请求）。
    public static let staleAfter: TimeInterval = 10

    public static func dir(_ paths: Paths) -> URL { paths.root.appendingPathComponent("requests") }

    /// 设置页这边：放一个请求，等输入法答复。输入法没在运行（超时还没取走）时返回 nil。
    public static func submit(_ paths: Paths, op: String, args: [String: String] = [:], timeout: TimeInterval = 3) -> [String: Any]? {
        let fm = FileManager.default
        let d = dir(paths)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let request = d.appendingPathComponent("\(id).json"), done = d.appendingPathComponent("\(id).done")
        var o: [String: Any] = args
        o["op"] = op
        guard let data = try? JSONSerialization.data(withJSONObject: o), (try? data.write(to: request, options: .atomic)) != nil else { return nil }
        if let r = wait(done, until: Date().addingTimeInterval(timeout)) { return r }
        // 超时：删得掉说明输入法还没取走，不再做；删不掉说明它刚取走，再等一会儿答复
        if (try? fm.removeItem(at: request)) != nil { return nil }
        return wait(done, until: Date().addingTimeInterval(timeout))
    }

    private static func wait(_ done: URL, until end: Date) -> [String: Any]? {
        while true {
            if let d = try? Data(contentsOf: done), let r = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                try? FileManager.default.removeItem(at: done)
                return r
            }
            if Date() >= end { return nil }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// 输入法这边：取走所有请求（删掉请求文件），过期的、读不懂的直接丢掉；顺带清掉没人来拿的旧答复。
    public static func take(_ paths: Paths, now: Date = Date()) -> [Request] {
        let fm = FileManager.default
        let d = dir(paths)
        guard let names = try? fm.contentsOfDirectory(atPath: d.path), !names.isEmpty else { return [] }
        var out: [Request] = []
        for name in names.sorted() {
            let url = d.appendingPathComponent(name)
            let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? now
            if name.hasSuffix(".done") {
                if now.timeIntervalSince(date) > 60 { try? fm.removeItem(at: url) }
                continue
            }
            guard name.hasSuffix(".json") else { continue }
            let data = try? Data(contentsOf: url)
            guard (try? fm.removeItem(at: url)) != nil else { continue } // 设置页已经取回了
            guard now.timeIntervalSince(date) <= staleAfter, let data,
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let op = o["op"] as? String else { continue }
            var args: [String: String] = [:]
            for (k, v) in o where k != "op" { if let s = v as? String { args[k] = s } }
            out.append(Request(id: String(name.dropLast(".json".count)), op: op, args: args))
        }
        return out
    }

    /// 输入法这边：写回答复。
    public static func answer(_ paths: Paths, _ id: String, _ result: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: result) else { return }
        try? data.write(to: dir(paths).appendingPathComponent("\(id).done"), options: .atomic)
    }
}
