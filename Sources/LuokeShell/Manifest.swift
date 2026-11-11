import Foundation

/// 引擎说明：引擎文件夹里的 engine.json（docs/引擎协议.md#引擎说明enginejson）。
public struct Manifest: Equatable {
    /// 打字引擎、快捷键引擎，和个人化组件（同一时间一个，接收所有引擎的上屏、回答转问）。
    public enum Kind: String { case typing, hotkey, personal }

    public var protocolVersion: Int
    public var name: String
    public var kind: Kind
    public var run: [String]
    public var inputKeys: Set<Character>
    public var punctuation: PunctuationTable
    public var context: Int
    public var app: Bool
    public var feedback: Bool
    /// 引擎自己会记住学到的东西（比如改选过的词），收 `forget_all` 清掉：菜单里因此有"清掉学到的词"。
    public var forgetAll = false
    public var hotkey: Hotkey?
    /// 会经壳向谁转问（`personal` 个人化组件、`hub` 主控）。
    public var asks: Set<AskTarget> = []
    public var permissions: Permissions
    /// A2UI 选项界面，原样保留；默认值在 `optionDefaults`。
    public var options: JSONValue?

    public var optionDefaults: JSONValue { options?["data"] ?? .object([:]) }

    public struct Hotkey: Equatable {
        public enum Key: String, CaseIterable { case rightCommand = "right_command", rightOption = "right_option", rightControl = "right_control" }
        public enum Mode: String { case hold, press }
        public var key: Key
        public var mode: Mode
        /// hold 模式下按下就发 `arm`，让引擎先开始准备（比如录音），确认是按住了再发 `start`（语音：不丢开头）。
        public var arm = false
    }

    public struct Permissions: Equatable {
        public enum Network: String { case none, local, any }
        public var network: Network = .none
        public var write: [String] = []
        /// network 为 local 时，只许连这些本机端口；空表示本机所有端口。
        public var localPorts: [Int] = []
        public var microphone = false
        public var camera = false
        public var screen = false
        /// GPU（Metal），引擎里跑本地模型用。
        public var gpu = false
        /// 读写螺壳的记忆（~/.luoke/mem.db）。只有个人化组件能声明。
        public var memory = false
        public init() {}
    }

    public enum AskTarget: String, CaseIterable { case personal, hub }

    public static func load(from engineDir: URL) throws -> Manifest {
        try parse(try readEngineJSON(engineDir))
    }

