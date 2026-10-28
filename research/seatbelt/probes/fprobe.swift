// fprobe: 只用 Foundation 的小命令行程序，模拟"用 Swift 写的引擎"。
// 每个子命令往 stdout 打一行 JSON: {"probe":..,"ok":true/false,"detail":..}
import Foundation
import UniformTypeIdentifiers

func emit(_ probe: String, _ ok: Bool, _ detail: String) {
    let d: [String: Any] = ["probe": probe, "ok": ok, "detail": detail]
    let data = try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "basic"

func fetch(_ urlStr: String, timeout: TimeInterval = 3) -> (Bool, String) {
    guard let url = URL(string: urlStr) else { return (false, "bad url") }
    var cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = timeout
    cfg.timeoutIntervalForResource = timeout
    let session = URLSession(configuration: cfg)
    let sem = DispatchSemaphore(value: 0)
    var result = (false, "no result")
    session.dataTask(with: url) { data, resp, err in
        if let err = err { result = (false, "\(err)") }
        else if let http = resp as? HTTPURLResponse, let data = data {
            result = (true, "HTTP \(http.statusCode), \(data.count) bytes: \(String(data: data.prefix(40), encoding: .utf8) ?? "")")
        }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 2)
    return result
}

switch cmd {
case "basic":
    // 普通 Swift 引擎会做的事：ProcessInfo / 日期 / JSON / 读 HOME / 读 UserDefaults / 起子进程
    var parts: [String] = []
    parts.append("pid=\(ProcessInfo.processInfo.processIdentifier)")
    let df = DateFormatter(); df.dateStyle = .medium; df.locale = Locale.current
    parts.append("date=\(df.string(from: Date(timeIntervalSince1970: 0)))")
    parts.append("locale=\(Locale.current.identifier)")
    parts.append("tz=\(TimeZone.current.identifier)")
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let n = (try? FileManager.default.contentsOfDirectory(atPath: home).count) ?? -1
    parts.append("home_entries=\(n)")
    let enc = try! JSONEncoder().encode(["a": 1]); parts.append("json=\(String(data: enc, encoding: .utf8)!)")
    let ud = UserDefaults.standard.string(forKey: "AppleLocale") ?? "nil"; parts.append("AppleLocale=\(ud)")
    parts.append("cwd=\(FileManager.default.currentDirectoryPath)")
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/echo"); p.arguments = ["child"]
    let pipe = Pipe(); p.standardOutput = pipe
    do { try p.run(); p.waitUntilExit(); parts.append("child=\(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines))") } catch { parts.append("child_err=\(error)") }
    emit("basic", true, parts.joined(separator: "; "))
case "write":
    let path = args[2]
    do { try "x".write(toFile: path, atomically: false, encoding: .utf8); emit("write", true, path) }
    catch { emit("write", false, "\(error)") }
case "write-atomic":
    let path = args[2]
    do { try "x".write(toFile: path, atomically: true, encoding: .utf8); emit("write-atomic", true, path) }
    catch { emit("write-atomic", false, "\(error)") }
case "tmpdir":
    let t = NSTemporaryDirectory()
    let f = t + "/fprobe-\(getpid()).tmp"
    do { try "x".write(toFile: f, atomically: true, encoding: .utf8); try FileManager.default.removeItem(atPath: f); emit("tmpdir", true, t) }
    catch { emit("tmpdir", false, "\(t) \(error)") }
case "fetch":
    let (ok, d) = fetch(args[2]); emit("fetch", ok, d)
case "resolve":
    // 只做名称解析，不发任何外部连接（localhost / 本机 hostname）
    var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>? = nil
    let rc = getaddrinfo(args[2], nil, &hints, &res)
    if rc == 0 { freeaddrinfo(res); emit("resolve", true, "\(args[2]) ok") }
    else { emit("resolve", false, "\(args[2]) gai=\(rc) \(String(cString: gai_strerror(rc)))") }
case "ls-dependent":
    // 依赖 LaunchServices 数据库的 Foundation / UTType 功能：被封后哪些坏了
    var parts: [String] = []
    parts.append("UTType(txt)=\(UTType(filenameExtension: "txt")?.identifier ?? "nil")")
    parts.append("UTType(pdf).conforms(data)=\(UTType(filenameExtension: "pdf")?.conforms(to: .data) ?? false)")
    let u = URL(fileURLWithPath: "/etc/hosts")
    let rv = try? u.resourceValues(forKeys: [.typeIdentifierKey, .contentTypeKey, .localizedTypeDescriptionKey, .isApplicationKey, .localizedNameKey])
    parts.append("typeIdentifier=\(rv?.typeIdentifier ?? "nil")")
    parts.append("contentType=\(rv?.contentType?.identifier ?? "nil")")
    parts.append("localizedName=\(rv?.localizedName ?? "nil")")
    parts.append("Bundle.main.bundleIdentifier=\(Bundle.main.bundleIdentifier ?? "nil")")
    parts.append("Bundle(path: Safari)=\(Bundle(path: "/Applications/Safari.app")?.bundleIdentifier ?? "nil")")
    parts.append("mimeType(for json)=\(UTType(filenameExtension: "json")?.preferredMIMEType ?? "nil")")
    emit("ls-dependent", true, parts.joined(separator: "; "))
default:
    emit(cmd, false, "unknown subcommand")
}
