import Foundation

/// JSON 文件状态（M1 够用；M2 换 SQLite 便于历史查询）
/// - uploaded: 目标站 -> dedupKey -> 时间戳（转种成功记录）
/// - pushed: dedupKey -> 下载器标识（推种记录）
/// - lastGistSync: 上次 gist 同步时间
final class StateStore {
    struct Snapshot: Codable {
        var uploaded: [String: [String: Double]] = [:]
        var pushed: [String: String] = [:]
        var lastGistSync: Double?
        var notes: [String] = []
    }

    private let path: String
    private var snapshot: Snapshot
    private let lock = NSLock()

    init(dataDir: String) {
        let dir = URL(fileURLWithPath: dataDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("state.json").path
        if let data = try? Data(contentsOf: dir.appendingPathComponent("state.json")),
           let s = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = s
        } else {
            snapshot = Snapshot()
        }
    }

    func isUploaded(site: String, key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return snapshot.uploaded[site]?[key] != nil
    }
    func markUploaded(site: String, key: String) {
        lock.lock(); defer { lock.unlock() }
        snapshot.uploaded[site, default: [:]][key] = Date().timeIntervalSince1970
        saveLocked()
    }
    func isPushed(key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return snapshot.pushed[key] != nil
    }
    func markPushed(key: String, id: String) {
        lock.lock(); defer { lock.unlock() }
        snapshot.pushed[key] = id
        saveLocked()
    }
    var lastGistSync: Double? {
        lock.lock(); defer { lock.unlock() }
        return snapshot.lastGistSync
    }
    func setLastGistSync(_ t: Double) {
        lock.lock(); defer { lock.unlock() }
        snapshot.lastGistSync = t
        saveLocked()
    }
    func note(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        snapshot.notes.append("\(ISO8601Time.stamp()): \(s)")
        if snapshot.notes.count > 500 { snapshot.notes.removeFirst(snapshot.notes.count - 500) }
        saveLocked()
    }
    var recentNotes: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(snapshot.notes.suffix(50))
    }

    private func saveLocked() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

enum ISO8601Time {
    static func stamp() -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: Date())
    }
}
