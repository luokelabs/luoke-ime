// 语音引擎：按住右 ⌥ 说话，松开上屏。录音在引擎里，识别交给主控的 luoke-ime.transcribe 任务（经壳转问，ADR 0016）。
//
// - 按下收到 arm 就开始录（16 kHz 单声道 PCM16），收到 cancel 就丢掉；确认按住（start）后开一个转写会话。
// - 按住期间每隔一会儿（内存 24 GB 及以下的 Mac 1 秒，别的 0.5 秒）送一块新录的音频、要一份草稿，用 show 显示（不上屏）；同一时间只有
//   一份草稿在算。新草稿多出来的字在接下来的一小段时间里逐字补出来，不一组一组地跳。
// - 松开（stop）送最后一块、要终稿，commit 上屏；没识别出字就 end。
// - 主控答 session_lost 就从 seq 0 重送整段；not_ready、busy 照 retry_after 原样重发；按下时请主控预热。
// - 终稿出来以后请主控整理（luoke-ime.tidy：去口头禅、理顺改口、数字和英文的写法，提示词是同目录的 tidy_prompt.txt），
//   整理完再上屏；出错或 2.5 秒没回来就上屏没整理的终稿。选项 tidy 为 false 时不整理。
// - 上下文：记忆里的常用说法（热词，问个人化组件要），加上光标前的字接上前面各段原文的最后 300 字。
// - 音频只在内存里，会话结束就丢。不做 VAD，只按声音大小判断有没有说话。
//
//   swiftc -O -o voice main.swift
// 测试：选项 test_wav（或环境变量 LUOKE_VOICE_WAV）给一个 16 kHz 单声道 PCM16 的 WAV，就不开麦克风，按住时把这个文件
// 按实时速度当成录到的声音。
import AudioToolbox
import CoreAudio
import IOKit
import Foundation

let task = "luoke-ime.transcribe"
let tidyTask = "luoke-ime.tidy"
let tidyPrompt = try? String(contentsOfFile: "tidy_prompt.txt", encoding: .utf8) // 引擎在自己的目录里运行
/// 示例：一问一答几轮，放在提示词和原文之间（9B 看示例比看规则管用）。
let tidyExamples = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "tidy_examples.json")))) as? [[String]] ?? []
/// 内存 24 GB 及以下的 Mac（和壳的 ShellConfig.voiceTidyDefault 一样按内存分；主控报的档位只能展示，不能据此决定行为）。
let smallMac = ProcessInfo.processInfo.physicalMemory <= 24 << 30
/// 整理不整理：壳照设置用选项 tidy 交给引擎；没给时（命令行版）小内存的 Mac 默认不整理（底座和转写二选一，
/// 每次整理要重新加载 9B，16 GB 测试机上实测 8–10 秒，就算底座在也要 3.4 秒，超过 tidyWait）。
var tidyEnabled = !smallMac
/// 多久要一份草稿：小内存的 Mac 1 秒（M1 上一份草稿要 0.2–0.5 秒），别的 0.5 秒。
let draftInterval = smallMac ? 1.0 : 0.5
var lastDraftAt = Date.distantPast
/// 光标处正显示的草稿和要补到的草稿（逐字补出来）。
var displayed = "", target = ""
/// 整理最多等多久，过了就上屏没整理的终稿（壳 stop 之后最多等 10 秒）。
let tidyWait = 2.5
let q = DispatchQueue(label: "voice")   // 下面的状态都只在这个队列上读写

func send(_ m: [String: Any]) {
    let d = try! JSONSerialization.data(withJSONObject: m)
    FileHandle.standardOutput.write(d + Data("\n".utf8))
}

func log(_ s: String) { FileHandle.standardError.write(Data("语音：\(s)\n".utf8)) }

// MARK: - 录音

/// 系统的音频设备（CoreAudio）：默认输入是不是蓝牙耳机、有没有内置麦克风。
enum Audio {
    /// 一个 UInt32 的属性（设备号、传输类型都是）。
    static func u32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func transport(_ dev: AudioDeviceID) -> UInt32? { u32(dev, kAudioDevicePropertyTransportType) }

