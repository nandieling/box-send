import Foundation

/// JSON 文件状态（M1 够用；M2 换 SQLite 便于历史查询）
/// - uploaded: 目标站 -> dedupKey -> 时间戳（转种成功记录）
/// - pushed: dedupKey -> 下载器标识（推种记录）
/// - targetURLs: 目标站 -> dedupKey -> 转种后的新种子详情页（用于推送/重试目标站 torrent）
/// - lastGistSync: 上次 gist 同步时间
public final class StateStore {
    struct Snapshot: Codable {
        var uploaded: [String: [String: Double]] = [:]
        var pushed: [String: String] = [:]
        var targetURLs: [String: [String: String]] = [:]   // 目标站 -> dedupKey -> 新种子详情页
        var lastGistSync: Double?
        var notes: [String] = []
        var rssSeen: [String: [String: Double]] = [:]      // 源站 -> rss guid -> 时间戳（已处理的新种）
        var importedZips: [String: Double] = [:]     // 已导入的 PTD_backup zip 文件名 -> 时间戳

        init() {}

        // 兼容旧版 state.json（无 targetURLs 字段）
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uploaded = try c.decodeIfPresent([String: [String: Double]].self, forKey: .uploaded) ?? [:]
            pushed = try c.decodeIfPresent([String: String].self, forKey: .pushed) ?? [:]
            targetURLs = try c.decodeIfPresent([String: [String: String]].self, forKey: .targetURLs) ?? [:]
            lastGistSync = try c.decodeIfPresent(Double.self, forKey: .lastGistSync)
            notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
            rssSeen = try c.decodeIfPresent([String: [String: Double]].self, forKey: .rssSeen) ?? [:]
            importedZips = try c.decodeIfPresent([String: Double].self, forKey: .importedZips) ?? [:]
        }
    }

    private let path: String
    private var snapshot: Snapshot
    private let lock = NSLock()
    /// 新日志回调（GUI 实时显示；在调用线程同步执行）
    public var onNote: ((String) -> Void)?

    public init(dataDir: String) {
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

    public func isUploaded(site: String, key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return snapshot.uploaded[site]?[key] != nil
    }
    public func markUploaded(site: String, key: String) {
        lock.lock(); defer { lock.unlock() }
        snapshot.uploaded[site, default: [:]][key] = Date().timeIntervalSince1970
        saveLocked()
    }
    public func isPushed(key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return snapshot.pushed[key] != nil
    }
    public func markPushed(key: String, id: String) {
        lock.lock(); defer { lock.unlock() }
        snapshot.pushed[key] = id
        saveLocked()
    }
    public func targetURL(site: String, key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return snapshot.targetURLs[site]?[key]
    }
    public func markTargetURL(site: String, key: String, url: String) {
        lock.lock(); defer { lock.unlock() }
        snapshot.targetURLs[site, default: [:]][key] = url
        saveLocked()
    }
    public func isRssSeen(site: String, guid: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return snapshot.rssSeen[site]?[guid] != nil
    }
    public func markRssSeen(site: String, guid: String) {
        lock.lock(); defer { lock.unlock() }
        var map = snapshot.rssSeen[site] ?? [:]
        // 每站最多保留 500 条，防 state.json 无限增长
        if map.count >= 500 {
            map = Dictionary(uniqueKeysWithValues: map.sorted { $0.value > $1.value }.prefix(300).map { ($0.key, $0.value) })
        }
        map[guid] = Date().timeIntervalSince1970
        snapshot.rssSeen[site] = map
        saveLocked()
    }
    public func isZipImported(name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return snapshot.importedZips[name] != nil
    }
    public func markZipImported(name: String) {
        lock.lock(); defer { lock.unlock() }
        var m = snapshot.importedZips
        if m.count >= 200 {
            m = Dictionary(uniqueKeysWithValues: m.sorted { $0.value > $1.value }.prefix(100).map { ($0.key, $0.value) })
        }
        m[name] = Date().timeIntervalSince1970
        snapshot.importedZips = m
        saveLocked()
    }
    public var lastGistSync: Double? {
        lock.lock(); defer { lock.unlock() }
        return snapshot.lastGistSync
    }
    public func setLastGistSync(_ t: Double) {
        lock.lock(); defer { lock.unlock() }
        snapshot.lastGistSync = t
        saveLocked()
    }
    public func note(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        snapshot.notes.append("\(ISO8601Time.stamp()): \(s)")
        if snapshot.notes.count > 500 { snapshot.notes.removeFirst(snapshot.notes.count - 500) }
        saveLocked()
        let cb = onNote
        cb?(snapshot.notes.last ?? "")
    }
    public var recentNotes: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(snapshot.notes.suffix(50))
    }

    private func saveLocked() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

public enum ISO8601Time {
    /// 日志时间戳：北京时间（Asia/Shanghai）
    public static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: Date())
    }
}
