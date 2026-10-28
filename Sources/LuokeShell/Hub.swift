import Foundation

/// 主控（luoke-core）的客户端：HTTP/1.1 跑在 Unix socket 上（luoke-core docs/V1.md §2 的线上格式，对外约定版本 1）。
/// 只有壳连主控；输入法引擎和个人化组件要用模型时，发 `to: "hub"` 的转问，由 AskBroker 经这里转过去。
/// 每个请求一条连接，用完就关（主控那边"取消 = 关闭连接"）。只依赖 Foundation 和 POSIX。
public final class HubClient {
    /// 请求头 X-Luoke-Accessory 的值：`luoke-ime/<版本>`。
    public let accessory: String
    public let socketPath: String

    public init(accessory: String, socketPath: String? = nil) {
        self.accessory = accessory
        self.socketPath = socketPath ?? HubClient.defaultSocket
    }

    /// 环境变量 LUOKE_HUB_SOCKET 优先，否则是装好的主控的位置。
    public static var defaultSocket: String {
        if let s = ProcessInfo.processInfo.environment["LUOKE_HUB_SOCKET"], !s.isEmpty { return s }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/luoke-core/run/hub.sock").path
    }

    public struct Response {
        public var status: Int
        public var body: Data
        /// 头，键都是小写（比如 x-luoke-tasks-version：任务参数等变了它就变，见 V1 §2）。
        public var headers: [String: String] = [:]
        public var json: JSONValue? { (try? JSONSerialization.jsonObject(with: body)).map { JSONValue($0) } }
    }

    public enum Failure: Error, Equatable {
        /// 连不上（主控没在运行、socket 不在）。
        case unreachable(String)
        /// 连上了但答复读不完或看不懂。
        case broken(String)
    }

    /// 发一个请求，同步等答复（在调用方自己的线程上；壳在后台队列上调）。
    public func request(_ method: String, _ path: String, body: JSONValue? = nil, timeout: TimeInterval = 5) -> Result<Response, Failure> {
        let payload = body.map { (try? JSONSerialization.data(withJSONObject: $0.any)) ?? Data() } ?? Data()
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nX-Luoke-Accessory: \(accessory)\r\nConnection: close\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        head += "Content-Length: \(payload.count)\r\n\r\n"

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.unreachable("socket: \(String(cString: strerror(errno)))")) }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return .failure(.unreachable("socket 路径太长")) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return .failure(.unreachable("连不上主控（\(String(cString: strerror(errno)))）")) }

        let out = Data(head.utf8) + payload
        let sent = out.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        guard sent else { return .failure(.broken("写请求失败")) }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { data.append(contentsOf: buf[0..<n]); continue }
            if n == 0 { break }
            return .failure(.broken(errno == EAGAIN ? "等答复超时" : "读答复失败"))
        }
        return Self.parse(data)
    }

    /// 解析 HTTP/1.1 答复：状态行、头、按 Content-Length 或 chunked 取正文（连接关了就是结束）。
    static func parse(_ data: Data) -> Result<Response, Failure> {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return .failure(.broken("答复不完整")) }
        let headText = String(decoding: data[..<sep.lowerBound], as: UTF8.self)
        let lines = headText.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else { return .failure(.broken("看不懂状态行")) }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(data[sep.upperBound...])
        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            var out = Data()
            var rest = body[...]
            while let nl = rest.range(of: Data("\r\n".utf8)) {
                let sizeText = String(decoding: rest[..<nl.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return .failure(.broken("chunked 看不懂")) }
                if size == 0 { break }
                let start = nl.upperBound
                guard rest.distance(from: start, to: rest.endIndex) >= size else { return .failure(.broken("chunked 不完整")) }
                let end = rest.index(start, offsetBy: size)
                out.append(rest[start..<end])
                rest = rest[end...].dropFirst(2)
            }
            body = out
        } else if let len = headers["content-length"].flatMap(Int.init), body.count > len {
            body = body.prefix(len)
        }
        return .success(Response(status: status, body: body, headers: headers))
    }
}