    /// 设备的输入音量（系统设置 › 声音 › 输入的那根滑杆，0–1）；没有这个属性的设备为 nil。只读，不替用户改。
    static func inputVolume(_ dev: AudioDeviceID) -> Float32? {
        for el in [kAudioObjectPropertyElementMain, 1] {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeInput, mElement: el)
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectHasProperty(dev, &addr), AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr { return v }
        }
        return nil
    }

    static func hasInput(_ dev: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr && size > 0
    }

    static func devices() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// 设备的 UID（AudioQueue 按它选设备）。
    static func uid(_ dev: AudioDeviceID) -> CFString? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var v: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v?.takeRetainedValue()
    }

    /// MacBook 合着盖吗（合着时内置麦克风在硬件上断开）；读不到（沙盒不让、台式机没有这一项）时为 nil。
    static func lidClosed() -> Bool? {
        let pm = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard pm != 0 else { return nil }
        defer { IOObjectRelease(pm) }
        return IORegistryEntryCreateCFProperty(pm, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    /// 默认输入是蓝牙的、又有内置麦克风、盖子没合着时，返回内置麦克风；否则 nil（照默认输入）。
    /// 合着盖的话直接用耳机，不用先试 0.3 秒内置麦克风（那一下开头的话就丢了）。
    static func builtInInsteadOfBluetooth() -> AudioDeviceID? {
        guard let def = u32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice), def != 0,
              let t = transport(def), t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE else { return nil }
        guard let mic = devices().first(where: { transport($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }) else { return nil }
        if lidClosed() == true { log("合着盖：照默认输入（蓝牙耳机）录"); return nil }
        return mic
    }
}

/// 录到的 16 kHz 单声道 PCM16，交给 onAudio（在 q 上）。
///
/// 用 AudioQueue 只开输入设备，不用 AVAudioEngine：AVAudioEngine 的输入会和默认输出拼成一个聚合设备，默认输出是 AirPods 时
/// 耳机被切到通话模式（声音突然变大、只剩电话音质），松开后也不恢复，因为聚合设备跟着系统的默认设备一直在重建（试用时遇到）。
/// 只在按下时才打开，松开就关掉、释放，空着时不碰任何音频设备。默认输入是蓝牙耳机、机器上又有内置麦克风时，
/// 用内置麦克风录，耳机不用切模式（选项 bluetooth_mic 为 true 时照系统的默认输入）。
final class Recorder {
    private var queue: AudioQueueRef?
    private let aq = DispatchQueue(label: "voice.audioqueue")
    var onAudio: (Data) -> Void = { _ in }
    private var wavTimer: DispatchSourceTimer?
    /// 测试用的 WAV（选项 test_wav，或环境变量 LUOKE_VOICE_WAV）：有它就不开麦克风。
    var wav = ProcessInfo.processInfo.environment["LUOKE_VOICE_WAV"]
    /// 默认输入是蓝牙耳机时也用它（选项 bluetooth_mic）。
    var bluetoothMic = false
    /// 这次改用了内置麦克风，还在看它是不是一直是零（MacBook 合着盖时内置麦克风在硬件上断开，录到的全是零）。
    private var watchingBuiltIn = false
    private var zeroBytes = 0
    /// 正在录的输入设备（读它的输入音量用）；按 WAV 测试时为 nil。
    private(set) var device: AudioDeviceID?

    func start() { start(builtIn: !bluetoothMic) }

    /// builtIn：默认输入是蓝牙耳机、又有内置麦克风时，改用内置麦克风。
    private func start(builtIn: Bool) {
        if let wav { return startFile(wav) }
        stop()
        watchingBuiltIn = false
        zeroBytes = 0
        var fmt = AudioStreamBasicDescription(mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                              mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                                              mBitsPerChannel: 16, mReserved: 0)
        var ref: AudioQueueRef?
        let st = AudioQueueNewInputWithDispatchQueue(&ref, &fmt, 0, aq) { [weak self] aqRef, buf, _, _, _ in
            let n = Int(buf.pointee.mAudioDataByteSize)
            if n > 0, let self {
                let data = Data(bytes: buf.pointee.mAudioData, count: n)
                // 改用的内置麦克风开头 0.3 秒一直是零：多半是合着盖（或者内置麦克风被关了），换回默认输入（蓝牙耳机）录。
                // 耳机会切到通话模式，但总比什么都录不到好
                if self.watchingBuiltIn {
                    if data.contains(where: { $0 != 0 }) {
                        self.watchingBuiltIn = false
                    } else {
                        self.zeroBytes += n
                        if self.zeroBytes >= 9600 {
                            self.watchingBuiltIn = false
                            q.async {
                                log("内置麦克风录到的全是零（可能合着盖）：换回默认输入")
                                self.start(builtIn: false)
                            }
                        }
                    }
                }
                q.async { self.onAudio(data) }
            }
            AudioQueueEnqueueBuffer(aqRef, buf, 0, nil)
        }
        guard st == noErr, let ref else { return log("打不开录音（\(st)）：可能没有能录音的输入设备") }
        device = Audio.u32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        if builtIn, let dev = Audio.builtInInsteadOfBluetooth(), let uid = Audio.uid(dev) {
            var u = Unmanaged.passUnretained(uid) // 属性的值是 CFStringRef 本身（一个指针）
            let r = withUnsafePointer(to: &u) {
                AudioQueueSetProperty(ref, kAudioQueueProperty_CurrentDevice, $0, UInt32(MemoryLayout<Unmanaged<CFString>>.size))
            }
            log(r == noErr ? "默认输入是蓝牙耳机：改用内置麦克风录" : "改用内置麦克风没成（\(r)），照默认输入录")
            if r == noErr { device = dev }
            watchingBuiltIn = r == noErr
        }
        for _ in 0..<4 { // 每块 0.1 秒
            var b: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(ref, 3200, &b) == noErr, let b { AudioQueueEnqueueBuffer(ref, b, 0, nil) }
        }
        let r = AudioQueueStart(ref, nil)
        guard r == noErr else {
            AudioQueueDispose(ref, true)
            log("启动录音失败（\(r)）")
            if watchingBuiltIn { // 改用的内置麦克风开不了：换回默认输入再试一次
                watchingBuiltIn = false
                start(builtIn: false)
            }
            return
        }
        queue = ref
    }

    func stop() {
        wavTimer?.cancel()
        wavTimer = nil
        guard let q = queue else { return }
        queue = nil
        AudioQueueStop(q, true)
        AudioQueueDispose(q, true) // 连设备一起放掉
    }

    /// 测试用：把 WAV 的 data 块每 100 ms 送 3200 字节，像在实时录音。
    private func startFile(_ path: String) {
        guard let all = FileManager.default.contents(atPath: path), let r = all.range(of: Data("data".utf8)) else { log("读不了 \(path)"); return }
        var pos = r.upperBound + 4
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self, pos < all.count else { return }
            let end = min(pos + 3200, all.count)
            self.onAudio(all.subdata(in: pos..<end))
            pos = end
        }
        wavTimer = t
        t.resume()
    }
}

