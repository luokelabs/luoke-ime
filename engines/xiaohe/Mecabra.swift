import Foundation

/// 苹果中文输入法自带的转换引擎（/usr/lib/libmecabra.dylib，系统私有库）。
/// 必需的 4 个函数：给一串全拼，取出候选。系统升级后若接口变了，init 会失败，引擎退出并说明原因。
/// 另有 3 个可选的：候选对应哪一段拼音、各音节多长、是不是 emoji；找不到时小鹤按每个字两个键算、不给 emoji，全拼不可用。
final class Mecabra {
    // 真实签名有 3 个参数（反汇编可见：它把第 3 个参数挪到第 4 位后转给
    // MecabraCreateWithAdditionalDictionariesAndOptions）。第 3 个是创建选项，必须显式传：
    // 不传的话读到的是寄存器里的残留值，结果会随环境变量大小变化；其中值 4 表示"只给整句候选"。
    private typealias Create = @convention(c) (Int, UnsafeRawPointer?, Int) -> OpaquePointer?
    private typealias Analyze = @convention(c) (OpaquePointer, CFString, Int) -> UInt8
    private typealias Next = @convention(c) (OpaquePointer) -> OpaquePointer?
    private typealias Surface = @convention(c) (OpaquePointer) -> Unmanaged<CFString>?
    private typealias Flag = @convention(c) (OpaquePointer) -> UInt8
    private typealias Lengths = @convention(c) (OpaquePointer) -> Unmanaged<CFArray>?

    private let analyze: Analyze
    private let next: Next
    private let surface: Surface
    private let analysis: Surface?
    private let isEmoji: Flag?
    private let syllableLengths: Lengths?
    private let engine: OpaquePointer
    private let setFuzzy: (@convention(c) (OpaquePointer, CFArray?) -> Void)?
    private var analyzeOption = 0

    init() throws {
        guard let lib = dlopen("/usr/lib/libmecabra.dylib", RTLD_NOW) else {
            throw EngineFailure("加载不了苹果的转换引擎：\(String(cString: dlerror()))")
        }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let p = dlsym(lib, name) else { throw EngineFailure("苹果的转换引擎里找不到 \(name)，可能是系统升级改了接口") }
            return unsafeBitCast(p, to: T.self)
        }
        let create = try symbol("MecabraCreateWithOptions", Create.self)
        analyze = try symbol("MecabraAnalyzeString", Analyze.self)
        next = try symbol("MecabraGetNextCandidate", Next.self)
        surface = try symbol("MecabraCandidateGetSurface", Surface.self)
        analysis = try? symbol("MecabraCandidateGetAnalysisString", Surface.self)
        isEmoji = try? symbol("MecabraCandidateIsEmojiCandidate", Flag.self)
        syllableLengths = try? symbol("MecabraCandidateCopySyllableLengthArrayInAnalysisString", Lengths.self)
        setFuzzy = try? symbol("MecabraSetFuzzyPinyinPairs", (@convention(c) (OpaquePointer, CFArray?) -> Void).self)
        guard let e = create(2, nil, 0) else { throw EngineFailure("苹果的转换引擎创建失败") } // 2 = 简体拼音；选项 0 = 整句和部分候选都给
        engine = e
    }

    /// 打开模糊音：每组是互通的两种拼法，比如 ["z", "zh"]。系统升级后找不到这个函数就不开，打字不受影响。
    /// 这几组只设上还不生效，分析时第 3 个参数要带 16（实测得出，没有文档）；拼音段照旧是用户打的字母。
    func enableFuzzy(_ pairs: [[String]]) {
        guard !pairs.isEmpty else { return }
        guard let setFuzzy else { return log("苹果的转换引擎里没有模糊音的接口，这一路不开") }
        setFuzzy(engine, pairs as CFArray)
        analyzeOption = 16
    }

    struct Candidate {
        var text: String
        /// 对应的拼音段（输入的开头一段，原样）；不知道时为 nil。
        var analysis: String?
        /// 对应几个音节（拼音段里 ' 分开的段数）；不知道时为 nil。
        var syllables: Int?
        /// 拼音段里每个音节的长度（全拼时用来切分）。
        var syllableLengths: [Int]?
        var emoji: Bool
    }

    /// 全拼（音节间用 ' 分隔）的候选，按苹果的顺序。给原始字母时也会出英文单词。lengths：要不要各音节的长度。
    func lookup(_ pinyin: String, limit: Int, lengths: Bool = false) -> [Candidate] {
        guard analyze(engine, pinyin as CFString, analyzeOption) != 0 else { return [] }
        var out: [Candidate] = []
        while out.count < limit, let c = next(engine) {
            guard let s = surface(c)?.takeUnretainedValue() else { continue }
            let a = analysis?(c)?.takeUnretainedValue() as String?
            let lens = lengths ? (syllableLengths?(c)?.takeRetainedValue() as? [NSNumber])?.map(\.intValue) : nil // 要算，只在全拼时取
            out.append(Candidate(text: s as String, analysis: a, syllables: a.map { $0.split(separator: "'").count },
                                 syllableLengths: lens, emoji: isEmoji.map { $0(c) != 0 } ?? false))
        }
        return out
    }

    func candidates(_ pinyin: String, limit: Int) -> [String] {
        lookup(pinyin, limit: limit).map(\.text)
    }
}

struct EngineFailure: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}
