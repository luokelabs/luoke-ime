import Foundation

/// 发现引擎文件夹里的文件变了（新增、删除、修改）。用轮询，不依赖平台的文件事件接口；引擎文件夹通常很小。
public final class FolderWatcher {
    public let dir: URL
    private var snapshot: [String: Date]

    public init(dir: URL) {
        self.dir = dir
        snapshot = FolderWatcher.scan(dir)
    }

    /// 和上次相比有没有变化。
    public func changed() -> Bool {
        let now = FolderWatcher.scan(dir)
        defer { snapshot = now }
        return now != snapshot
    }

    static func scan(_ dir: URL) -> [String: Date] {
        var out: [String: Date] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return out }
        for case let url as URL in e {
            if url.pathComponents.contains("__pycache__") || url.pathComponents.contains("node_modules") { e.skipDescendants(); continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            out[url.path] = v.contentModificationDate ?? .distantPast
        }
        return out
    }
}