// MARK: - 一次听写

struct Dictation {
    var id: Int                 // 壳给的号（arm / start 的 id）
    var session = UUID().uuidString
    var pcm = Data()            // 这次录到的全部音频（session_lost 时从这一段的开头重送）
    var sentBytes = 0           // 已经送给主控的
    var seq = 0
    // 分段：说到 segmentSecs 秒左右在停顿处先要这一段的终稿、在后台整理，接着开新的一段（主控一次听写最长 120 秒，
    // 整理一大段又太慢）；松开时只剩最后一段要识别、整理
    var segStart = 0            // 这一段（这个会话）的音频从 pcm 的哪里开始
    var segs: [Segment] = []    // 前面几段（松开后最后一段也放进来）
    var prefix: String { segs.map(\.raw).joined() } // 前面几段的终稿，接在这一段前面显示
    var rolling = false         // 正在要上一段的终稿（新的一段等它回来再开）
    var finalized = false       // 最后一段的终稿也回来了，等各段整理完就上屏
    var lastDraft = ""          // 这一段最近一份草稿（终稿出错时至少上屏它，不丢字）
    var started = false         // 收到 start 了（之前只录不送）
    var stopped = false
    var draftInFlight = false
    var armedAt = Date()        // 什么时候 arm 的
    var ready = false           // 话筒真的开始收音了（录到的不再全是零）
    var levels: [Float] = []    // 每块（0.1 秒）的音量，dBFS；全是零的块（话筒还没开始收音）不记
    var loud: Int { let f = noiseFloor(levels); return levels.filter { isLoud($0, floor: f) }.count } // 有声音的块数：不到 minLoudBlocks 就当没说话
    var cursor = ""             // 光标前已经写的字（壳在 start 里给）：交给转写模型当上下文，前面出现过的名字、英文词更容易认对
    var blocked: String?        // 螺壳这次做不了转写（这一版没开放、模型没准备好、没连上）：光标旁一直提示这一句，不再送音频
}

/// 螺壳做不了转写时给用户看的一句（按错误码）；别的错误照常重试或退回草稿。
func blockedHint(_ code: String) -> String? {
    switch code {
    case "unsupported": return "这一版螺壳还没开放语音输入"
    case "task_unavailable": return "螺壳的语音模型还没准备好，稍后再试"
    case "unavailable": return "没连上螺壳，语音输入用不了"
    default: return nil
    }
}

/// 提示停一会儿再结束这次听写（不上屏）。
func endBlocked(_ id: Int) {
    q.asyncAfter(deadline: .now() + 2) { if current?.id == id { finish(nil) } }
}

/// 一段话：识别出来的终稿，整理完的（没整理、整理出错时为 nil，用 raw），整理完了没有。
struct Segment {
    var raw: String
    var tidied: String?
    var done: Bool
}

struct Pending {
    var params: [String: Any]
    var dictation: Int?         // 转写的是哪一次听写（壳的号）；预热为 nil
    var raw: String?            // 整理：没整理的这一段（出错时用它）
    var seg: Int?               // 整理的是第几段
    var roll = false            // 分段时要的上一段的终稿
    var method = ""             // 转问的方法
    var isWarmup: Bool { method == "warmup" }
}