    /// 读 engine.json 的原始字节：不跟随符号链接（是链接就拒绝）。解析和算指纹用同一份字节，免得两次读之间被换掉
    ///（引擎能把 engine.json 做成指向自己数据目录的链接、来回切）。
    public static func readEngineJSON(_ engineDir: URL) throws -> Data {
        let path = engineDir.appendingPathComponent("engine.json").path
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw ManifestError(errno == ELOOP ? "\(path) 是符号链接：为安全起见不认，请换成普通文件" : "找不到 \(path)")
        }
        defer { close(fd) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 { throw ManifestError("读不了 \(path)") }
            if n == 0 { break }
            data.append(buf, count: n)
            if data.count > 1 << 20 { throw ManifestError("\(path) 太大（超过 1 MB）") }
        }
        return data
    }

    public static func parse(_ data: Data) throws -> Manifest {
        guard let obj = try? JSONSerialization.jsonObject(with: data), let m = obj as? [String: Any] else {
            throw ManifestError("engine.json 不是合法的 JSON 对象")
        }
        // JSON 的 true/false 在 Foundation 里也是 NSNumber，`as? Int` 会把 true 当成 1 收下
        func req<T>(_ k: String, _ t: T.Type, _ what: String) throws -> T {
            guard let v = m[k] else { throw ManifestError("缺少必填字段 \(k)") }
            guard let x = v as? T, !(T.self == Int.self && isJSONBool(v)) else { throw ManifestError("\(k) 必须是\(what)") }
            return x
        }
        func opt<T>(_ k: String, _ t: T.Type, _ what: String) throws -> T? {
            guard let v = m[k] else { return nil }
            guard let x = v as? T, !(T.self == Int.self && isJSONBool(v)) else { throw ManifestError("\(k) 必须是\(what)") }
            return x
        }
        func flag(_ k: String) throws -> Bool {
            guard let v = m[k] else { return false }
            guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw ManifestError("\(k) 必须是 true 或 false") }
            return n.boolValue
        }

        let version = try req("protocol", Int.self, "整数")
        guard version == LuokeShell.protocolVersion else {
            throw ManifestError("协议版本 \(version) 不受支持，壳支持的是 \(LuokeShell.protocolVersion)")
        }
        let name = try req("name", String.self, "字符串")
        guard let kind = Kind(rawValue: try req("kind", String.self, "字符串")) else {
            throw ManifestError("kind 只能是 typing、hotkey 或 personal")
        }
        let run = try req("run", [String].self, "字符串数组")
        guard !run.isEmpty, !run[0].isEmpty else { throw ManifestError("run 不能为空") }

        var manifest = Manifest(protocolVersion: version, name: name, kind: kind, run: run, inputKeys: [],
                                punctuation: .default, context: 0, app: false, feedback: false, hotkey: nil,
                                permissions: Permissions(), options: nil)

        switch kind {
        case .typing:
            let keys = try req("input_keys", String.self, "字符串")
            guard !keys.isEmpty else { throw ManifestError("input_keys 不能为空") }
            manifest.inputKeys = Set(keys)
            if let bad = manifest.inputKeys.first(where: { $0.isWhitespace || $0.isNewline }) {
                throw ManifestError("input_keys 不能包含空白字符（\(bad.unicodeScalars.first!.escaped(asASCII: true))）")
            }
        case .hotkey:
            let h = try req("hotkey", [String: Any].self, "对象")
            guard let key = (h["key"] as? String).flatMap(Hotkey.Key.init(rawValue:)) else {
                throw ManifestError("hotkey.key 只能是 " + Hotkey.Key.allCases.map(\.rawValue).joined(separator: "、"))
            }
            guard let mode = (h["mode"] as? String).flatMap(Hotkey.Mode.init(rawValue:)) else {
                throw ManifestError("hotkey.mode 只能是 hold 或 press")
            }
            var hotkey = Hotkey(key: key, mode: mode)
            if let a = h["arm"] {
                guard let b = a as? NSNumber, CFGetTypeID(b) == CFBooleanGetTypeID() else { throw ManifestError("hotkey.arm 必须是 true 或 false") }
                guard mode == .hold || !b.boolValue else { throw ManifestError("hotkey.arm 只用于 hold 模式") }
                hotkey.arm = b.boolValue
            }
            manifest.hotkey = hotkey
        case .personal:
            break
        }

        if let p = try opt("punctuation", [String: Any].self, "对象") {
            manifest.punctuation = try PunctuationTable(json: p)
        }
        if let c = try opt("context", Int.self, "整数") {
            guard (0...maxContext).contains(c) else { throw ManifestError("context 要在 0 到 \(maxContext) 之间") }
            manifest.context = c
        }
        manifest.app = try flag("app")
        manifest.feedback = try flag("feedback")
        manifest.forgetAll = try flag("forget_all")

        if let p = try opt("permissions", [String: Any].self, "对象") {
            var perms = Permissions()
            if let n = p["network"] {
                guard let s = n as? String, let net = Permissions.Network(rawValue: s) else {
                    throw ManifestError("permissions.network 只能是 none、local 或 any")
                }
                perms.network = net
            }
            if let w = p["write"] {
                guard let paths = w as? [String] else { throw ManifestError("permissions.write 必须是字符串数组") }
                guard paths.count <= 16 else { throw ManifestError("permissions.write 最多 16 项") }
                for path in paths { try checkWritePath(path) }
                perms.write = paths
            }
            if let lp = p["local_ports"] {
                guard let ports = lp as? [Int], !((lp as? [Any])?.contains(where: isJSONBool) ?? false),
                      ports.count <= 8, ports.allSatisfy({ (1...65535).contains($0) }) else {
                    throw ManifestError("permissions.local_ports 必须是最多 8 个端口号（1–65535）")
                }
                guard perms.network == .local else { throw ManifestError("permissions.local_ports 只在 network 为 local 时有意义") }
                perms.localPorts = ports
            }
            for (k, path) in [("microphone", \Permissions.microphone), ("camera", \.camera), ("screen", \.screen), ("gpu", \.gpu),
                              ("memory", \.memory)] {
                guard let v = p[k] else { continue }
                guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
                    throw ManifestError("permissions.\(k) 必须是 true 或 false")
                }
                perms[keyPath: path] = n.boolValue
            }
            manifest.permissions = perms
        }

        if let a = m["asks"] {
            guard let list = a as? [String] else { throw ManifestError("asks 必须是字符串数组") }
            for t in list {
                guard let target = AskTarget(rawValue: t) else {
                    throw ManifestError("asks 里的 \(t) 不认识，只能是 " + AskTarget.allCases.map(\.rawValue).joined(separator: "、"))
                }
                manifest.asks.insert(target)
            }
        }
        try checkPersonalRules(manifest)

        if let o = try opt("options", [String: Any].self, "对象") {
            guard let comps = o["components"] as? [[String: Any]] else { throw ManifestError("options.components 必须是对象数组") }
            guard comps.contains(where: { $0["id"] as? String == "root" }) else {
                throw ManifestError("options.components 里必须有一个 id 为 root 的组件")
            }
            let allowed: Set<String> = ["Text", "CheckBox", "ChoicePicker", "Slider", "TextField", "Button", "Divider", "Row", "Column"]
            for c in comps {
                let type = c["component"] as? String ?? "（缺失）"
                guard allowed.contains(type) else {
                    throw ManifestError("组件 \(type) 不在壳的组件目录里，可用的有：" + allowed.sorted().joined(separator: "、"))
                }
            }
            if o["data"] != nil, !(o["data"] is [String: Any]) { throw ManifestError("options.data 必须是对象") }
            manifest.options = JSONValue(o)
        }
        return manifest
    }
}

