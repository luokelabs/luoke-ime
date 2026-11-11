import Foundation

/// 引擎的 Seatbelt 沙盒（ADR 0006）：一份固定的规则模板（SandboxTemplate.swift，默认全拒 + Apple 的 system.sb），
/// 每个引擎的所需权限通过 `-D` 参数传进去，不拼接规则文本。实测结论见 research/seatbelt/README.md。
public enum SandboxProfile {
    /// sandbox-exec 的参数（不含要运行的命令本身）。
    /// `memory`：声明了 permissions.memory 时放行的记忆文件（个人化组件用）。
    /// `luokeHome`：一律不可读的螺壳目录，缺省是真的 ~/.luoke；只有测试传自己的临时目录。
    /// `home`：家目录（挡住的钥匙、凭据等都在它下面），缺省是真的；只有测试传自己的临时目录。
    public static func arguments(manifest: Manifest, tag: String, engineDir: URL, dataDir: URL, tmpDir: URL, paths: Paths,
                                 memory: URL? = nil, luokeHome: URL? = nil, home: URL? = nil, sharedTemporaryItems: Bool = true) -> [String] {
        let home = home ?? FileManager.default.homeDirectoryForCurrentUser
        let p = manifest.permissions
        var params: [(String, String)] = [
            ("ENGINE_ID", tag),
            ("ENGINE_DIR", realPath(engineDir.path)),
            ("DATA_DIR", realParent(dataDir.path)),
            ("TMP_DIR", realParent(tmpDir.path)),
            ("DATA_ROOT", realPath(paths.dataRoot.path)),
            ("TMP_ROOT", realPath(paths.tmpRoot.path)),
            ("SHELL_ROOT", realPath(paths.root.path)),
            ("HOME", realPath(home.path)),
            ("LUOKE_HOME", realPath((luokeHome ?? home.appendingPathComponent(".luoke")).path)),
            ("NET", p.network.rawValue),
            ("MIC", p.microphone ? "1" : "0"),
            ("CAM", p.camera ? "1" : "0"),
            ("SCREEN", p.screen ? "1" : "0"),
            ("GPU", p.gpu ? "1" : "0"),
        ]
        if sharedTemporaryItems, let t = darwinDir(_CS_DARWIN_USER_TEMP_DIR) { params.append(("USER_TMP", t)) }
        if p.gpu, let c = darwinDir(_CS_DARWIN_USER_CACHE_DIR) { params.append(("USER_CACHE", c)) }
        for (i, w) in p.write.prefix(16).enumerated() { params.append(("WRITE_\(i)", realParent(expand(w)))) }
        // 记忆文件归个人化组件写，它能把 mem.db 换成指向别处的链接：同数据目录一样只解析上级目录
        if p.memory, let memory {
            let db = realParent(memory.path)
            params.append(("MEM_DB", db))
            params.append(("MEM_DIR", (db as NSString).deletingLastPathComponent))
        }
        if p.network == .local {
            for (i, port) in p.localPorts.prefix(8).enumerated() { params.append(("LOCAL_PORT_\(i)", String(port))) }
        }
        return ["-p", sandboxTemplate] + params.flatMap { ["-D", "\($0.0)=\($0.1)"] }
    }

    /// 写进日志标签的引擎名：只能含 [A-Za-z0-9._-]。名字里有别的字符时，换成下划线并加一段短哈希以免重名。
    public static func tag(for id: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let cleaned = String(id.map { allowed.contains($0) ? $0 : "_" }.prefix(48))
        if cleaned == id, !id.isEmpty { return id }
        var h: UInt32 = 2166136261 // FNV-1a
        for b in id.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return (cleaned.isEmpty ? "engine" : cleaned) + "-" + String(h, radix: 16)
    }

    static func expand(_ path: String) -> String {
        path == "~" || path.hasPrefix("~/") ? FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst() : path
    }

    /// 引擎自己能改动的位置（数据目录、临时目录、声明的可写路径）只解析上级目录，不跟随最后一级的符号链接：
    /// 引擎能把这些目录本身换成指向别处（比如家目录）的链接，跟随的话下次启动就把那里整个放开了。
    /// 不跟随时，经链接写到的真实位置不在放行范围内，照样被拦。
    static func realParent(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = url.deletingLastPathComponent().path
        guard parent != url.path else { return url.path }
        return (parent == "/" ? "" : realPath(parent)) + "/" + url.lastPathComponent
    }

    /// Seatbelt 按真实路径匹配（/tmp → /private/tmp）。路径不存在时，解析最近的存在的上级再接回去。不带结尾的 /。
    static func realPath(_ path: String) -> String {
        if let r = realpath(path, nil) {
            defer { free(r) }
            return String(cString: r)
        }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        guard parent != path, parent != "/" else { return path }
        return realPath(parent) + "/" + url.lastPathComponent
    }