/// 说到多久就在停顿处分段（选项 segment_secs 可改，测试用）；到 maxSegmentSecs 不管停没停都切（主控的上限是 120 秒）。
var segmentSecs = 30.0
let maxSegmentSecs = 100.0

let recorder = Recorder()
var current: Dictation?
var pending: [Int: Pending] = [:]
var askCounter = 0
var lease: String?

func ask(_ method: String, _ params: [String: Any], dictation: Int?) {
    askCounter += 1
    pending[askCounter] = Pending(params: params, dictation: dictation, method: method)
    send(["type": "ask", "id": askCounter, "to": "hub", "method": method, "params": params])
}

// MARK: - 热词

/// 记忆里的常用说法（问个人化组件要的），五分钟内不重要；交给转写模型当上下文的一部分。
var hotwords: [String] = []
var hotwordsAt = Date.distantPast

func refreshHotwords() {
    guard Date().timeIntervalSince(hotwordsAt) > 300 else { return }
    hotwordsAt = Date()
    askCounter += 1
    pending[askCounter] = Pending(params: ["hotwords": true], dictation: nil)
    send(["type": "ask", "id": askCounter, "to": "personal", "method": "hotwords", "params": ["limit": 50]])
}

/// 模型偶尔会把上下文里的热词表整串吐出来（「螺壳实验室、小鹤双拼、飞书、……」）：连着 4 个以上、用顿号逗号隔开的热词去掉。
/// 说话里本来就会出现的热词照留，随口列两三个也不动；开头带「常用说法：」的连它一起去掉。
func stripLeakedHotwords(_ text: String) -> String {
    guard hotwords.count >= 4 else { return text }
    let alts = hotwords.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
    guard let re = try? NSRegularExpression(pattern: "(?:常用说法[:：]\\s*)?(?:(?:\(alts))[、，,]\\s*){3,}(?:\(alts))[。.]?") else { return text }
    let out = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    if out != text { log("去掉了吐出来的热词表") }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

func warmup() {
    var p: [String: Any] = ["task": task]
    if let lease { p["lease_id"] = lease }
    ask("warmup", p, dictation: nil)
}

/// 把还没送的音频连同 want 送出去。roll：分段时要上一段的终稿。
func transcribe(_ want: String, roll: Bool = false) {
    guard var d = current else { return }
    let chunk = d.pcm.subdata(in: d.sentBytes..<d.pcm.count)
    var params: [String: Any] = ["task": task, "session": d.session, "seq": d.seq, "audio": chunk.base64EncodedString(), "want": want]
    let before = d.prefix
    // 上下文：记忆里的常用说法，光标前已经写的字，加上前面几段说了什么（接缝处靠它接上，「就……塌了」）
    let hot = hotwords.isEmpty ? "" : "常用说法：" + hotwords.joined(separator: "、") + "\n"
    let ctx = hot + String((d.cursor + before).suffix(300))
    if !ctx.isEmpty { params["context"] = ctx }
    d.sentBytes = d.pcm.count
    d.seq += 1
    if want == "draft" { d.draftInFlight = true }
    if roll { d.rolling = true }
    current = d
    askCounter += 1
    pending[askCounter] = Pending(params: params, dictation: d.id, roll: roll)
    send(["type": "ask", "id": askCounter, "to": "hub", "method": "transcribe", "params": params])
}

/// 上一段的终稿回来了：接到 prefix 后面，开新的一段；已经松开了就接着要新一段的终稿。
func rolled(_ text: String) {
    guard var d = current else { return }
    d.segs.append(Segment(raw: digitsFirst(text.trimmingCharacters(in: .whitespacesAndNewlines)), tidied: nil, done: false))
    d.lastDraft = ""
    d.session = UUID().uuidString
    d.seq = 0
    d.segStart = d.sentBytes
    d.rolling = false
    d.draftInFlight = false
    current = d
    target = d.prefix
    tidy(d.segs.count - 1) // 用户还在说，这一段先在后台整理
    if d.stopped {
        if d.pcm.count > d.sentBytes { transcribe("final") } else { gotFinal("") }
    } else if d.pcm.count > d.sentBytes {
        transcribe("none") // 新的一段从 seq 0 开
    }
}

/// 连着 5 个以上的汉字数字（念出来的电话、订单号）先逐位换成阿拉伯数字，不交给模型（evals/tidy 的 eval_tidy.py 一样）。
func digitsFirst(_ text: String) -> String {
    let map: [Character: Character] = ["零": "0", "〇": "0", "一": "1", "二": "2", "三": "3", "四": "4", "五": "5", "六": "6", "七": "7", "八": "8", "九": "9", "幺": "1"]
    var out = "", run = ""
    func flush() { out += run.count >= 5 ? String(run.map { map[$0]! }) : run; run = "" }
    for c in text {
        if map[c] != nil { run.append(c) } else { flush(); out.append(c) }
    }
    flush()
    return latinNumerals(out)
}

/// 汉字数字换成阿拉伯数字：带十百千的按位算（「十七」→ 17、「一百零五」→ 105），不带的逐位（「二零二六」→ 2026）；
/// 「点」前后各算一次（版本号「三点十二」→ 3.12）。
func cnNumber(_ s: String) -> String? {
    let digit: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
    let unit: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
    func one(_ part: Substring) -> String? {
        guard !part.isEmpty else { return nil }
        if part.contains(where: { unit[$0] != nil }) {
            var total = 0, cur = 0
            for c in part {
                if let d = digit[c] { cur = d } else if let u = unit[c] { total += (cur == 0 && u == 10 ? 1 : cur) * u; cur = 0 } else { return nil }
            }
            return String(total + cur)
        }
        var out = ""
        for c in part { guard let d = digit[c] else { return nil }; out += String(d) }
        return out
    }
    let parts = s.split(separator: "点", maxSplits: 1, omittingEmptySubsequences: false)
    guard let head = one(parts[0]) else { return nil }
    guard parts.count == 2 else { return head }
    guard let tail = one(parts[1]) else { return nil }
    return head + "." + tail
}

/// 紧跟在英文后面的汉字数字（版本号、型号：「beta 二」「iPhone 十七 Pro」「version 二点一」）换成阿拉伯数字，英文和数字之间留一个空格。
/// 转写模型按中文出数字，整理模型见了「Beta 二」会写成「Beta Two」。后面跟着量词的（「pull 一下」「merge 两次」）不动。
let latinNumeralPattern = try! NSRegularExpression(
    pattern: "([A-Za-z])\\s*((?>[零〇一二两三四五六七八九十百千]+(?:点[零〇一二三四五六七八九十]+)?))(?![下次个遍些起点会直样般定切共位只件条种段份天年月日周趟回把张本句页分秒岁倍台部])(\\s*)(?=([A-Za-z])?)")
func latinNumerals(_ text: String) -> String {
    let ns = text as NSString
    var out = "", last = 0
    for m in latinNumeralPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        guard let n = cnNumber(ns.substring(with: m.range(at: 2))) else { continue }
        let latinAfter = m.range(at: 4).location != NSNotFound
        out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
        out += ns.substring(with: m.range(at: 1)) + " " + n + (latinAfter ? " " : ns.substring(with: m.range(at: 3)))
        last = m.range.location + m.range.length
    }
    return out + ns.substring(from: last)
}

