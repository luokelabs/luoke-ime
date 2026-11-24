// 语音引擎：按住右 ⌥ 说话，松开上屏。录音在引擎里，识别交给主控的 luoke-ime.transcribe 任务（经壳转问，ADR 0016）。
//
// - 按下收到 arm 就开始录（16 kHz 单声道 PCM16），收到 cancel 就丢掉；确认按住（start）后开一个转写会话。
// - 按住期间每隔一会儿（内存 24 GB 及以下的 Mac 1 秒，别的 0.5 秒）送一块新录的音频、要一份草稿，用 show 显示（不上屏）；同一时间只有
//   一份草稿在算。新草稿多出来的字在接下来的一小段时间里逐字补出来，不一组一组地跳。
// - 按住、话筒在收音时每块（0.1 秒）发一次 level（0–1），壳在光标旁画成音量条。
// - 松开（stop）送最后一块、要终稿，commit 上屏；没识别出字就 end。
// - 主控答 session_lost 就从 seq 0 重送整段；not_ready、busy 照 retry_after 原样重发；按下时请主控预热。
// - 终稿出来以后请主控整理（luoke-ime.tidy：去口头禅、理顺改口、数字和英文的写法、排列表和分段，提示词是同目录的 tidy_prompt.txt），
//   整理完再上屏；出错或等不到（2.5 秒起按字数加，最多 5 秒）就上屏没整理的终稿。分了段的松开后整篇一起编辑一次。选项 tidy 为 false 时不整理。
// - 上下文：记忆里的常用说法（热词，问个人化组件要），加上光标前的字接上前面各段原文的最后 300 字。
// - 有没有说话、哪里是停顿，按 VAD（vad.swift，earshot 的做法和权重）判断，不看声音大小：键盘声、风扇声不算说话，小声说话也算。
//   earshot.bin 读不了、或选项 vad 为 false（测试用）时退回按音量判断。
// - 转写出来的字和热词读音一样、写法不一样时换成热词（hotfix.swift）。
// - 音频只在内存里，会话结束就丢。
//
//   ./build.sh（swiftc -O -o voice main.swift vad.swift hotfix.swift）
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
/// 逐字补的节奏：草稿实际隔多久来一份（滑动平均，草稿越长、主控越忙越久），和攒着还没补的零头。
var draftGap = draftInterval, lastTargetAt: Date?, typeBudget = 0.0
func resetTyping() { displayed = ""; target = ""; draftGap = draftInterval; lastTargetAt = nil; typeBudget = 0 }
/// 松开后整理最多等多久，过了就上屏没整理的（壳 stop 之后最多等 10 秒）：2.5 秒起，字越多等得越久（编辑要写出整篇），
/// 每 200 个字多等 1 秒，最多 5 秒。
func tidyWait(chars: Int) -> Double { min(5, 2.5 + Double(chars) / 200) }
let q = DispatchQueue(label: "voice")   // 下面的状态都只在这个队列上读写

/// 判断是不是在说话（vad.swift）；读不了权重时为 nil，退回按音量判断。引擎在自己的目录里运行。
let earshot = Earshot(weights: "earshot.bin")
/// 选项 vad 为 false 时按音量判断（测试分段时用随机噪声当说话）。
var vadEnabled = true

