import Foundation
import LuokeShell

/// `luoke-ime replay`：把一段输入记录重放给引擎，逐键打印结果，并和记录里当时的答复对比。
func runReplay(record: URL, engineDir: URL?, sandboxed: Bool, fast: Bool) -> Int32 {
    let entries: [(t: TimeInterval, kind: Recorder.Kind, data: Any)]
    do { entries = try Recorder.read(record) } catch {
        FileHandle.standardError.write(Data("读不了输入记录：\(error)\n".utf8))
        return 2
    }
    let header = entries.first { $0.kind == .context }?.data as? [String: Any]
    guard let dir = engineDir ?? (header?["engine"] as? String).map({ URL(fileURLWithPath: $0) }) else {
        FileHandle.standardError.write(Data("记录里没有引擎位置，请用 --engine 指定\n".utf8))
        return 2
    }
    let keys = entries.compactMap { e -> (TimeInterval, KeyEvent)? in
        guard e.kind == .key, let m = e.data as? [String: Any], let k = KeyEvent(json: m) else { return nil }
        return (e.t, k)
    }

    // 新的一次运行也记下来，用于对比答复
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("luoke-ime-replay-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    var o = TryOptions()
    o.engineDir = dir
    o.context = header?["document"] as? String ?? ""
    o.app = header?["app"] as? String
    o.sandboxed = sandboxed
    let trial: Trial
    do {
        trial = try Trial(o)
        let r = try Recorder(directory: scratch)
        trial.typing.recorder = r
        trial.recorder = r
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        return 2
    }
    defer { trial.shutdown() }

    print("重放 \(record.lastPathComponent)：\(keys.count) 个键，引擎 \(trial.typing.manifest.name)（\(dir.path)）\(fast ? "，不按原来的节奏" : "")")
    trial.settle()
    let start = ProcessInfo.processInfo.systemUptime
    let t0 = keys.first?.0 ?? 0
    for (t, e) in keys {
        if !fast {
            let due = start + (t - t0)
            while ProcessInfo.processInfo.systemUptime < due {
                let now = ProcessInfo.processInfo.systemUptime
                trial.channel.wait(until: min(trial.session.nextDeadline ?? due, due, now + 0.05))
                trial.service()
            }
        }
        trial.feed(e)
        if fast { trial.settle() } else { trial.service() }
        let doc = trial.client.document.replacingOccurrences(of: "\n", with: "⏎")
        let label = describe(e)
        print("\(label.padding(toLength: max(8, label.count), withPad: " ", startingAt: 0)) \(summarizeView(trial.client.view))  输入框：「\(doc)」")
    }
    trial.settle()

    // 对比：按询问的先后，看每次询问最终答复的首选是否和当时一样
    let before = finalTops(entries)
    let after = finalTops((try? Recorder.read(trial.recorder!.url)) ?? [])
    var diffs: [String] = []
    for (i, (a, b)) in zip(before, after).enumerated() where a != b {
        diffs.append("第 \(i + 1) 次询问 \(a.input)：当时首选「\(a.top ?? "无")」，现在「\(b.input == a.input ? b.top ?? "无" : "（询问不同：\(b.input)）")」")
    }
    print("\n对比：当时 \(before.count) 次询问，这次 \(after.count) 次；首选不同的 \(diffs.count) 次")
    diffs.prefix(20).forEach { print("  " + $0) }
    return 0
}

private struct Asked: Equatable {
    var input: String
    var top: String?
}

/// 从输入记录里取出每次询问（按发送顺序）及其最后一次答复的首选。
private func finalTops(_ entries: [(t: TimeInterval, kind: Recorder.Kind, data: Any)]) -> [Asked] {
    var order: [Int] = []
    var asked: [Int: Asked] = [:]
    for e in entries {
        guard let line = e.data as? String, let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = obj["id"] as? Int else { continue }
        if e.kind == .toEngine, obj["type"] as? String == "query", let input = obj["input"] as? String {
            order.append(id)
            asked[id] = Asked(input: input, top: nil)
        } else if e.kind == .fromEngine, obj["type"] as? String == "answer", asked[id] != nil {
            asked[id]!.top = ((obj["candidates"] as? [[String: Any]])?.first?["text"] as? String)
        }
    }
    return order.map { asked[$0]! }
}