/// 整理前先去掉单独成段的单字语气词（「嗯，」「呃，」「啊，」「额，」：在开头或标点后面、后面跟逗号的），不交给模型：
/// 小模型常留着开头的「嗯」「啊」。「好啊，」这种跟在字后面的不动。
let fillerPattern = try! NSRegularExpression(pattern: "(^|[，。！？,.!?\\s])[嗯呃啊额]+[，,]\\s*")
func stripFillers(_ text: String) -> String {
    fillerPattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
}

/// 只数字母和数字（去掉标点、空格）。
func letters(_ s: String) -> Int { s.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }.count }

/// 整理的结果比原文短一半以上、或长三成以上，就当跑偏了（比如照着原文里的话去做了），用原文。
func guarded(_ raw: String, _ out: String?) -> String {
    guard let out, !out.isEmpty else { return raw }
    let a = Double(letters(raw)), b = Double(letters(out))
    return b >= 0.5 * a && b <= 1.3 * a + 2 ? out : raw
}

/// 最后一段的终稿出来了：放进各段，整理它；各段都整理完（或者等够了）就一起上屏。
func gotFinal(_ text: String) {
    guard var d = current else { return }
    // 按住了但一直没说话（只有底噪）：模型可能吐出语气词、甚至把上下文整段吐出来，当没说，不上屏
    if d.loud < minLoudBlocks, d.segs.isEmpty {
        let f = noiseFloor(d.levels)
        log("没听到说话（有声音的只有 \(d.loud) 块，最响 \(Int(d.levels.max() ?? -120)) dBFS，底噪 \(Int(f)) dBFS），不上屏")
        // 录到了比底噪明显响的声音、只是太小（不是只有底噪）：光标旁说一句为什么，不要什么都没有、让人再按一次
        if d.levels.filter({ $0 > f + 6 }).count >= minLoudBlocks {
            var hint = "声音太小，没听清"
            if let dev = recorder.device, let v = Audio.inputVolume(dev), v < 0.5 { hint += "：系统设置 › 声音 › 输入里的音量偏低" }
            d.blocked = hint
            current = d
            send(["type": "show", "id": d.id, "text": "", "hint": hint])
            return endBlocked(d.id)
        }
        return finish(nil)
    }
    let t = digitsFirst(text.trimmingCharacters(in: .whitespacesAndNewlines))
    if !t.isEmpty { d.segs.append(Segment(raw: t, tidied: nil, done: false)) }
    d.finalized = true
    current = d
    let all = d.prefix
    if !t.isEmpty { tidy(d.segs.count - 1) } // 不整理时它直接算整理完
    if tidyEnabled, tidyPrompt != nil, !all.isEmpty {
        send(["type": "show", "id": d.id, "text": all, "hint": "整理中…"]) // 终稿出来了，在整理
        let id = d.id
        q.asyncAfter(deadline: .now() + tidyWait) { if current?.id == id { tryCommit(force: true) } } // 太慢就不等了
    }
    tryCommit(force: false)
}

