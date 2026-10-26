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
        var existing: [String: [String: Double]] = [:]     // 目标站 -> dedupKey -> 判定「站内已有」的时间
        var lastGistSync: Double?
        var notes: [String] = []
        var importedZips: [String: Double] = [:]     // 已导入的 PTD_backup zip 文件名 -> 时间戳
        var cookieChecks: [String: CookieCheckRec] = [:]   // siteID -> 最近一次 cookie 检测结果
        /// 辅种：站点 -> 本地种子 info hash -> 已辅记录（含站内详情页与判定级别）
        var assisted: [String: [String: AssistRec]] = [:]
        /// 辅种负缓存：站点 -> hash -> 站内没检索到的时间。没找到也要记，
        /// 否则每轮都替站点重搜一遍同一条，纯属白跑（站点还嫌你烦）
        var assistMiss: [String: [String: Double]] = [:]
        /// 辅种失败：站点 -> hash -> 上次失败时间与原因。失败不算「站内没有」，下轮还要再试，
        /// 但界面要能数出「失败辅种」有多少、为什么砸的，所以单独记一张表。
        var assistFail: [String: [String: AssistFailRec]] = [:]
        /// 待复核：已经推进下载器，但没等到校验结果（等超时、中途退出）。
        /// 不落盘就没人收尾了——那条种子还在下载器里暂停着，下一轮又当新面孔重搜一遍，
        /// 白敲站点，还可能加出第二条。
        var assistReview: [String: [String: AssistReviewRec]] = [:]
        /// 人工否决：检索到的那条不是同一种子。永久别再拿它烦人，界面上留一条可撤销。
        var assistReject: [String: [String: Double]] = [:]
        /// 上次扫描下载器的时间与当时的 hash 集合摘要（增量扫描用）
        var assistScanTime: Double?
        var assistScanDigest: String?
        /// 上次扫描时的种子条数（报「上次 N 条 → 这次 M 条」用）
        var assistScanCount: Int?

        init() {}

        // 兼容旧版 state.json（无 targetURLs 字段）
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uploaded = try c.decodeIfPresent([String: [String: Double]].self, forKey: .uploaded) ?? [:]
            pushed = try c.decodeIfPresent([String: String].self, forKey: .pushed) ?? [:]
            targetURLs = try c.decodeIfPresent([String: [String: String]].self, forKey: .targetURLs) ?? [:]
            existing = try c.decodeIfPresent([String: [String: Double]].self, forKey: .existing) ?? [:]
            lastGistSync = try c.decodeIfPresent(Double.self, forKey: .lastGistSync)
            notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
            importedZips = try c.decodeIfPresent([String: Double].self, forKey: .importedZips) ?? [:]
            cookieChecks = try c.decodeIfPresent([String: CookieCheckRec].self, forKey: .cookieChecks) ?? [:]
            assisted = try c.decodeIfPresent([String: [String: AssistRec]].self, forKey: .assisted) ?? [:]
            assistMiss = try c.decodeIfPresent([String: [String: Double]].self, forKey: .assistMiss) ?? [:]
            assistFail = try c.decodeIfPresent([String: [String: AssistFailRec]].self, forKey: .assistFail) ?? [:]
            assistReview = try c.decodeIfPresent([String: [String: AssistReviewRec]].self, forKey: .assistReview) ?? [:]
            assistReject = try c.decodeIfPresent([String: [String: Double]].self, forKey: .assistReject) ?? [:]
            assistScanTime = try c.decodeIfPresent(Double.self, forKey: .assistScanTime)
            assistScanDigest = try c.decodeIfPresent(String.self, forKey: .assistScanDigest)
            assistScanCount = try c.decodeIfPresent(Int.self, forKey: .assistScanCount)
        }
    }

    /// 一条辅种记录
    struct AssistRec: Codable {
        var time: Double
        var url: String
        /// sameHash / sameFiles：靠什么判定是同一种子（界面上要说清）
        var level: String
    }

    /// 一条辅种失败。旧版 state.json 里只存一个时间戳，读出来原因留空。
    struct AssistFailRec: Codable {
        var time: Double
        var why: String

        private enum C: String, CodingKey { case time, why }

        init(time: Double, why: String) {
            self.time = time
            self.why = why
        }

        init(from d: Decoder) throws {
            if let t = try? d.singleValueContainer().decode(Double.self) {
                time = t; why = ""
                return
            }
            let c = try d.container(keyedBy: C.self)
            time = try c.decode(Double.self, forKey: .time)
            why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
        }
    }

    /// 一条待复核记录。siteHash 是加进下载器那条的哈希——站点重新打包过时它与本地 hash 不同，
    /// 回查校验只能按它问下载器。
    public struct AssistReviewRec: Codable {
        public var time: Double
        public var url: String
        public var siteHash: String
        public var level: String
        public var why: String

        public init(time: Double, url: String, siteHash: String, level: String, why: String) {
            self.time = time
            self.url = url
            self.siteHash = siteHash
            self.level = level
            self.why = why
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
    /// 本站记下「转种成功」的时间
    public func uploadedAt(site: String, key: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let t = snapshot.uploaded[site]?[key] else { return nil }
        return Date(timeIntervalSince1970: t)
    }
    /// 该站此前是判定「站内已有」（不是本次新发种）
    public func isExisting(site: String, key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return snapshot.existing[site]?[key] != nil
    }
    public func markExisting(site: String, key: String) {
        lock.lock(); defer { lock.unlock() }
        snapshot.existing[site, default: [:]][key] = Date().timeIntervalSince1970
        saveLocked()
    }
    /// 回站内看清了那条是自己发的：别再挂着「站内已有」的标记
    public func unmarkExisting(site: String, key: String) {
        lock.lock(); defer { lock.unlock() }
        guard snapshot.existing[site]?[key] != nil else { return }
        snapshot.existing[site]?.removeValue(forKey: key)
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

    // MARK: 辅种

    /// 这条本地种子在这个站已经辅过
    public func isAssisted(site: String, hash: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return snapshot.assisted[site]?[hash.lowercased()] != nil
    }

    public func markAssisted(site: String, hash: String, url: String, level: String) {
        lock.lock(); defer { lock.unlock() }
        snapshot.assisted[site, default: [:]][hash.lowercased()] =
            AssistRec(time: Date().timeIntervalSince1970, url: url, level: level)
        snapshot.assistMiss[site]?.removeValue(forKey: hash.lowercased())
        snapshot.assistFail[site]?.removeValue(forKey: hash.lowercased())
        snapshot.assistReview[site]?.removeValue(forKey: hash.lowercased())
        snapshot.assistReject[site]?.removeValue(forKey: hash.lowercased())
        saveLocked()
    }

    /// 站内没检索到这条的时间（超过 ttlSeconds 就不再拦着）
    public func assistMissedAt(site: String, hash: String, ttlSeconds: TimeInterval) -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let t = snapshot.assistMiss[site]?[hash.lowercased()] else { return nil }
        let at = Date(timeIntervalSince1970: t)
        return Date().timeIntervalSince(at) > ttlSeconds ? nil : at
    }

    public func markAssistMiss(site: String, hash: String) {
        lock.lock(); defer { lock.unlock() }
        snapshot.assistMiss[site, default: [:]][hash.lowercased()] = Date().timeIntervalSince1970
        snapshot.assistFail[site]?.removeValue(forKey: hash.lowercased())
        saveLocked()
    }

    /// 记一次辅种失败（检索到了但读不下来 / 加进下载器失败 / 校验不满被删）：下轮还会再试。
    /// 原因一起记：待处理队列要就地说明为什么砸的，光有个时间没法定位。
    public func markAssistFail(site: String, hash: String, why: String = "") {
        lock.lock(); defer { lock.unlock() }
        snapshot.assistFail[site, default: [:]][hash.lowercased()] =
            AssistFailRec(time: Date().timeIntervalSince1970, why: why)
        snapshot.assistReview[site]?.removeValue(forKey: hash.lowercased())
        saveLocked()
    }

    public func assistFailedAt(site: String, hash: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return snapshot.assistFail[site]?[hash.lowercased()].map { Date(timeIntervalSince1970: $0.time) }
    }

    // MARK: 辅种：待复核 / 人工否决

    /// 推进了下载器但没等到校验结果
    public func markAssistReview(site: String, hash: String, url: String, siteHash: String,
                                 level: String, why: String) {
        lock.lock(); defer { lock.unlock() }
        snapshot.assistReview[site, default: [:]][hash.lowercased()] =
            AssistReviewRec(time: Date().timeIntervalSince1970, url: url, siteHash: siteHash,
                            level: level, why: why)
        snapshot.assistFail[site]?.removeValue(forKey: hash.lowercased())
        saveLocked()
    }

    public func clearAssistReview(site: String, hash: String) {
        lock.lock(); defer { lock.unlock() }
        if snapshot.assistReview[site]?.removeValue(forKey: hash.lowercased()) != nil { saveLocked() }
    }

    public func assistReviewRecs(site: String) -> [String: AssistReviewRec] {
        lock.lock(); defer { lock.unlock() }
        return snapshot.assistReview[site] ?? [:]
    }

    /// 这条是「人工否决」过的（检索到但不算同一种子）
    public func isAssistRejected(site: String, hash: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return snapshot.assistReject[site]?[hash.lowercased()] != nil
    }

    public func markAssistReject(site: String, hash: String) {
        lock.lock(); defer { lock.unlock() }
        snapshot.assistReject[site, default: [:]][hash.lowercased()] = Date().timeIntervalSince1970
        snapshot.assistReview[site]?.removeValue(forKey: hash.lowercased())
        snapshot.assistFail[site]?.removeValue(forKey: hash.lowercased())
        saveLocked()
    }

    public func clearAssistReject(site: String, hash: String) {
        lock.lock(); defer { lock.unlock() }
        if snapshot.assistReject[site]?.removeValue(forKey: hash.lowercased()) != nil { saveLocked() }
    }

    // MARK: 辅种批量取表（全量目录算计数用：上万种子 × 上百个站不能一条条问）

    /// 这个站已辅过的全部 hash
    public func assistedHashes(site: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(snapshot.assisted[site]?.keys ?? [:].keys)
    }

    /// 这个站「站内没有」还在负缓存期内的 hash
    public func assistMissHashes(site: String, ttlSeconds: TimeInterval) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        guard let table = snapshot.assistMiss[site] else { return [] }
        let cutoff = Date().timeIntervalSince1970 - ttlSeconds
        return Set(table.filter { $0.value >= cutoff }.map { $0.key })
    }

    /// 这个站上轮失败的 hash
    public func assistFailHashes(site: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(snapshot.assistFail[site]?.keys ?? [:].keys)
    }

    /// 这个站待复核的 hash（等校验结果，本轮不该再去站内重搜）
    public func assistReviewHashes(site: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(snapshot.assistReview[site]?.keys ?? [:].keys)
    }

    /// 这个站被人工否决过的 hash
    public func assistRejectHashes(site: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(snapshot.assistReject[site]?.keys ?? [:].keys)
    }

    /// 待处理队列的素材：各站待复核 / 失败 / 已否决 的条目（不含「待人工确认」，
    /// 那种只在跑的那一轮里存在，由调用方从实时进展里补）
    public func assistQueueEntries() -> [AssistQueueEntry] {
        lock.lock(); defer { lock.unlock() }
        var out: [AssistQueueEntry] = []
        for (site, table) in snapshot.assistReview {
            for (hash, rec) in table {
                out.append(AssistQueueEntry(siteID: site, hash: hash, kind: .review,
                                           why: rec.why, time: rec.time, url: rec.url))
            }
        }
        for (site, table) in snapshot.assistFail {
            for (hash, rec) in table {
                out.append(AssistQueueEntry(siteID: site, hash: hash, kind: .failed,
                                           why: rec.why, time: rec.time))
            }
        }
        for (site, table) in snapshot.assistReject {
            for (hash, t) in table {
                out.append(AssistQueueEntry(siteID: site, hash: hash, kind: .rejected,
                                           why: "人工判定不是同一种子", time: t))
            }
        }
        return out
    }

    /// 记一次扫描（增量扫描靠它：种子集合没变、站点也没新增，就没什么可搜的）
    public var assistScanWatermark: (time: Date?, digest: String?) {
        lock.lock(); defer { lock.unlock() }
        return (snapshot.assistScanTime.map { Date(timeIntervalSince1970: $0) }, snapshot.assistScanDigest)
    }

    public func setAssistScan(digest: String, count: Int) {
        lock.lock(); defer { lock.unlock() }
        snapshot.assistScanTime = Date().timeIntervalSince1970
        snapshot.assistScanDigest = digest
        snapshot.assistScanCount = count
        saveLocked()
    }

    /// 上次扫描的条数（报「上次 N 条 → 这次 M 条」）
    public var assistScanCount: Int? {
        lock.lock(); defer { lock.unlock() }
        return snapshot.assistScanCount
    }

    /// 各站已辅条数（辅种页在站点名后面写「辅过 N」）
    public func assistCountsBySite() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return snapshot.assisted.mapValues { $0.count }
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

/// 待处理队列里的一条历史记录（状态表 → 界面）
public struct AssistQueueEntry: Equatable {
    public enum Kind: String { case review, failed, rejected }
    public var siteID: String
    public var hash: String
    public var kind: Kind
    public var why: String
    public var time: Double
    /// 站内那条种子的详情页（待复核记录里有，点队列条目能直接跳过去看）
    public var url: String

    public init(siteID: String, hash: String, kind: Kind, why: String, time: Double,
                url: String = "") {
        self.siteID = siteID
        self.hash = hash
        self.kind = kind
        self.why = why
        self.time = time
        self.url = url
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
