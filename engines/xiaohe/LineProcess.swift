import Foundation

/// 引擎自己的子进程（RIME、模型打分器）：按行发请求、按行读回复。子进程继承引擎的沙盒。
final class LineProcess {
    private let process = Process()
    private let input: FileHandle
    private let outFD: Int32
    private var buffer: [UInt8] = []
    /// 超时了还没读到的回复数。子进程按顺序答，晚到的回复要先丢掉，否则之后每次都会读到上一条的回复。
    private var owed = 0

    init(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
         onStderr: @escaping (String) -> Void = { _ in }) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let i = Pipe(), o = Pipe(), e = Pipe()
        process.standardInput = i
        process.standardOutput = o
        process.standardError = e
        input = i.fileHandleForWriting
        outFD = o.fileHandleForReading.fileDescriptor
        var pending = Data()
        e.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 0x0A) {
                onStderr(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...nl)
            }
        }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    /// 发一行；子进程已经退出（管道断了）时返回 false。
    @discardableResult
    func send(_ line: String) -> Bool {
        do {
            try input.write(contentsOf: Data((line + "\n").utf8))
            return true
        } catch {
            return false
        }
    }

    /// 读一行回复；超时或子进程退出时返回 nil。
    func readLine(timeout: TimeInterval) -> String? {
        readLine(until: Date().addingTimeInterval(timeout))
    }

    private func readLine(until deadline: Date) -> String? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<nl], as: UTF8.self)
                buffer.removeSubrange(...nl)
                return line
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var fds = pollfd(fd: outFD, events: Int16(POLLIN), revents: 0)
            guard poll(&fds, 1, Int32(remaining * 1000) + 1) > 0 else { return nil }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(outFD, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    /// 发一行，读一行。
    func ask(_ line: String, timeout: TimeInterval) -> String? {
        guard send(line) else { return nil }
        return reply(timeout: timeout)
    }

    /// 读最近一次请求的回复（先丢掉之前超时的请求晚到的回复）。
    func reply(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while owed > 0 {
            guard readLine(until: deadline) != nil else { owed += 1; return nil }
            owed -= 1
        }
        guard let reply = readLine(until: deadline) else { owed += 1; return nil }
        return reply
    }

    func terminate() { if process.isRunning { process.terminate() } }
}