// 测试用：voice --vad-scores <16 kHz 单声道 PCM16 的 WAV>，每帧（16 ms）打一行分数，和 earshot 的结果对（test_vad.py）。
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--vad-scores" {
    guard let model = earshot, let all = FileManager.default.contents(atPath: CommandLine.arguments[2]),
          let r = all.range(of: Data("data".utf8)) else { log("读不了权重或 WAV"); exit(1) }
    let pcm = all.subdata(in: (r.upperBound + 4)..<all.count)
    let samples: [Int16] = pcm.withUnsafeBytes { raw in (0..<(raw.count / 2)).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) } }
    model.reset()
    var out = ""
    var i = 0
    while i + 256 <= samples.count { out += String(format: "%.4f\n", model.predict(samples[i..<(i + 256)])); i += 256 }
    FileHandle.standardOutput.write(Data(out.utf8))
    exit(0)
}

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
    var prefix: String { joinSegments(segs.map(\.raw)) } // 前面几段的终稿，接在这一段前面显示
    var rolling = false         // 正在要上一段的终稿（新的一段等它回来再开）
    var finalized = false       // 最后一段的终稿也回来了，等各段整理完就上屏
    var lastDraft = ""          // 这一段最近一份草稿（终稿出错时至少上屏它，不丢字）
    var started = false         // 收到 start 了（之前只录不送）
    var stopped = false
    var draftInFlight = false
    var armedAt = Date()        // 什么时候 arm 的
    var ready = false           // 话筒真的开始收音了（录到的不再全是零）
    var levels: [Float] = []    // 每块（0.1 秒）的音量，dBFS；全是零的块（话筒还没开始收音）不记
    var detector = (vadEnabled ? earshot : nil).map(SpeechDetector.init) // 按 VAD 判断时有
    var speech: [Bool] = []     // 每块是不是说话（VAD），和 levels 一一对应
    var loud: Int { spoken(from: 0) } // 说话的块数：不到 minBlocks 就当没说话
    var segLevels = 0           // 这一段的音量从 levels 的哪里开始
    var rollLevels = 0          // 要上一段终稿时 levels 到了哪里（上一段的终稿回来、新的一段从这里开始）
    var segLoud: Int { spoken(from: segLevels) } // 这一段说话的块数
    /// 说话的块至少这么多才算说了话：按 VAD 0.2 秒（它不会把键盘声当说话，宁可松一点、少吞短话），按音量 0.3 秒。
    var minBlocks: Int { detector != nil ? 2 : 3 }
    /// 从第 i 块起说话的块数：按 VAD；没有 VAD 时数有声音的块（不是停顿的）。
    func spoken(from i: Int) -> Int {
        if detector != nil { return speech[min(i, speech.count)...].filter { $0 }.count }
        let f = noiseFloor(levels)
        return levels[min(i, levels.count)...].filter { isLoud($0, floor: f) }.count
    }
    var cursor = ""             // 光标前已经写的字（壳在 start 里给）：交给转写模型当上下文，前面出现过的名字、英文词更容易认对
    var blocked: String?        // 螺壳这次做不了转写（这一版没开放、模型没准备好、没连上）：光标旁一直提示这一句，不再送音频
    var whole: String?          // 分了段的：松开后整篇一起编辑的结果（列表、分段要看到整篇才排得对）
    var wholeAsked = false      // 整篇编辑在等答复
}

/// 螺壳做不了转写时给用户看的一句（按错误码）；别的错误照常重试或退回草稿。
func blockedHint(_ code: String) -> String? {
    switch code {
    case "unsupported": return "当前版本的螺壳不支持语音输入"
    case "task_unavailable": return "螺壳语音模型准备中，请稍后重试"
    case "unavailable": return "未连接螺壳，语音输入不可用"
    case "unknown_accessory": return "螺壳尚未支持此版本输入法，需等待螺壳更新" // 连上了，但这一版不在螺壳验证过的版本里
    default: return nil
    }
}

/// 显示串和状态：这次做不了转写时（blocked）每一条都带着那句提示。
/// 壳每收到一条 show 就换掉提示，不带的话话筒开始收音时那条「录音中」会把「未连接螺壳」盖掉，松开后只剩「整理中…」然后什么都没有。
func show(_ d: Dictation, _ text: String, listening: Bool? = nil) {
    var m: [String: Any] = ["type": "show", "id": d.id, "text": text]
    if let l = listening { m["listening"] = l }
    if let h = d.blocked { m["hint"] = h }
    send(m)
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
    var whole = false           // 整篇编辑（seg 为 nil）
    var roll = false           // 分段时要的上一段的终稿
    var method = ""             // 转问的方法
    var isWarmup: Bool { method == "warmup" }
}