/// 请主控整理第 i 段（不整理时直接算整理完）。
func tidy(_ i: Int) {
    guard var d = current, i < d.segs.count else { return }
    guard tidyEnabled, let tidyPrompt, !d.segs[i].raw.isEmpty else {
        d.segs[i].done = true
        current = d
        return
    }
    let raw = stripFillers(d.segs[i].raw)
    if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { // 整段只有语气词
        d.segs[i].tidied = ""
        d.segs[i].done = true
        current = d
        return
    }
    var msgs: [[String: String]] = [["role": "system", "content": tidyPrompt]]
    for e in tidyExamples where e.count == 2 {
        msgs.append(["role": "user", "content": "<<<\n" + e[0] + "\n>>>"])
        msgs.append(["role": "assistant", "content": String(data: try! JSONSerialization.data(withJSONObject: ["text": e[1]]), encoding: .utf8)!])
    }
    msgs.append(["role": "user", "content": "<<<\n" + raw + "\n>>>"])
    let params: [String: Any] = [
        "task": tidyTask,
        "messages": msgs,
        "response_format": ["type": "json_schema", "json_schema": ["name": "tidy", "schema": [
            "type": "object", "properties": ["text": ["type": "string"]], "required": ["text"], "additionalProperties": false]]],
    ]
    askCounter += 1
    pending[askCounter] = Pending(params: params, dictation: d.id, raw: raw, seg: i)
    send(["type": "ask", "id": askCounter, "to": "hub", "method": "generate", "params": params])
}

/// 终稿都回来了：各段都整理完，或者 force（等够了），就上屏——整理完的用整理后的，没整理完、出错的用原文。
func tryCommit(force: Bool) {
    guard let d = current, d.finalized, force || d.segs.allSatisfy(\.done) else { return }
    finish(d.segs.map { $0.tidied ?? $0.raw }.joined())
}

func finish(_ text: String?) {
    guard let d = current else { return }
    let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    send(t.isEmpty ? ["type": "end", "id": d.id] : ["type": "commit", "id": d.id, "text": t])
    current = nil
    displayed = ""
    target = ""
    recorder.stop()
}

