import Foundation

/// JSON 文件状态（M1 够用；M2 换 SQLite 便于历史查询）
/// - uploaded: 目标站 -> dedupKey -> 时间戳（转种成功记录）
/// - pushed: dedupKey -> 下载器标识（推种记录）
/// - targetURLs: 目标站 -> dedupKey -> 转种后的新种子详情页（用于推送/重试目标站 torrent）
/// - lastGistSync: 上次 gist 同步时间
public final class StateStore {
    /// 单站 cookie 检测结果（持久化：同步导入时判断本地 cookie 是否「已检测为失效」，
    /// 防止备份中的旧值覆盖本地有效 cookie、重启后判断丢失）
    public struct CookieCheckRec: Codable {
        public var ok: Bool
        public var message: String
        public var time: Double
        public init(ok: Bool, message: String, time: Double) {
            self.ok = ok; self.message = message; self.time = time
        }
    }

    struct Snapshot: Codable {
        var uploaded: [String: [String: Double]] = [:]
        var pushed: [String: String] = [:]
        var targetURLs: [String: [String: String]] = [:]   // 目标站 -> dedupKey -> 新种子详情页
        var lastGistSync: Double?
        var notes: [String] = []
        var importedZips: [String: Double] = [:]     // 已导入的 PTD_backup zip 文件名 -> 时间戳
        var cookieChecks: [String: CookieCheckRec] = [:]   // siteID -> 最近一次 cookie 检测结果

        init() {}

        // 兼容旧版 state.json（无 targetURLs 字段）
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uploaded = try c.decodeIfPresent([String: [String: Double]].self, forKey: .uploaded) ?? [:]
            pushed = try c.decodeIfPresent([String: String].self, forKey: .pushed) ?? [:]
            targetURLs = try c.decodeIfPresent([String: [String: String]].self, forKey: .targetURLs) ?? [:]
            lastGistSync = try c.decodeIfPresent(Double.self, forKey: .lastGistSync)
            notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
            importedZips = try c.decodeIfPresent([String: Double].self, forKey: .importedZips) ?? [:]
            cookieChecks = try c.decodeIfPresent([String: CookieCheckRec].self, forKey: .cookieChecks) ?? [:]
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

    /// 从磁盘重新加载（多进程共用 state.json：CLI 与 App 各自持有内存快照，
    /// 运行流水线前 reload 可避免旧快照覆盖另一进程写入的记录）
    public func reload() {
        lock.lock(); defer { lock.unlock() }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let s2 = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = s2
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
    public func cookieCheck(_ siteID: String) -> CookieCheckRec? {
        lock.lock(); defer { lock.unlock() }
        return snapshot.cookieChecks[siteID]
    }
    public func setCookieCheck(siteID: String, ok: Bool, message: String) {
        lock.lock(); defer { lock.unlock() }
        snapshot.cookieChecks[siteID] = CookieCheckRec(ok: ok, message: message, time: Date().timeIntervalSince1970)
        saveLocked()
    }
    public func clearCookieCheck(_ siteID: String) {
        lock.lock(); defer { lock.unlock() }
        if snapshot.cookieChecks.removeValue(forKey: siteID) != nil { saveLocked() }
    }
    public func clearAllCookieChecks() {
        lock.lock(); defer { lock.unlock() }
        if !snapshot.cookieChecks.isEmpty {
            snapshot.cookieChecks = [:]
            saveLocked()
        }
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