/// 说到多久就在停顿处分段（选项 segment_secs 可改，测试用）；到它的两倍不管停没停都切（主控的上限是 120 秒）。
/// 一段越长，每份草稿越慢（76 秒的一段一份要 2 秒多，字明显跟不上说话），松开后整理也越慢（超过 tidyWait 就上屏没整理的）。
var segmentSecs = 30.0
var maxSegmentSecs: Double { segmentSecs * 2 }

/// 分段的地方算不算停顿：不算有声音的块，或者比这次的底噪高不到 6 dB（字和字、句和句之间的低谷）。
/// 只看 isLoud 不够：话筒的底噪在 -40 dBFS 以上时每一块都「有声音」，一直等到硬切。说到 1.5 倍还没等到，放宽到 12 dB。
func isPause(_ l: Float, floor: Float, secs: Double) -> Bool {
    !isLoud(l, floor: floor) || l < floor + (secs >= segmentSecs * 1.5 ? 12 : 6)
}

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
    if roll { d.rolling = true; d.rollLevels = d.levels.count }
    current = d
    askCounter += 1
    pending[askCounter] = Pending(params: params, dictation: d.id, roll: roll)
    send(["type": "ask", "id": askCounter, "to": "hub", "method": "transcribe", "params": params])
}

/// 上一段的终稿回来了：接到 prefix 后面，开新的一段；已经松开了就接着要新一段的终稿。
func rolled(_ text: String) {
    guard var d = current else { return }
    let echoFree = d.segs.isEmpty ? text : stripEcho(text, after: d.cursor + d.prefix)
    d.segs.append(Segment(raw: digitsFirst(echoFree.trimmingCharacters(in: .whitespacesAndNewlines)), tidied: nil, done: false))
    d.lastDraft = ""
    d.session = UUID().uuidString
    d.seq = 0
    d.segStart = d.sentBytes
    d.segLevels = d.rollLevels
    d.rolling = false
    d.draftInFlight = false
    current = d
    target = unspaced(d.prefix)
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
/// 转写模型按中文出数字，整理模型见了「Beta 二」会写成「Beta Two」。后面跟着量词的（「pull 一下」「merge 两次」）不动；
/// 单独一个「一」后面接着汉字时也不动（「Mac 一打开就卡」「Excel 一算」的「一……就」）。
let latinNumeralPattern = try! NSRegularExpression(
    pattern: "([A-Za-z])\\s*((?>[零〇一二两三四五六七八九十百千]+(?:点[零〇一二三四五六七八九十]+)?))(?![下次个遍些起点会直样般定切共位只件条种段份天年月日周趟回把张本句页分秒岁倍台部])(\\s*)(?=([A-Za-z])?)")
func latinNumerals(_ text: String) -> String {
    let ns = text as NSString
    var out = "", last = 0
    for m in latinNumeralPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let numeral = ns.substring(with: m.range(at: 2))
        guard let n = cnNumber(numeral) else { continue }
        let end = m.range.location + m.range.length
        if numeral == "一", end < ns.length, (0x4E00...0x9FFF).contains(Int(ns.character(at: end))) { continue }
        let latinAfter = m.range(at: 4).location != NSNotFound
        out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
        out += ns.substring(with: m.range(at: 1)) + " " + n + (latinAfter ? " " : ns.substring(with: m.range(at: 3)))
        last = m.range.location + m.range.length
    }
    return out + ns.substring(from: last)
}

/// 整理前先由代码去掉语气词，不交给模型（模型常留着；整理太慢、没整理就上屏时也要去掉）：
/// - 「嗯」「呃」在哪都去掉，连同它带的标点（「好的，嗯。」→「好的。」，「我觉得嗯这个」→「我觉得这个」）；
/// - 「啊」「额」只去单独成段、后面跟逗号的（「啊，对」）：「好啊」「金额」「额外」不动；
/// - 「然后呢」后面跟逗号的（口述里接着往下说，9B 整理长段时常留着）；问人的「然后呢？」不动。
let fillerPatterns: [(NSRegularExpression, String)] = [
    ("[，,、]\\s*[嗯呃]+(?=[。！？.!?]|$)", ""),
    ("(^|[，。！？,.!?、\\s])[嗯呃啊额]+[，,、]\\s*", "$1"),
    ("(^|[。！？.!?\\s])[嗯呃]+[。！？.!?]*\\s*", "$1"),
    ("[嗯呃]+", ""),
    ("(^|[，。！？,.!?、\\s])然后呢[，,]\\s*", "$1"),
].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
func stripFillers(_ text: String) -> String {
    var t = text
    for (re, template) in fillerPatterns {
        t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: template)
    }
    return letters(t) == 0 ? "" : t // 只剩标点：整段都是语气词
}