    /// DARWIN_USER_TEMP_DIR / DARWIN_USER_CACHE_DIR 的真实路径（带结尾 /）。
    /// Swift 的原子写会用到临时目录下的 TemporaryItems；Metal 着色器编译器把缓存写在缓存目录下。
    static func darwinDir(_ name: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(name, &buf, buf.count) > 0 else { return nil }
        return realPath(String(cString: buf)) + "/"
    }
}

/// 沙盒拦下的一次操作，从统一日志里读来。
public struct SandboxDenial: Equatable {
    public enum Severity: String { case hard, soft }
    /// 引擎的日志标签（SandboxProfile.tag）。
    public var engine: String
    public var process: String
    public var pid: Int
    public var operation: String
    public var detail: String
    /// 规则里标的类别：write、write-protected、read-protected、read-other-engine-data、read-secret、network、dns、
    /// microphone、camera、screen、tcc、exfil、other。
    public var category: String
    /// 内核对相同的拒绝限流时折叠掉的次数。
    public var duplicates: Int
    public var severity: Severity
    /// 该补哪条声明，或为什么不能放行。
    public var suggestion: String

    /// 菜单里的一行：做了什么、对着哪里，路径太长时截掉中间。完整的说明在 `suggestion`。
    public var summary: String {
        let path = Self.shorten(detail)
        switch category {
        case "write", "write-protected": return "写 \(path)"
        case "read-protected", "read-other-engine-data", "read-secret": return "读 \(path)"
        case "network":
            if detail.hasPrefix("/") { return "连 unix socket \(path)" }
            return "联网（端口 \(detail.split(separator: ":").last.map(String.init) ?? "?")）"
        case "dns": return "名称解析 \(Self.shorten(detail, max: 32))"
        case "microphone": return "用麦克风"
        case "camera": return "用摄像头"
        case "screen": return "读屏幕"
        case "exfil": return "借别的程序外发（\(operation)）"
        default: return "\(operation) \(path)"
        }
    }

    /// 家目录写成 ~，超过 `max` 个字时留头尾、中间换成 …
    static func shorten(_ path: String, max: Int = 44) -> String {
        var p = path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if p == home || p.hasPrefix(home + "/") { p = "~" + p.dropFirst(home.count) }
        guard p.count > max else { return p }
        let tail = max * 2 / 3, head = max - tail - 1
        return String(p.prefix(head)) + "…" + String(p.suffix(tail))
    }