func reply(_ m: [String: Any]) {
    guard let id = m["id"] as? Int, let p = pending.removeValue(forKey: id) else { return }
    if p.params["hotwords"] != nil { // 热词的答复；没开记忆、出错时是空的，照样识别
        hotwords = ((m["result"] as? [String: Any])?["words"] as? [String] ?? []).filter { !$0.isEmpty }
        return
    }
    let want = p.params["want"] as? String
    if let raw = p.raw, let i = p.seg { // 整理的答复：{"text": "{\"text\": …}"}，模型按 response_format 出的 JSON 在 text 里
        guard var d = current, d.id == p.dictation, i < d.segs.count else { return }
        let out = ((m["result"] as? [String: Any])?["text"] as? String).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["text"] as? String
        if out == nil, let e = m["error"] { log("整理出错：\(e)") }
        d.segs[i].tidied = guarded(raw, out?.trimmingCharacters(in: .whitespacesAndNewlines))
        d.segs[i].done = true
        current = d
        return tryCommit(force: false)
    }
    if let r = m["result"] as? [String: Any] {
        if p.dictation == nil {
            if p.isWarmup { lease = r["lease_id"] as? String } // 取消（want: cancel）的答复不带 lease，不能把预热拿到的清掉
            return
        }
        guard var d = current, d.id == p.dictation else { return }
        let text = stripLeakedHotwords(r["text"] as? String ?? "")
        if p.roll { return rolled(text) }
        guard p.params["session"] as? String == d.session else { return } // 分段以前那一段的草稿：不要了
        if want == "draft" {
            d.draftInFlight = false
            if !text.isEmpty { d.lastDraft = text }
            current = d
            if !d.stopped, !text.isEmpty, d.loud >= minLoudBlocks { target = d.prefix + text } // 还没听到说话：模型可能把上下文吐出来，不显示
        } else if want == "final" {
            gotFinal(text)
        }
        return
    }
    let e = m["error"] as? [String: Any] ?? [:]
    let code = e["code"] as? String ?? "?"
    if p.dictation == nil { // 预热没成：下次按下再来；取消没成不用管
        if p.isWarmup { lease = nil }
        return
    }
    guard var d = current, d.id == p.dictation else { return }
    switch code {
    case "superseded":
        if want == "draft" { d.draftInFlight = false; current = d }
    case "session_lost":
        // 主控不认得这个会话了（比如重启过）：从这一段的开头、seq 0 重送，要的东西不变
        guard p.params["session"] as? String == d.session else { return }
        d.sentBytes = d.segStart
        d.seq = 0
        d.draftInFlight = false
        d.rolling = false
        current = d
        if want == "final" || want == "draft" { transcribe(want!, roll: p.roll) }
    case "not_ready", "busy":
        // 这一块当没收到，原样重发
        let delay = (e["retry_after"] as? Double) ?? 1
        q.asyncAfter(deadline: .now() + min(delay, 3)) {
            guard current?.id == p.dictation else { return }
            pending[askCounter + 1] = p
            askCounter += 1
            send(["type": "ask", "id": askCounter, "to": "hub", "method": "transcribe", "params": p.params])
        }
    default:
        // 螺壳做不了转写、这次又还没识别出字：提示为什么，不要只亮着「正在听」最后什么都没有
        if let hint = blockedHint(code), d.prefix.isEmpty, d.lastDraft.isEmpty {
            log("转写用不了：\(code) \(e["message"] as? String ?? "")")
            if d.blocked == nil {
                d.blocked = hint
                d.draftInFlight = false
                current = d
                send(["type": "show", "id": d.id, "text": "", "hint": hint])
                if d.stopped { endBlocked(d.id) }
            }
            return
        }
        // 出错了也不丢字：上一段要不到终稿就拿它最近的草稿顶上；整次的终稿要不到就上屏已经识别出来的
        log("转写出错：\(code) \(e["message"] as? String ?? "")")
        if p.roll {
            rolled(d.lastDraft)
        } else if want == "final" {
            gotFinal(d.lastDraft)
        } else if want == "draft" {
            d.draftInFlight = false
            current = d
        }
    }
}

func handle(_ m: [String: Any]) {
    guard let type = m["type"] as? String else { return }
    let id = m["id"] as? Int
    switch type {
    case "hello":
        let opts = m["options"] as? [String: Any] ?? [:]
        if let w = opts["test_wav"] as? String, !w.isEmpty { recorder.wav = w }
        if let b = opts["bluetooth_mic"] as? Bool { recorder.bluetoothMic = b }
        if let t = opts["tidy"] as? Bool { tidyEnabled = t }
        if let sg = opts["segment_secs"] as? Double, sg > 0 { segmentSecs = sg }
        warmup()
        refreshHotwords()
    case "arm":
        // 还没确认按住、刚 arm 过又来一个 arm（试用时一次按下来了两个，相隔约 70 ms）：接着录，只换成新的号，
        // 不然录音要关了重开，开头那一点就丢了。上一个号随后的 cancel 对不上号，不理
        if var d = current, !d.started, Date().timeIntervalSince(d.armedAt) < 0.5 {
            d.id = id ?? 0
            current = d
            return
        }
        if current != nil { recorder.stop() }
        current = Dictation(id: id ?? 0)
        displayed = ""
        target = ""
        recorder.start()
        warmup()
        refreshHotwords()
    case "start":
        if current?.id != id { // 没有先 arm（比如壳没发）：现在才开始录
            current = Dictation(id: id ?? 0)
            recorder.start()
        }
        current?.started = true
        current?.cursor = m["context"] as? String ?? ""
        transcribe("none")
        if let d = current, !d.ready { send(["type": "show", "id": d.id, "text": "", "listening": false]) } // 还没收到声音：先显示准备中
    case "stop":
        guard var d = current, d.id == id else { return }
        d.stopped = true
        current = d
        // 松开就关麦克风，不等识别、整理完：用的是蓝牙耳机的麦克风时，耳机能早点切回听音乐的模式。
        // 已经录到、排在队列里的音频照样接上，所以终稿放到它们后面再要
        recorder.stop()
        if d.blocked != nil { return endBlocked(d.id) }
        q.async { if current?.id == d.id, !(current?.rolling ?? true) { transcribe("final") } } // 正在要上一段的终稿：等它回来再要这一段的（rolled）
    case "cancel":
        guard let d = current, d.id == id else { return }
        if d.started { ask("transcribe", ["task": task, "session": d.session, "seq": d.seq, "want": "cancel"], dictation: nil) }
        current = nil
        displayed = ""
        target = ""
        recorder.stop()
    case "reply":
        reply(m)
    default:
        break
    }
}