/// 分段处多半在一句话中间，整理却把这一段当成完整的话、末尾补了句号（试用时「比如 GitHub。iPhone 17」）。
/// 原文这一段不是以句末标点结尾的，就照原文的结尾：原文是逗号、顿号就还是它，什么都没有就不加。
func keepSegmentEnd(_ raw: String, _ tidied: String) -> String {
    guard let last = tidied.last, last == "。" || last == "." else { return tidied }
    let rawEnd = raw.trimmingCharacters(in: .whitespacesAndNewlines).last
    if let rawEnd, "。！？.!?".contains(rawEnd) { return tidied }
    return String(tidied.dropLast()) + (rawEnd.map { "，,、；;：:".contains($0) ? String($0) : "" } ?? "")
}

/// 把各段接起来：前一段以英文、数字结尾，后一段又以英文、数字开头时，中间空一格（「GitHub」「iPhone」不能粘成一个词）。
func joinSegments(_ parts: [String]) -> String {
    func latin(_ c: Character?) -> Bool { c.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false }
    var out = ""
    for p in parts where !p.isEmpty {
        if latin(out.last), latin(p.first) { out += " " }
        out += p
    }
    return out
}

/// 去掉汉字和英文、数字之间的空格（英文和英文之间的不动）：转写和整理的模型都爱在这儿加空格，
/// 加不加该由壳的「自动空格」设置决定（开着的壳会照规矩加回来），不由模型。草稿和上屏的都这样，前后一致。
let unspacePattern = try! NSRegularExpression(pattern: "(?<=[\\u4e00-\\u9fff])[ \\t]+(?=[A-Za-z0-9])|(?<=[A-Za-z0-9%])[ \\t]+(?=[\\u4e00-\\u9fff])")
func unspaced(_ text: String) -> String {
    unspacePattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
}

/// 只数字母和数字（去掉标点、空格）。
func letters(_ s: String) -> Int { s.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }.count }

