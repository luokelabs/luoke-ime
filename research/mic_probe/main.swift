// 录音探测：在壳的沙盒里按住右 ⌥ 录音（按下收到 arm 就开始录），松开后把录到的情况作为文字上屏（时长、采样率、音量、出错信息），
// 用来实测声明了麦克风的快捷键引擎能不能真的录到声音（research/seatbelt 只测到服务可达，没真录过）。
// 不存音频，只算音量；不联网。   swiftc -O -o mic_probe main.swift
import AVFoundation
import Foundation

func send(_ m: [String: Any]) {
    let d = try! JSONSerialization.data(withJSONObject: m)
    FileHandle.standardOutput.write(d + Data("\n".utf8))
}

final class Probe {
    let engine = AVAudioEngine()
    let lock = NSLock()
    var frames = 0, sum = 0.0, peak: Float = 0, rate = 0.0, started = Date()
    var error: String?

    func start() {
        lock.lock(); frames = 0; sum = 0; peak = 0; error = nil; started = Date(); lock.unlock()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        rate = format.sampleRate
        guard format.channelCount > 0, rate > 0 else { error = "没有输入设备（声道 \(format.channelCount)，采样率 \(rate)）"; return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData?[0] else { return }
            var s = 0.0, p: Float = 0
            for i in 0..<Int(buf.frameLength) { let v = ch[i]; s += Double(v * v); p = max(p, abs(v)) }
            self.lock.lock(); self.frames += Int(buf.frameLength); self.sum += s; self.peak = max(self.peak, p); self.lock.unlock()
        }
        do { try engine.start() } catch { self.error = "启动录音失败：\(error)" }
    }

    /// 预先分配好录音要用的东西，下一次 start 快一些（不开麦克风）。
    func prepare() {
        _ = engine.inputNode
        engine.prepare()
    }

    func summary() -> String {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        defer { prepare() }
        lock.lock(); defer { lock.unlock() }
        let auth = ["0": "未询问", "1": "受限", "2": "已拒绝", "3": "已允许"]["\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)"] ?? "?"
        if let error { return "录音探测：\(error)；授权 \(auth)" }
        let secs = rate > 0 ? Double(frames) / rate : 0
        let rms = frames > 0 ? (sum / Double(frames)).squareRoot() : 0
        return String(format: "录音探测：从开始录到松开 %.2f 秒，录到 %.2f 秒，采样率 %.0f，音量 RMS %.4f，峰值 %.4f；授权 %@",
                      Date().timeIntervalSince(started), secs, rate, rms, Double(peak), auth)
    }
}

let probe = Probe()
probe.prepare()
var current: Int?
while let line = readLine() {
    guard let m = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let type = m["type"] as? String else { continue }
    let id = m["id"] as? Int
    switch type {
    case "arm": // 按下就开始录（引擎说明里 hotkey.arm）；没确认是按住会收到 cancel
        current = id
        probe.start()
    case "start":
        if current != id { // 没声明 arm、或者 arm 的号对不上：现在才开始录
            current = id
            probe.start()
        }
        send(["type": "show", "id": id ?? 0, "text": "录音中…"])
    case "stop":
        guard let id, id == current else { continue }
        send(["type": "commit", "id": id, "text": probe.summary()])
        current = nil
    case "cancel":
        if current != nil { _ = probe.summary() }
        current = nil
    default:
        break
    }
}
