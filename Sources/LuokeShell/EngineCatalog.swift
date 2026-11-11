import Foundation

/// 装了哪些引擎、哪些能用：包里自带的，加上引擎目录里装的（同一个标识以引擎目录里确认过的为准，方便开发时换上新版）。
/// 输入法（EngineManager）和命令行的 `luoke-ime mcp` 共用这一份规则，螺壳主窗口里列的输入方案和输入法里的一样。
public struct EngineCatalog {
    public struct Entry {
        public let id: String
        public let dir: URL
        public let manifest: Manifest?
        public let error: String?
        /// 随输入法发布、在 LuokeIME.app 里的（只读，不监视改动）。
        public var bundled = false
        /// 第三方引擎：引擎说明里和权限有关的内容的指纹（ThirdParty.fingerprint），用户确认时记下；自带的为 nil。
        public var fingerprint: String?

        public init(id: String, dir: URL, manifest: Manifest?, error: String?, bundled: Bool = false, fingerprint: String? = nil) {
            self.id = id
            self.dir = dir
            self.manifest = manifest
            self.error = error
            self.bundled = bundled
            self.fingerprint = fingerprint
        }
    }

    /// 用得上的引擎（同名的取一份），按标识排。
    public private(set) var entries: [Entry] = []
    /// 等用户确认的第三方引擎（包括和自带的同名、还没确认、所以先用着自带那份的）。
    public private(set) var pending: [Entry] = []
    /// 自带引擎的标识（同名的第三方引擎换个数据目录）。
    public private(set) var bundledIDs: Set<String> = []

    public init() {}

    /// 已经扫描好的一组（EngineManager 拿自己存着的重新组出来）。
    public init(entries: [Entry]) { self.entries = entries }

    public static func scan(bundled: URL?, user: URL, approved: [String: String]) -> EngineCatalog {
        func folders(_ root: URL?) -> [URL] {
            guard let root else { return [] }
            let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                       options: [.skipsHiddenFiles])) ?? []
            return dirs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        func entry(_ dir: URL, bundled: Bool) -> Entry {
            do {
                // 解析和算指纹用同一份字节（不跟随链接）：确认过的就是启动时用的
                let data = try Manifest.readEngineJSON(dir)
                return Entry(id: dir.lastPathComponent, dir: dir, manifest: try Manifest.parse(data), error: nil, bundled: bundled,
                             fingerprint: bundled ? nil : ThirdParty.fingerprint(engineJSON: data))
            } catch {
                return Entry(id: dir.lastPathComponent, dir: dir, manifest: nil, error: String(describing: error), bundled: bundled)
            }
        }
        var c = EngineCatalog()
        var own: [String: Entry] = [:]
        for dir in folders(bundled) { own[dir.lastPathComponent] = entry(dir, bundled: true) }
        c.bundledIDs = Set(own.keys)
        var byId = own
        var waiting: [Entry] = []
        for dir in folders(user) {
            let e = entry(dir, bundled: false)
            // 和自带的同名的第三方引擎：用户确认过才盖过自带的那份（开发时用），没确认前照旧用自带的
            if own[e.id] == nil || usable(e, approved: approved) { byId[e.id] = e }
            if e.manifest != nil, refusal(e) == nil, !isApproved(e, approved: approved) { waiting.append(e) }
        }
        c.entries = byId.values.sorted { $0.id < $1.id }
        c.pending = waiting.sorted { $0.id < $1.id }
        return c
    }

    public var typing: [Entry] { entries.filter { $0.manifest?.kind == .typing } }

    /// 个人化组件：用户确认过的第三方个人化组件，否则自带的。
    public func personal(approved: [String: String]) -> Entry? {
        let ok = entries.filter { $0.manifest?.kind == .personal && Self.usable($0, approved: approved) }
        return ok.first { !$0.bundled } ?? ok.first
    }

    /// 当前引擎：设置里指定的（能用的话），否则第一个自带的打字引擎。第三方引擎不会被自动选中。
    public func current(_ config: ShellConfig) -> Entry? {
        if let id = config.currentEngine, let e = typing.first(where: { $0.id == id }), Self.usable(e, approved: config.approvedEngines) { return e }
        return typing.first { $0.bundled && Self.usable($0, approved: config.approvedEngines) }
    }

    /// 第三方引擎不能有的声明（联网、GPU、额外的写入位置）；自带的为 nil。
    public static func refusal(_ e: Entry) -> String? { e.bundled ? nil : e.manifest.flatMap(ThirdParty.refusal) }

    /// 用户确认过（自带的不用确认）：确认时记下的指纹和现在的一样。
    public static func isApproved(_ e: Entry, approved: [String: String]) -> Bool {
        e.bundled || (e.fingerprint != nil && approved[e.id] == e.fingerprint)
    }

    /// 能启动：引擎说明读得懂、没有第三方不能有的声明、确认过。
    public static func usable(_ e: Entry, approved: [String: String]) -> Bool {
        e.manifest != nil && refusal(e) == nil && isApproved(e, approved: approved)
    }

    /// 记忆同意的键：自带的是标识；第三方的带上指纹，同名的不继承自带的同意，确认的内容变了也要重新同意。
    public static func consentKey(_ e: Entry) -> String { e.bundled ? e.id : "\(e.id)@\(e.fingerprint ?? "?")" }

    /// 说明里有麦克风、是快捷键引擎：自带的语音（语音开关管它）。
    public static func isVoice(_ m: Manifest) -> Bool { m.kind == .hotkey && m.permissions.microphone }
}