/// 和前文对上多少个字（只数字母和数字）才算模型在照抄前文。
let minEcho = 8
/// 转写模型拿光标前的字和前面几段当上下文；分段以后新的一段音频很少时，它会把上下文照抄出来，接在后面就成了两遍。
/// 整段都在前文里出现过：不要；开头和前文的结尾对上 minEcho 个字以上：去掉对上的这部分（连同紧跟的标点）。
func stripEcho(_ text: String, after before: String) -> String {
    func isWord(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) } }
    let t = Array(text.filter(isWord)), b = Array(before.filter(isWord))
    guard t.count >= minEcho, b.count >= minEcho else { return text }
    if String(b).contains(String(t)) { return "" }
    var k = min(t.count, b.count)
    while k >= minEcho, !t[..<k].elementsEqual(b[(b.count - k)...]) { k -= 1 }
    guard k >= minEcho else { return text }
    var n = 0, i = text.startIndex
    while i < text.endIndex, n < k { if isWord(text[i]) { n += 1 }; i = text.index(after: i) }
    while i < text.endIndex, !isWord(text[i]) { i = text.index(after: i) }
    return String(text[i...])
}

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
    if d.loud < d.minBlocks, d.segs.isEmpty {
        let f = noiseFloor(d.levels)
        log("没听到说话（说话的只有 \(d.loud) 块\(d.detector != nil ? "，按 VAD" : "")，最响 \(Int(d.levels.max() ?? -120)) dBFS，底噪 \(Int(f)) dBFS），不上屏")
        // 录到了比底噪明显响的声音、只是太小（不是只有底噪）：光标旁说一句为什么，不要什么都没有、让人再按一次。
        // 按 VAD 时只算够不上「有声音」的那些（响的不是说话，是键盘声、咳嗽这类，不提示）
        if d.levels.filter({ $0 > f + 6 && (d.detector == nil || !isLoud($0, floor: f)) }).count >= minLoudBlocks {
            var hint = "音量过低，未识别到语音"
            if let dev = recorder.device, let v = Audio.inputVolume(dev), v < 0.5 { hint += "：系统设置 › 声音 › 输入中的输入音量偏低" }
            d.blocked = hint
            current = d
            send(["type": "show", "id": d.id, "text": "", "hint": hint])
            return endBlocked(d.id)
        }
        return finish(nil)
    }
    var t = digitsFirst(text.trimmingCharacters(in: .whitespacesAndNewlines))
    // 分段以后的最后一段：刚分段就松开、几乎没说话时，模型会把上下文（前面几段）整段吐出来，接上去就成了两遍。
    // 这一段没说话就当没有；说了的也去掉开头和前文重复的部分
    if !d.segs.isEmpty {
        if d.segLoud < d.minBlocks {
            if !t.isEmpty { log("分段后的最后一段没听到说话（有声音的只有 \(d.segLoud) 块），不要它的 \(t.count) 个字") }
            t = ""
        } else {
            t = stripEcho(t, after: d.cursor + d.prefix)
        }
    }
    if !t.isEmpty { d.segs.append(Segment(raw: t, tidied: nil, done: false)) }
    d.finalized = true
    current = d
    let all = unspaced(d.prefix)
    if tidyEnabled, tidyPrompt != nil, d.segs.count > 1 {
        // 分了段的：整篇一起编辑一次（每段单独整理时，列表、分段只在一段里面对，段和段直接接上）。
        // 最后一段不再单独整理；前面几段说话时已经在后台整理好了，整篇的没等到或出错时用它们，最后一段用去掉语气词的原文
        if !t.isEmpty { d.segs[d.segs.count - 1].done = true; current = d }
        editWhole()
    } else if !t.isEmpty {
        tidy(d.segs.count - 1) // 不整理时它直接算整理完
    }
    if tidyEnabled, tidyPrompt != nil, !all.isEmpty {
        send(["type": "show", "id": d.id, "text": all, "hint": "整理中…"]) // 终稿出来了，在整理
        let id = d.id
        q.asyncAfter(deadline: .now() + tidyWait(chars: all.count)) { if current?.id == id { tryCommit(force: true) } } // 太慢就不等了
    }
    tryCommit(force: false)
}

/// 整理一次的请求：提示词、几轮示例、原文。
func tidyParams(_ prompt: String, _ raw: String) -> [String: Any] {
    var msgs: [[String: String]] = [["role": "system", "content": prompt]]
    for e in tidyExamples where e.count == 2 {
        msgs.append(["role": "user", "content": "<<<\n" + e[0] + "\n>>>"])
        msgs.append(["role": "assistant", "content": String(data: try! JSONSerialization.data(withJSONObject: ["text": e[1]]), encoding: .utf8)!])
    }
    msgs.append(["role": "user", "content": "<<<\n" + raw + "\n>>>"])
    return [
        "task": tidyTask,
        "messages": msgs,
        "response_format": ["type": "json_schema", "json_schema": ["name": "tidy", "schema": [
            "type": "object", "properties": ["text": ["type": "string"]], "required": ["text"], "additionalProperties": false]]],
    ]
}

/// 分了段的听写松开以后，请主控把整篇一起编辑一次。
func editWhole() {
    guard var d = current, let tidyPrompt else { return }
    let raw = stripFillers(joinSegments(d.segs.map(\.raw)))
    guard !raw.isEmpty else { return }
    d.wholeAsked = true
    current = d
    let params = tidyParams(tidyPrompt, raw)
    askCounter += 1
    pending[askCounter] = Pending(params: params, dictation: d.id, raw: raw, seg: nil, whole: true)
    send(["type": "ask", "id": askCounter, "to": "hub", "method": "generate", "params": params])
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
    let params = tidyParams(tidyPrompt, raw)
    askCounter += 1
    pending[askCounter] = Pending(params: params, dictation: d.id, raw: raw, seg: i)
    send(["type": "ask", "id": askCounter, "to": "hub", "method": "generate", "params": params])
}