    /// 解析 `log stream --style ndjson` 的一行里的 eventMessage。
    public static func parse(eventMessage m: String) -> SandboxDenial? {
        // 标签在最后一行，而且整行只能是 "LUOKE[<引擎>] <类别>"：被拦的路径里可能夹着换行和假标签
        let lines = m.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return nil }
        var head = String(lines[0])
        var dups = 0
        if let r = head.range(of: #"^\d+ duplicate reports? for "#, options: .regularExpression) {
            dups = Int(head[r].prefix { $0.isNumber }) ?? 0
            head.removeSubrange(r)
        }
        guard head.hasPrefix("Sandbox: ") else { return nil }
        let regex = try! NSRegularExpression(pattern: #"^Sandbox: (.+?)\((\d+)\) deny\(\d+\) ([\w\-\*]+) ?(.*)$"#)
        let ns = head as NSString
        guard let match = regex.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> String { match.range(at: i).location == NSNotFound ? "" : ns.substring(with: match.range(at: i)) }
        let tagLine = (lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "").trimmingCharacters(in: .whitespaces) as NSString
        let tagRegex = try! NSRegularExpression(pattern: #"^LUOKE\[([A-Za-z0-9._-]+)\] ([a-z-]+)$"#)
        guard let t = tagRegex.firstMatch(in: tagLine as String, range: NSRange(location: 0, length: tagLine.length)) else { return nil }
        let engine = tagLine.substring(with: t.range(at: 1)), category = tagLine.substring(with: t.range(at: 2))
        var d = SandboxDenial(engine: engine, process: g(1), pid: Int(g(2)) ?? 0, operation: g(3), detail: g(4),
                              category: category, duplicates: dups, severity: .soft, suggestion: "")
        (d.severity, d.suggestion) = hint(d)
        return d
    }

    static func hint(_ d: SandboxDenial) -> (Severity, String) {
        let detail = d.detail
        switch d.category {
        case "write" where detail.contains("/__pycache__"):
            return (.soft, "Python 想写字节码缓存（\(detail)），不影响运行")
        case "write":
            let target = d.operation == "file-write-create" ? (detail as NSString).deletingLastPathComponent : detail
            return (.hard, "写 \(detail) 被拦：要写那里就在 permissions.write 里加入 \(target)；自己的数据请写到 LUOKE_IME_DATA")
        case "write-protected":
            return (.hard, "写 \(detail) 被拦：引擎文件夹、壳的目录、启动项、shell 配置、~/.ssh 永远不可写，请写到 LUOKE_IME_DATA")
        case "read-protected", "read-other-engine-data":
            return (.hard, "读 \(detail) 被拦：输入记录、壳的设置、别的引擎的数据、~/.luoke 下螺壳其他工具的数据（比如记忆）都不可读")
        case "read-secret":
            return (.hard, "读 \(detail) 被拦：钥匙和凭据（~/.ssh、钥匙串、云服务的登录信息）、浏览器和邮件的数据、shell 历史，任何引擎都不可读")
        case "network":
            if detail.hasPrefix("/") {
                return (.hard, "连 unix socket \(detail) 被拦：任何档位都不放行，请改用 127.0.0.1 的 TCP 端口并声明 network: local")
            }
            let port = detail.split(separator: ":").last.map(String.init) ?? "?"
            return (.hard, "联网（端口 \(port)）被拦：只连本机就声明 permissions.network: \"local\"（可再用 local_ports 限定端口），要上网就声明 \"any\"")
        case "dns":
            return (.soft, "名称解析被拦（\(detail)）：只有要解析 localhost 以外的主机名时才需要 network: \"any\"")
        case "tcc":
            return (.soft, "引擎在查系统隐私授权（\(detail)）：要用麦克风、摄像头或屏幕就声明对应的 permissions")
        case "microphone": return (.hard, "用麦克风被拦：声明 permissions.microphone: true")
        case "camera": return (.hard, "用摄像头被拦：声明 permissions.camera: true")
        case "screen": return (.hard, "读屏幕被拦：声明 permissions.screen: true")
        case "exfil" where d.operation == "mach-lookup" && detail.hasPrefix("com.apple.distributed_notifications"):
            // 系统的录音、界面组件会顺手连分布式通知（比如监听音频设备变化），被拦也不影响功能；照样不放行（能拿来外发），只是不提示
            return (.soft, "系统组件想连分布式通知（\(detail)），不放行，一般不影响功能")
        case "exfil":
            return (.hard, "借别的程序外发、读剪贴板或创建后台任务被拦（\(d.operation) \(detail)）：没有对应的声明，永远不放行")
        default:
            return (.soft, "其他被拦的操作：\(d.operation) \(detail)")
        }
    }
}

/// 常驻的 `log stream`，把沙盒拒绝事件交给回调。实测订阅后约 0.04 秒生效，事件延迟不到 1 毫秒。
///
/// `log stream` 套在一个小 sh 里起：sh 读我们给的管道，我们退出（哪怕被强制结束）管道就到头，sh 随即结束 `log stream`。
/// 直接起的话，父进程被结束后它成了孤儿、一直挂着（实测，luokelabs/luoke-ime#12）；它平时几乎不往外写，等不到 SIGPIPE。
public final class SandboxMonitor {
    public var onDenial: ((SandboxDenial) -> Void)?
    private var process: Process?
    /// 写端一直留在我们手里、从不写；关掉（或我们退出）时 sh 读到头。
    private var lifeline: Pipe?
    private let ready = DispatchSemaphore(value: 0)
    private var signaled = false
    private let lock = NSLock()

    public init() {}

    /// 启动并等到订阅生效（最多 `timeout` 秒）。返回是否成功（非管理员用户可能不行）。
    @discardableResult
    public func start(timeout: TimeInterval = 2) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #""$@" </dev/null & pid=$!; read -r _; kill "$pid" 2>/dev/null"#, "sh",
                       "/usr/bin/log", "stream", "--style", "ndjson", "--predicate", #"sender == "Sandbox" AND eventMessage CONTAINS "LUOKE[""#]
        let out = Pipe()
        let life = Pipe()
        p.standardInput = life
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        var buffer = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                self?.handle(line)
            }
        }
        do { try p.run() } catch { return false }
        lock.lock()
        process = p
        lifeline = life
        lock.unlock()
        guard ready.wait(timeout: .now() + timeout) == .success else { return false }
        usleep(50_000) // 首行出现后订阅很快生效，再留一点余量
        return true
    }

    /// 套着 log stream 的那个 sh 的进程号（测试用）。
    var shellPID: Int32? { lock.lock(); defer { lock.unlock() }; return process?.processIdentifier }

    public func stop() {
        lock.lock()
        let life = lifeline
        process = nil
        lifeline = nil
        lock.unlock()
        try? life?.fileHandleForWriting.close() // sh 读到头，结束 log stream 后自己退出
    }

    deinit { stop() }

    private func handle(_ line: Data) {
        lock.lock()
        if !signaled { signaled = true; ready.signal() } // 首行是 "Filtering the log data using ..."
        lock.unlock()
        guard line.first == UInt8(ascii: "{"),
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let msg = obj["eventMessage"] as? String,
              let d = SandboxDenial.parse(eventMessage: msg) else { return }
        onDenial?(d)
    }
}
