// 判断一小段声音是不是人在说话（VAD）：照搬 earshot 1.2.2（pyke.io，MIT OR Apache-2.0，https://github.com/pykeio/earshot）
// 的做法和权重（同目录的 earshot.bin，约 40 KB），改写成 Swift。每帧 16 ms（16 kHz 的 256 个采样）出一个 0–1 的分数，
// 0.5 以上算说话。它不看音量（特征按每帧的均方根归一），键盘声、风扇声、咳嗽不算说话，小声说话也认得出来。
// 只在 CPU 上算，一帧几微秒，不经主控。许可原文见 licenses/earshot。
import Foundation

final class Earshot {
    // 权重：前 705 个是 float32，后面是 int16（Q9），顺序和 earshot 的 default_predictor.rs 一样
    private let norm, l1k, l1w, l1b, l2k, l2w, l2b, l3k, l3w: [Float]
    private let rnn1, rnn2, outW: [Int32]

    private var prev: Float = 0
    private var ring = [Float](repeating: 0, count: 768)
    private var feat = [Float](repeating: 0, count: 120)   // 3 帧 × 40 个梅尔带，最新的在最后
    private var state = [Int16](repeating: 0, count: 128)  // 两层 minGRU 的状态，Q15

    /// 梅尔滤波器：第 i 个三角从 edges[i] 升到 edges[i+1]、降到 edges[i+2]（不含），和 earshot 的 MEL_COEFFS 逐项一样。
    private static let edges = [4, 7, 10, 13, 17, 21, 25, 29, 33, 38, 43, 48, 54, 60, 66, 73, 80, 87, 95, 103, 112, 122, 132, 142, 153,
                                165, 178, 191, 205, 220, 236, 253, 270, 289, 309, 330, 353, 376, 402, 428, 456, 486]
    private static let hann: [Float] = (0..<768).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 768)) }
    // 1024 点 FFT 的旋转因子和位反转表
    private static let cosT: [Float] = (0..<512).map { Float(cos(-2 * Double.pi * Double($0) / 1024)) }
    private static let sinT: [Float] = (0..<512).map { Float(sin(-2 * Double.pi * Double($0) / 1024)) }
    private static let bitrev: [Int] = (0..<1024).map { i in (0..<10).reduce(0) { $0 | (((i >> $1) & 1) << (9 - $1)) } }

    /// path：earshot.bin；读不了、大小不对时为 nil（调用方退回按音量判断）。
    init?(weights path: String) {
        guard let d = FileManager.default.contents(atPath: path), d.count == 705 * 4 + 18560 * 2 else { return nil }
        let f: [Float] = (0..<705).map { i in Float(bitPattern: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self) }.littleEndian) }
        let q: [Int32] = (0..<18560).map { i in Int32(Int16(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 705 * 4 + i * 2, as: Int16.self) })) }
        norm = Array(f[0..<40]); l1k = Array(f[40..<49]); l1w = Array(f[49..<65]); l1b = Array(f[65..<81])
        l2k = Array(f[81..<129]); l2w = Array(f[129..<385]); l2b = Array(f[385..<401])
        l3k = Array(f[401..<449]); l3w = Array(f[449..<705])
        rnn1 = Array(q[0..<10240]); rnn2 = Array(q[10240..<18432]); outW = Array(q[18432..<18560])
    }

    /// 新的一次录音前清掉状态。
    func reset() {
        prev = 0
        for i in ring.indices { ring[i] = 0 }
        for i in feat.indices { feat[i] = 0 }
        for i in state.indices { state[i] = 0 }
    }

    /// 一帧 256 个 16 kHz 的 PCM16 采样 → 是说话的分数（0–1）。
    func predict(_ frame: ArraySlice<Int16>) -> Float {
        precondition(frame.count == 256)
        for i in 0..<512 { ring[i] = ring[i + 256] }
        var k = 512
        for s in frame { // 预加重
            let x = Float(s)
            ring[k] = x - 0.97 * prev
            prev = x
            k += 1
        }
        // 加窗（768 点，补零到 1024）、FFT、功率谱
        var re = [Float](repeating: 0, count: 1024), im = [Float](repeating: 0, count: 1024)
        for i in 0..<768 { re[Self.bitrev[i]] = ring[i] * Self.hann[i] }
        var size = 2
        while size <= 1024 {
            let half = size / 2, step = 1024 / size
            var start = 0
            while start < 1024 {
                for j in 0..<half {
                    let a = start + j, b = a + half
                    let wr = Self.cosT[j * step], wi = Self.sinT[j * step]
                    let tr = re[b] * wr - im[b] * wi, ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                }
                start += size
            }
            size *= 2
        }
        let powerFac: Float = 1 / (32768 * 32768)
        // 梅尔带的对数能量，接在前两帧后面
        for i in 0..<80 { feat[i] = feat[i + 40] }
        var sq: Float = 0
        for m in 0..<40 {
            let a = Self.edges[m], b = Self.edges[m + 1], c = Self.edges[m + 2]
            var v: Float = 0
            for bin in a..<c {
                let w = bin <= b ? Float(bin - a) / Float(b - a) : Float(c - bin) / Float(c - b)
                v += (re[bin] * re[bin] + im[bin] * im[bin]) * powerFac * w
            }
            let l = log(v + 1e-20)
            feat[80 + m] = l
            sq += l * l
        }
        let irms = 1 / (sq / 40).squareRoot()
        for m in 0..<40 { feat[80 + m] = norm[m] * feat[80 + m] * irms }
        return network()
    }

    private func network() -> Float {
        // 第一层：3×3 深度卷积（3 帧 × 40 带 → 38），逐点到 16 个通道，最大池化 3/2（同时是 ReLU）→ 16 × 18
        var row = [Float](repeating: 0, count: 38)
        for ox in 0..<38 {
            var s: Float = 0
            for kh in 0..<3 { for kw in 0..<3 { s += feat[kh * 40 + ox + kw] * l1k[kh * 3 + kw] } }
            row[ox] = s
        }
        var out1 = [Float](repeating: 0, count: 288)
        for c in 0..<16 {
            for qd in 0..<18 {
                var m: Float = 0
                for x in 0..<3 { m = max(m, row[qd * 2 + x] * l1w[c] + l1b[c]) }
                out1[18 * c + qd] = m
            }
        }
        // 第二层：每个通道上宽 3、步长 2 的卷积（18 → 9），逐点 16 → 16，加偏置、ReLU
        var out2 = [Float](repeating: 0, count: 144)
        for ox in 0..<9 {
            var dw = [Float](repeating: 0, count: 16)
            for c in 0..<16 {
                var s: Float = 0
                for kw in 0..<3 { let ix = ox * 2 + kw - 1; if ix >= 0, ix < 18 { s += out1[c * 18 + ix] * l2k[c * 3 + kw] } }
                dw[c] = s
            }
            for oc in 0..<16 {
                var s: Float = 0
                for c in 0..<16 { s += dw[c] * l2w[oc * 16 + c] }
                out2[oc * 9 + ox] = max(0, s + l2b[oc])
            }
        }
        // 第三层：同上（9 → 5），不加偏置、不 ReLU，转成 Q15，按位置在前、通道在后排
        var out3 = [Int16](repeating: 0, count: 80)
        for ox in 0..<5 {
            var dw = [Float](repeating: 0, count: 16)
            for c in 0..<16 {
                var s: Float = 0
                for kw in 0..<3 { let ix = ox * 2 + kw - 1; if ix >= 0, ix < 9 { s += out2[c * 9 + ix] * l3k[c * 3 + kw] } }
                dw[c] = s
            }
            for oc in 0..<16 {
                var s: Float = 0
                for c in 0..<16 { s += dw[c] * l3w[oc * 16 + c] }
                out3[ox * 16 + oc] = Int16(max(-32768, min(32767, (s * 32768).rounded())))
            }
        }
        minGRU(out3, offset: 0, rnn1)
        minGRU(Array(state[0..<64]), offset: 64, rnn2)
        var o: Int32 = 0
        for f in 0..<128 { o &+= Int32(state[f]) &* outW[f] } // Q15 × Q9 = Q24
        return 1 / (1 + exp(-Float(o) / 16777216))
    }

    /// 定点的 minGRU：前 64 个输出是候选，后 64 个是门（×4 后夹在 [0, 1]），整数运算和 earshot 一样（溢出时照 Rust 发布版回绕）。
    private func minGRU(_ x: [Int16], offset: Int, _ w: [Int32]) {
        let dim = x.count
        var t = [Int32](repeating: 0, count: 128)
        for d in 0..<128 {
            var o: Int32 = 0
            let ri = d * dim
            for f in 0..<dim { o &+= Int32(x[f]) &* w[ri + f] } // Q15 × Q9 = Q24
            t[d] = o
        }
        for i in 0..<64 {
            let g = Int64(max(0, min(16777215, t[64 + i] &<< 2)))
            let y = (16777215 - g) * (Int64(state[offset + i]) << 9) + g * Int64(t[i]) // Q48
            state[offset + i] = Int16(max(-32768, min(32767, y >> 33)))
        }
    }
}

/// 把录到的 PCM16 切成 256 个采样一帧送给 Earshot；不满一帧的留到下一块。
struct SpeechDetector {
    let model: Earshot
    private var tail: [Int16] = []

    init(_ model: Earshot) {
        self.model = model
        model.reset()
    }

    /// 一块音频里各帧的最高分；不满一帧时为 nil。
    mutating func push(_ data: Data) -> Float? {
        data.withUnsafeBytes { raw in
            for i in 0..<(raw.count / 2) { tail.append(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) }
        }
        var best: Float?
        var start = 0
        while tail.count - start >= 256 {
            let s = model.predict(tail[start..<(start + 256)])
            best = max(best ?? 0, s)
            start += 256
        }
        tail.removeFirst(start)
        return best
    }
}