/// 终稿都回来了就上屏：整篇编辑回来了用它；否则各段都整理完（整篇的出错了），或者 force（等够了），
/// 整理完的段用整理后的，没整理完、出错的用原文。
func tryCommit(force: Bool) {
    guard let d = current, d.finalized else { return }
    if let w = d.whole { return finish(w) }
    guard force || (!d.wholeAsked && d.segs.allSatisfy(\.done)) else { return }
    finish(joinSegments(d.segs.map { $0.tidied ?? (tidyEnabled ? stripFillers($0.raw) : $0.raw) })) // 整理太慢没等到：至少去掉语气词
}

func finish(_ text: String?) {
    guard let d = current else { return }
    let t = unspaced(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    send(t.isEmpty ? ["type": "end", "id": d.id] : ["type": "commit", "id": d.id, "text": t])
    current = nil
    resetTyping()
    recorder.stop()
}

func reply(_ m: [String: Any]) {
    guard let id = m["id"] as? Int, let p = pending.removeValue(forKey: id) else { return }
    if p.params["hotwords"] != nil { // 热词的答复；没开记忆、出错时是空的，照样识别
        hotwords = ((m["result"] as? [String: Any])?["words"] as? [String] ?? []).filter { !$0.isEmpty }
        return
    }
    let want = p.params["want"] as? String
    if let raw = p.raw, p.whole { // 整篇编辑的答复；出错时不用它，用各段的
        guard var d = current, d.id == p.dictation else { return }
        let out = ((m["result"] as? [String: Any])?["text"] as? String).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["text"] as? String
        if out == nil, let e = m["error"] { log("整篇编辑出错：\(e)") }
        if let out { d.whole = guarded(raw, out.trimmingCharacters(in: .whitespacesAndNewlines)) }
        d.wholeAsked = false
        current = d
        return tryCommit(force: false)
    }
    if let raw = p.raw, let i = p.seg { // 整理的答复：{"text": "{\"text\": …}"}，模型按 response_format 出的 JSON 在 text 里
        guard var d = current, d.id == p.dictation, i < d.segs.count else { return }
        let out = ((m["result"] as? [String: Any])?["text"] as? String).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["text"] as? String
        if out == nil, let e = m["error"] { log("整理出错：\(e)") }
        let tidied = guarded(raw, out?.trimmingCharacters(in: .whitespacesAndNewlines))
        // 不是最后一段（还没松开，或者后面还有）：分段处多半在一句话中间，别让整理补的句号把一句话断开
        d.segs[i].tidied = !d.finalized || i < d.segs.count - 1 ? keepSegmentEnd(raw, tidied) : tidied
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
        var text = correctHotwords(stripLeakedHotwords(r["text"] as? String ?? ""), hotwords)
        if p.roll { return rolled(text) }
        guard p.params["session"] as? String == d.session else { return } // 分段以前那一段的草稿：不要了
        if want == "draft" {
            if !d.segs.isEmpty { text = stripEcho(text, after: d.cursor + d.prefix) } // 分段以后：模型吐出来的前文不要
            d.draftInFlight = false
            if !text.isEmpty { d.lastDraft = text }
            current = d
            if !d.stopped, !text.isEmpty, d.segLoud >= d.minBlocks { // 这一段还没听到说话：模型可能把上下文吐出来，不显示
                let now = Date()
                if let t = lastTargetAt { draftGap = 0.7 * draftGap + 0.3 * min(3, now.timeIntervalSince(t)) }
                lastTargetAt = now
                target = unspaced(joinSegments([d.prefix, text]))
            }
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
        // 螺壳做不了转写、这次又还没识别出字：提示为什么，不要只亮着「录音中」最后什么都没有
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
        if let v = opts["vad"] as? Bool { vadEnabled = v }
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
        resetTyping()
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
        if let d = current, !d.ready { show(d, "", listening: false) } // 还没收到声音：先显示准备中
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
        resetTyping()
        recorder.stop()
    case "reply":
        reply(m)
    default:
        break
    }
}

/// 按音量判断时，有声音的块（不是停顿的）至少这么多（0.3 秒）才算说了话；也是「声音太小」提示的门槛。
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

/// 光标旁音量条的高低（0–1）：比底噪高 6 dB 起、再高 30 dB 到顶。底噪最多按 -45 dBFS 算（刚按下几块时底噪还不准，
/// 吵的地方也别让条一直趴着）。说得太小、门槛不算说话的，条也几乎不动，按着就看得出来。
func meter(_ l: Float, floor: Float) -> Double { Double(min(1, max(0, (l - (min(floor, -45) + 6)) / 30))) }

recorder.onAudio = { data in
    guard var d = current else { return }
    d.pcm.append(data)
    let said = d.detector?.push(data).map { $0 >= 0.5 } ?? false // 全是零的块也要送：VAD 要连续的音频
    if let l = level(data) { d.levels.append(l); d.speech.append(said) }
    // 话筒真的开始收音了（不再全是零：蓝牙耳机切到通话模式、合着盖换麦克风都要一会儿）：告诉壳，黄点变红点
    if !d.ready, data.contains(where: { $0 != 0 }) {
        d.ready = true
        if d.started, !d.stopped { show(d, displayed, listening: true) }
    }
    current = d
    // 按住、话筒在收音时，每块报一次音量，壳画成跟着声音动的音量条
    if d.started, !d.stopped, d.ready { send(["type": "level", "id": d.id, "level": meter(level(data) ?? -120, floor: noiseFloor(d.levels))]) }
    // 说到 segmentSecs 以后挑一个停顿的地方切（不在一句话中间切开）：先要这一段的终稿、在后台整理，接着开新的一段；
    // 一直没停顿的话到 maxSegmentSecs 硬切（主控一次最长 120 秒）
    let secs = Double(d.pcm.count - d.segStart) / 32000
    // 按 VAD 时停顿是连着两块（0.2 秒）不是说话；说到 1.5 倍还没等到，一块也算
    let pause = d.detector != nil
        ? !said && (secs >= segmentSecs * 1.5 || d.speech.count < 2 || !d.speech[d.speech.count - 2])
        : isPause(level(data) ?? -120, floor: noiseFloor(d.levels), secs: secs)
    if d.started, !d.stopped, !d.rolling, d.blocked == nil, secs >= maxSegmentSecs || (secs >= segmentSecs && pause) { transcribe("final", roll: true) }
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

// 逐字补出：每 40 ms 看一次，按「草稿实际隔多久来一份」匀速补，不是一下补完再干等下一份（原来每 40 ms 补一个字，
// 新草稿多出的三五个字 0.2 秒就补完了，然后停着等，看着一卡一卡）。还没补的字越多补得越快，大约在下一份草稿来时补到；
// 字不会一下全到，比草稿晚一点出来，换来字是一个个均匀出来的。
// 草稿是整段重解的，前面的字可能变：变了的就地换掉，不删了重打（长段落一大片删了又出会闪，输入框也一会儿高一会儿矮）
let typeTimer = DispatchSource.makeTimerSource(queue: q)
typeTimer.schedule(deadline: .now() + 0.04, repeating: 0.04)
typeTimer.setEventHandler {
    guard let d = current, !d.stopped, displayed != target else { return }
    if target.count <= displayed.count { // 新草稿不比显示的长：直接换
        displayed = target
        typeBudget = 0
        return show(d, displayed)
    }
    let common = displayed.count // 显示的这些字照新草稿就地换掉
    let left = target.count - common
    typeBudget += Double(left) * 0.04 / min(0.3, max(0.15, draftGap * 0.6)) // 最多拖 0.3 秒：草稿来得慢时宁可一下多出几个字，不能越拖越落后
    let step = min(left, Int(typeBudget))
    typeBudget -= Double(step)
    let next = String(target.prefix(common + step))
    guard next != displayed else { return }
    displayed = next
    show(d, displayed)
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