/// 有声音的块（不是停顿的）至少这么多（0.3 秒）才算说了话。
let minLoudBlocks = 3

/// 一块音频的音量（RMS），dBFS；全是零时为 nil。
func level(_ data: Data) -> Float? {
    let n = data.count / 2
    guard n > 0 else { return nil }
    let sum = data.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).reduce(0.0) { $0 + Double($1) * Double($1) } }
    guard sum > 0 else { return nil }
    return Float(10 * log10(sum / Double(n)) - 20 * log10(32768))
}

/// 这次按住的底噪：各块音量里靠下的那一档（第 10 百分位）。
func noiseFloor(_ levels: [Float]) -> Float {
    guard !levels.isEmpty else { return -120 }
    let v = levels.sorted()
    return v[v.count / 10]
}

/// 这一块算不算有声音（不是停顿）：高于 -40 dBFS 的都算；再小声的，比这次的底噪高 10 dB 以上、又不低于 -65 dBFS 也算。
/// 原来只看 -40 dBFS（满幅的 1%）：系统的麦克风输入音量调低了（内置麦克风 27/100 约 -5.5 dB）时，小声说的一整段都在它下面，
/// 当成没说话。转写模型本身不挑音量：合成的句子压低 40 dB（最响的块约 -55 dBFS）照样一字不差。
func isLoud(_ l: Float, floor: Float) -> Bool { l > -40 || (l > -65 && l > floor + 10) }

recorder.onAudio = { data in
    guard var d = current else { return }
    d.pcm.append(data)
    if let l = level(data) { d.levels.append(l) }
    // 话筒真的开始收音了（不再全是零：蓝牙耳机切到通话模式、合着盖换麦克风都要一会儿）：告诉壳，黄点变红点
    if !d.ready, data.contains(where: { $0 != 0 }) {
        d.ready = true
        if d.started, !d.stopped { send(["type": "show", "id": d.id, "text": displayed, "listening": true]) }
    }
    current = d
    // 说到 segmentSecs 以后挑一个停顿的地方切（不在一句话中间切开）：先要这一段的终稿、在后台整理，接着开新的一段；
    // 一直没停顿的话到 maxSegmentSecs 硬切（主控一次最长 120 秒）
    let secs = Double(d.pcm.count - d.segStart) / 32000
    if d.started, !d.stopped, !d.rolling, d.blocked == nil, secs >= maxSegmentSecs || (secs >= segmentSecs && !isLoud(level(data) ?? -120, floor: noiseFloor(d.levels))) { transcribe("final", roll: true) }
}

// 草稿：按住期间每隔 draftInterval 一份，上一份没回来就等它
let draftTimer = DispatchSource.makeTimerSource(queue: q)
draftTimer.schedule(deadline: .now() + 0.25, repeating: 0.25)
draftTimer.setEventHandler {
    guard let d = current, d.started, !d.stopped, !d.rolling, !d.draftInFlight, d.blocked == nil, d.pcm.count > d.sentBytes,
          Date().timeIntervalSince(lastDraftAt) >= draftInterval else { return }
    lastDraftAt = Date()
    transcribe("draft")
}
draftTimer.resume()

// 逐字补出：每 40 ms 往 target 走几个字，大约在下一份草稿来之前补完。草稿是整段重解的，前面的字可能变：
// 变了的就地换掉，不删了重打（长段落一大片删了又出会闪，输入框也一会儿高一会儿矮），只有新多出来的字逐字补
let typeTimer = DispatchSource.makeTimerSource(queue: q)
typeTimer.schedule(deadline: .now() + 0.04, repeating: 0.04)
typeTimer.setEventHandler {
    guard let d = current, !d.stopped, displayed != target else { return }
    if target.count <= displayed.count { // 新草稿不比显示的长：直接换
        displayed = target
        return send(["type": "show", "id": d.id, "text": displayed])
    }
    let common = displayed.count // 显示的这些字照新草稿就地换掉
    var next = String(target.prefix(common))
    let left = target.count - common
    let step = max(1, Int((Double(left) / (draftInterval * 0.8 / 0.04)).rounded(.up)))
    next += target.dropFirst(common).prefix(step)
    displayed = next
    send(["type": "show", "id": d.id, "text": displayed])
}
typeTimer.resume()

Thread.detachNewThread {
    while let line = readLine() {
        guard let m = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
        q.async { handle(m) }
    }
    exit(0)
}
dispatchMain()