/// 个人化组件看得到用户在所有引擎里的输入，规则因此更严（docs/引擎协议.md#个人化组件）：
/// 它不能联网；只有它能读写记忆；能联网出去的引擎不能转问它（它的答复里有用户的个人数据）。
func checkPersonalRules(_ m: Manifest) throws {
    let p = m.permissions
    if m.kind == .personal {
        guard p.network == .none else { throw ManifestError("个人化组件不能联网（permissions.network 只能是 none）：它看得到用户在所有引擎里的输入") }
        guard !p.microphone, !p.camera, !p.screen else { throw ManifestError("个人化组件不能声明麦克风、摄像头或屏幕录制") }
        guard !m.asks.contains(.personal) else { throw ManifestError("个人化组件不能转问自己（asks 里只能有 hub）") }
    } else {
        guard !p.memory else { throw ManifestError("permissions.memory 只有个人化组件（kind 为 personal）能声明") }
        if m.asks.contains(.personal) {
            let reachesOut = p.network == .any || (p.network == .local && p.localPorts.isEmpty)
            guard !reachesOut else {
                throw ManifestError("要转问个人化组件（asks 里有 personal），就不能联网出去：permissions.network 只能是 none，或 local 并用 local_ports 限定端口（本机所有端口里可能有代理）")
            }
        }
    }
}

func isJSONBool(_ v: Any) -> Bool {
    guard let n = v as? NSNumber else { return false }
    return CFGetTypeID(n) == CFBooleanGetTypeID()
}

/// 前文最多读多少字。
public let maxContext = 2000

/// 额外可写的位置必须是绝对路径或 ~/ 开头，且不能和壳自己的目录（~/.luoke/ime）重叠。
func checkWritePath(_ path: String) throws {
    guard path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") else {
        throw ManifestError("permissions.write 里的 \(path) 必须是绝对路径或以 ~/ 开头")
    }
    let full = URL(fileURLWithPath: SandboxProfile.expand(path)).standardizedFileURL.path
    let shell = Paths().root.standardizedFileURL.path
    if shell == full || shell.hasPrefix(full.hasSuffix("/") ? full : full + "/") || full.hasPrefix(shell + "/") {
        throw ManifestError("permissions.write 里的 \(path) 和壳自己的目录 \(shell) 重叠；请声明更具体的位置。引擎自己的数据请写到 LUOKE_IME_DATA")
    }
}

public struct ManifestError: Error, CustomStringConvertible, Equatable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// 标点表：非输入键 → 上屏文字；成对符号在两项间交替。
public struct PunctuationTable: Equatable {
    public enum Value: Equatable {
        case single(String)
        case pair(String, String)
    }

    public var entries: [Character: Value]

    public init(_ entries: [Character: Value]) { self.entries = entries }

    init(json: [String: Any]) throws {
        var e: [Character: Value] = [:]
        for (k, v) in json {
            guard k.count == 1, let ch = k.first else { throw ManifestError("标点表的键必须是单个字符：\(k)") }
            if let s = v as? String {
                e[ch] = .single(s)
            } else if let a = v as? [String], a.count == 2 {
                e[ch] = .pair(a[0], a[1])
            } else {
                throw ManifestError("标点表里 \(k) 的值必须是字符串，或两项的字符串数组")
            }
        }
        entries = e
    }

    /// 壳的默认表（实现时逐项与系统简体拼音核对）。
    public static let `default` = PunctuationTable([
        ",": .single("，"), ".": .single("。"), "?": .single("？"), "!": .single("！"),
        ":": .single("："), ";": .single("；"), "\\": .single("、"),
        "(": .single("（"), ")": .single("）"), "[": .single("【"), "]": .single("】"),
        "<": .single("《"), ">": .single("》"), "~": .single("～"), "^": .single("……"),
        "_": .single("——"), "$": .single("￥"), "`": .single("·"),
        "\"": .pair("“", "”"), "'": .pair("‘", "’"),
    ])
}
