import Foundation

/// 自动批量辅种：扫描下载器 → 逐条种子 × 参与站点 → 站内检索 → 下载站点那份 .torrent
/// → 判定同一种子 → 加进下载器（先暂停）→ 校验复核 → 满 100% 才启动，否则按策略回滚。
///
/// 与转种的分工：转种要发新种，辅种只是把站内已有的那条挂到本账号下做种。
/// 站点侧负载由 `SiteThrottle` 统一收口 —— 所有对站点的请求（检索、详情、下载种子文件）
/// 都要先领号，一次领号算一次，不按「是不是搜索页」区别对待。
/// 「停止本轮」用的标志：界面线程写、跑轮的线程读
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool
    init(_ on: Bool) { self.on = on }
    func set(_ v: Bool) { lock.lock(); on = v; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
}

public final class AssistPipeline {
    let config: AppConfig
    let cookies: CookieStore
    let client: HTTPClient
    let state: StateStore
    let downloader: Downloader
    let throttle: SiteThrottle

    public init(config: AppConfig, cookies: CookieStore, state: StateStore,
                downloader: Downloader, throttle: SiteThrottle? = nil) {
        self.config = config
        self.cookies = cookies
        self.client = HTTPClient(cookies: cookies, userAgent: config.userAgent)
        self.state = state
        self.downloader = downloader
        self.throttle = throttle ?? SiteThrottle(limits: config.assist?.throttleLimits ?? .init())
    }

    /// 辅种用的是哪台下载器（界面显示：免得在错的机器上找种子）
    public var downloaderLabel: String { config.assistDownloader.label }

    /// 逐条进展（界面卡片用）。与转种分开一套：辅种多了「校验中」这一态，
    /// 因为「已添加」不等于「已辅种」——要等下载器校验到 100% 才算成。
    public struct Status: Equatable {
        public enum Phase: Equatable { case working, verifying, review, done, failed, skipped }
        public var siteID: String
        /// 哪条种子（下载器里的 v1 hash，小写）；站点级提示时为空
        public var hash: String
        public var torrentName: String
        public var text: String
        public var phase: Phase
        public var detail: String
        /// 界面定位行用
        public var rowKey: String { "\(siteID)|\(hash)" }
    }

    public struct Options {
        /// 本轮参与的站点（nil = 用配置里的白名单）
        public var siteIDs: [String]?
        /// 只报告不动下载器
        public var dryRun = false
        /// 本轮最多处理几条（0 = 不限）
        public var limit = 0
        /// 人工采纳的组合（"站点|种子 hash"）：跳过负缓存与「已辅过」预筛，
        /// 也不再停在「待人工确认」，直接按人的判断走推送流程
        public var forceKeys: Set<String> = []
        public var onEvent: ((Status) -> Void)?
        /// 等校验时的等待（注入点：单测不真睡觉）
        public var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        public init() {}
    }

    public struct Report {
        public var outcomes: [AssistOutcome] = []
        /// 本轮对站点发了多少次请求
        public var requests: Int { throttleUsed }
        public var throttleUsed = 0
        public var assistedCount: Int { outcomes.filter { $0.done }.count }
        /// 待人工确认：只有没被采纳的才算，人工采纳成功的已经进 assistedCount
        public var pendingCount: Int {
            outcomes.filter { if case .nameOnly = $0.level { return !$0.done }; return false }.count
        }
        public var skippedCount: Int {
            outcomes.filter { if case .skip = $0.level { return true }; return false }.count
        }
        /// 推进了下载器但没等到校验结果的条数
        public var reviewCount: Int { outcomes.filter { $0.review }.count }
        /// 中途被「停止本轮」打断（剩下的格子原样留着，下轮接着跑）
        public var stopped = false
    }

    /// 站点适配器工厂（默认走内置注册表；单测注入假适配器，不发真请求）
    var adapterFactory: (SiteConfig, HTTPClient) -> any SiteAdapter = { site, client in
        SiteRegistry.adapter(for: site, client: client)
    }

    // MARK: - 扫描

    /// 下载器里可以拿去辅种的种子（已完成 + 过大小/分类筛选）
    public func scanCandidates() throws -> [LocalTorrent] {
        guard let cfg = config.assist else { return [] }
        let all = try downloader.listTorrents()
        return all.filter { t in
            guard t.progress >= 0.999 else { return false }
            let gb = Double(t.totalSize) / 1_073_741_824
            if cfg.minSizeGB > 0, gb < cfg.minSizeGB { return false }
            if cfg.maxSizeGB > 0, gb > cfg.maxSizeGB { return false }
            if !cfg.categories.isEmpty {
                let mine = Set((t.category.map { [$0] } ?? []) + t.tags)
                if cfg.categories.first(where: { mine.contains($0) }) == nil { return false }
            }
            return true
        }
    }

    /// 扫描摘要：种子集合变没变（增量扫描的锚）+ 各站已辅多少
    public struct ScanSummary {
        public var torrents: [LocalTorrent]
        public var count: Int
        /// 上次扫描时的条数（nil = 没扫过）
        public var previousCount: Int?
        /// 首次扫描，或种子集合与上次不同
        public var changed: Bool
        public var lastScan: Date?
        public var assistedBySite: [String: Int]

        /// 给人看的一句：新增 / 有变化 / 没变
        public var deltaText: String {
            guard let prev = previousCount else { return "首次扫描：\(count) 条" }
            guard changed else { return "与上次扫描一致（\(count) 条）" }
            return count >= prev ? "比上次多 \(count - prev) 条（\(prev) → \(count)）"
                                 : "比上次少 \(prev - count) 条（\(prev) → \(count)）"
        }
    }

    /// 扫描并记账。种子集合摘要记进 state：辅种本来就能增量重跑（已辅过、站内没有
    /// 的两张表会拦住重复检索），这里只是让人看得出「这批里哪些是新面孔」。
    public func scanAndRecord() throws -> ScanSummary {
        let torrents = try scanCandidates()
        return recordScan(torrents: torrents)
    }

    @discardableResult
    public func recordScan(torrents: [LocalTorrent]) -> ScanSummary {
        let digest = Self.digest(of: torrents.map { $0.hash })
        let previous = state.assistScanWatermark
        let summary = ScanSummary(torrents: torrents, count: torrents.count,
                                  previousCount: state.assistScanCount,
                                  changed: previous.digest != digest,
                                  lastScan: previous.time,
                                  assistedBySite: state.assistCountsBySite())
        state.setAssistScan(digest: digest, count: torrents.count)
        return summary
    }

    /// FNV-1a 64：Swift 的 hashValue 每换一个进程就换一套哈希种子，跨启动比对会全判成「变了」
    static func digest(of hashes: [String]) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for hash in hashes.sorted() {
            for byte in hash.utf8 {
                h ^= UInt64(byte)
                h = h &* 0x100_0000_01b3
            }
            h ^= 0x1f
            h = h &* 0x100_0000_01b3
        }
        return String(format: "%016llx", h)
    }

    // MARK: - 执行

    /// 本轮请求已用 / 上限：界面上那句「本轮预算还剩多少」
    public var budget: (used: Int, total: Int) { throttle.budget }

    /// 追加本轮请求预算（不追节奏，只追次数上限）
    public func addBudget(_ n: Int) { throttle.addBudget(n) }

    /// 这一轮里有几条是靠宽松查询词才找到站内那条的
    public var relaxedHits: Int { relaxedHitCount }
    private var relaxedHitCount = 0

    public func requestStop() { stopFlag.set(true) }
    public var stopRequested: Bool { stopFlag.value }
    private let stopFlag = StopFlag(false)

    /// 那个标志：界面线程写、跑轮的线程读，裸 Bool 算数据竞争，套一层锁

    @discardableResult
    public func run(torrents: [LocalTorrent], opts: Options = Options()) -> Report {
        var report = Report()
        guard let cfg = config.assist else { return report }
        let ids = opts.siteIDs ?? cfg.siteIDs
        stopFlag.set(false)
        // 站点在外层：一个站连着处理多条种子，间隔才有意义（种子在外层会变成
        // 一条种子挨个站敲一遍，每站各敲一次，节奏全废）
        for id in ids {
            if stopRequested { report.stopped = true; break }
            guard let site = config.site(id) else { continue }
            if cfg.isPaused(id) {
                emit(opts, Status(siteID: id, hash: "", torrentName: "",
                                  text: "跳过：本站已暂停", phase: .skipped,
                                  detail: "在「辅种」页「进度」的逐站卡片上点一下就能恢复"))
                continue
            }
            let adapter = adapterFactory(SiteRegistry.effectiveSite(site), client)
            if !adapter.canPrecheckDuplicate {
                emit(opts, Status(siteID: id, hash: "", torrentName: "",
                                  text: "跳过：该站暂不支持站内检索", phase: .skipped,
                                  detail: "\(site.name) 没有可用的检索入口，辅种要靠检索找到站内那条"))
                continue
            }
            for t in torrents {
                if stopRequested { report.stopped = true; break }
                if opts.limit > 0, report.outcomes.count >= opts.limit { return report }
                let out = attempt(t, site: site, adapter: adapter, cfg: cfg, opts: opts)
                // 失败单独记一张表：不算「站内没有」，下轮还要再试，
                // 但界面要数得出失败几条、为什么砸的（待处理队列就地说明）
                if out.failed { state.markAssistFail(site: id, hash: t.hash, why: out.message) }
                report.outcomes.append(out)
                emit(opts, Status(siteID: id, hash: t.hash, torrentName: t.name,
                                  text: textOf(out), phase: phaseOf(out),
                                  detail: out.detailURL.map { "\(out.message)\n\($0)" } ?? out.message))
            }
        }
        report.throttleUsed = throttle.used
        return report
    }

    private func emit(_ opts: Options, _ s: Status) { opts.onEvent?(s) }

    private func textOf(_ o: AssistOutcome) -> String {
        if o.done { return "辅种成功" }
        switch o.level {
        case .sameHash, .sameFiles: return o.done ? "辅种成功" : "待复核"
        case .nameOnly: return "待人工确认"
        case .skip(let why): return "跳过：\(why)"
        }
    }

    private func phaseOf(_ o: AssistOutcome) -> Status.Phase {
        if o.done { return .done }
        if o.review { return .review }
        if o.failed { return .failed }
        switch o.level {
        case .sameHash, .sameFiles: return o.done ? .done : .verifying
        case .nameOnly: return .skipped
        case .skip: return .skipped
        }
    }

    // MARK: - 回查校验

    /// 回查「待复核」的结果汇总
    public struct RecheckReport {
        public var checked = 0
        /// 复核到 100%：这条算辅成了
        public var verified = 0
        /// 校验不满 / 下载器里已经没了：回滚并转失败
        public var dropped = 0
        /// 还在校验，下次再看
        public var waiting = 0

        public var text: String {
            guard checked > 0 else { return "没有待复核的种子" }
            return "回查 \(checked) 条：辅种成功 \(verified)，已回滚 \(dropped)，还在校验 \(waiting)"
        }
    }

    /// 回查上一轮没等到校验结果的种子。只问下载器，一次站点请求都不发，
    /// 所以随时能点，也不会给站点添负载。
    /// - Parameter names: hash → 种子名（界面上要说清复核的是哪条，核心库不重读下载器）
    @discardableResult
    public func recheckReviews(siteIDs: [String]? = nil, keys: Set<String> = [],
                               names: [String: String] = [:],
                               onEvent: ((Status) -> Void)? = nil) -> RecheckReport {
        var rep = RecheckReport()
        guard let cfg = config.assist else { return rep }
        func emit(_ id: String, _ hash: String, _ text: String, _ phase: Status.Phase,
                  url: String) {
            onEvent?(Status(siteID: id, hash: hash,
                            torrentName: names[hash] ?? "", text: text, phase: phase, detail: url))
        }
        for id in (siteIDs ?? cfg.siteIDs) {
            let recs = state.assistReviewRecs(site: id)
            guard !recs.isEmpty else { continue }
            for (hash, rec) in recs.sorted(by: { $0.key < $1.key }) {
                if !keys.isEmpty, !keys.contains("\(id)|\(hash)") { continue }
                rep.checked += 1
                guard let p = try? downloader.torrentProgress(hash: rec.siteHash) else {
                    state.clearAssistReview(site: id, hash: hash)
                    state.markAssistFail(site: id, hash: hash,
                                         why: "复核时下载器里已经没有这条种子")
                    emit(id, hash, "复核失败：下载器里已经没这条", .failed, url: rec.url)
                    rep.dropped += 1
                    continue
                }
                if p.progress >= 0.999 {
                    try? downloader.setPaused(hashes: [rec.siteHash], paused: false)
                    state.markAssisted(site: id, hash: hash, url: rec.url, level: rec.level)
                    state.note("assist[\(id)] REVIEW-OK \(names[hash] ?? hash) \(rec.level)")
                    emit(id, hash, "复核：校验到 100%，已启动", .done, url: rec.url)
                    rep.verified += 1
                    continue
                }
                // 校验早停了却不满：文件对不上，留着它会自己重下一整份
                if !isChecking(p.state) {
                    if cfg.removeOnVerifyFail {
                        try? downloader.removeTorrent(hash: rec.siteHash, keepFiles: true)
                    }
                    state.clearAssistReview(site: id, hash: hash)
                    state.markAssistFail(site: id, hash: hash,
                                         why: "复核时校验只到 \(Int(p.progress * 100))%"
                                            + (cfg.removeOnVerifyFail ? "，已删掉刚加的种子" : "，种子保持暂停"))
                    emit(id, hash, "复核：校验只到 \(Int(p.progress * 100))%", .failed, url: rec.url)
                    rep.dropped += 1
                    continue
                }
                rep.waiting += 1
                emit(id, hash, "还在校验（\(p.state)），稍后再回查", .review, url: rec.url)
            }
        }
        return rep
    }

    /// 人工否决 / 撤销否决：检索到的那条到底算不算同一种子，人说了算
    public func setRejected(_ key: String, rejected: Bool) {
        let parts = key.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return }
        if rejected {
            state.markAssistReject(site: String(parts[0]), hash: String(parts[1]))
        } else {
            state.clearAssistReject(site: String(parts[0]), hash: String(parts[1]))
        }
    }

    /// 发请求前的预筛：命中就一次请求都不花（已在该站做种 / 已辅过 / 负缓存期内）
    private struct PreSkip {
        let why: String
        let detail: String
    }

    private func preSkip(_ t: LocalTorrent, site: SiteConfig, cfg: AssistConfig) -> PreSkip? {
        if let host = AssistConfig.announceHost(of: site), t.trackerHosts.contains(host) {
            return PreSkip(why: "已在该站做种", detail: "这份文件的 tracker 里已经有 \(host)")
        }
        if state.isAssisted(site: site.id, hash: t.hash) {
            return PreSkip(why: "此前已辅过", detail: "本轮跳过，重跑不重复检索")
        }
        if state.assistReviewRecs(site: site.id)[t.hash.lowercased()] != nil {
            return PreSkip(why: "待复核（上次校验没等完）",
                           detail: "那条种子还在下载器里暂停着：用「回查校验」收尾，"
                                 + "本轮不重复检索，免得加出第二条")
        }
        if state.isAssistRejected(site: site.id, hash: t.hash) {
            return PreSkip(why: "人工判定不是同一种子", detail: "已经否决过，不再检索；界面上可以撤销")
        }
        if let f = cfg.assistFilter(site.id),
           let why = f.reject(t.name, sizeGB: Double(t.totalSize) / 1_073_741_824) {
            return PreSkip(why: "按本站筛选不辅（\(why)）", detail: "在「设置 → 辅种」的逐站筛选里改")
        }
        if state.assistMissedAt(site: site.id, hash: t.hash,
                               ttlSeconds: Double(cfg.missTTLDays) * 86_400) != nil {
            return PreSkip(why: "站内没有（\(cfg.missTTLDays) 天内查过）", detail: "负缓存生效，不重复检索")
        }
        return nil
    }

    /// 本轮计划：一条种子 × 一个站，预先标出哪些会跳过（不发任何站点请求）。
    /// 界面先给人看「这次要敲哪些站的门、大概敲几次」，再决定跑不跑。
    public struct PlanRow {
        public var siteID: String
        public var hash: String
        public var torrentName: String
        /// nil = 本轮会去站内检索；有值 = 直接跳过及原因
        public var skipReason: String?
        /// 计划阶段的结论。有它就以它为准：「上次失败」这类既不算跳过、又不是待辅种
        public var planned: RowStatus?
        /// 与 Status.rowKey 同一套拼法
        public var rowKey: String { "\(siteID)|\(hash)" }

        public init(siteID: String, hash: String, torrentName: String,
                    skipReason: String? = nil, planned: RowStatus? = nil) {
            self.siteID = siteID
            self.hash = hash
            self.torrentName = torrentName
            self.skipReason = skipReason
            self.planned = planned
        }
    }

    /// 「自动整轮」一次最多处理多少条种子（体积倒序取前 N 条）。
    /// 界面翻页不受这个数限制：整库都要能翻到，这只是后台整轮的处理量上限。
    public static let roundTorrentCap = 200

    /// 本轮实际要处理的候选（去重后按体积倒序裁到上限）
    public static func roundCandidates(_ torrents: [LocalTorrent], cap: Int = roundTorrentCap)
        -> [LocalTorrent] {
        Array(catalog(torrents).prefix(max(1, cap)))
    }

    // MARK: - 种子目录（去重）

    /// 同一份文件在下载器里常常有好几份：各站的 .torrent tracker 不同 → info hash 不同，
    /// 名字与体积却一样。整库列出来就是一片重复，按 hash 与名字各去一次重，留体积最大的那条。
    public static func dedupe(_ torrents: [LocalTorrent]) -> [LocalTorrent] {
        var byHash: [String: LocalTorrent] = [:]
        for t in torrents {
            let h = t.hash.lowercased()
            if let old = byHash[h], old.totalSize >= t.totalSize { continue }
            byHash[h] = t
        }
        var kept: [LocalTorrent] = []
        var byName: [String: LocalTorrent] = [:]
        for t in byHash.values.sorted(by: { $0.totalSize > $1.totalSize }) {
            let key = nameKey(t.name)
            // 名字归一化后相同、体积也差不到 1 MiB：站点重新打包只会多几 KB 说明文件
            if let old = byName[key], abs(old.totalSize - t.totalSize) <= nameSizeTolerance { continue }
            byName[key] = t
            kept.append(t)
        }
        return kept
    }

    /// 界面上的种子目录：去重 + 体积倒序
    public static func catalog(_ torrents: [LocalTorrent]) -> [LocalTorrent] {
        dedupe(torrents)
    }

    /// 重名判定用的大小容差：重新打包时多几 KB 的 .nfo / 说明文件
    static let nameSizeTolerance: Int64 = 1_048_576

    /// 种子名归一化：去掉容器后缀与分隔符，只留字母数字
    /// （同一条种子在不同站常被加上各自的后缀，空格/点/方括号都不该影响判重）
    static func nameKey(_ name: String) -> String {
        var s = Substring(name[...])
        if let dot = s.lastIndex(of: "."), containers.contains(String(s[s.index(after: dot)...]).lowercased()) {
            s = s[..<dot]
        }
        return String(s.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }

    private static let containers: Set<String> = [
        "mkv", "mp4", "avi", "m2ts", "ts", "m4v", "mov", "webm", "wmv", "iso", "img", "bin", "mks",
    ]

    // MARK: - 全量目录计划

    /// 一个站的分桶集合。整库 × 全站一条条问状态会是上百万次查表，
    /// 所以每个站只取一次表，之后全是集合运算。
    struct SiteBucket {
        var unsupported = false
        var seeding: Set<String> = []
        var assisted: Set<String> = []
        var review: Set<String> = []
        var rejected: Set<String> = []
        var missing: Set<String> = []
        var failed: Set<String> = []
        var filtered: Set<String> = []
        var filteredReason: [String: String] = [:]
        /// 整站暂停：本该「待辅种」的格子改标「已暂停」
        var pausedSite = false
    }

    /// 全量种子目录 × 辅种站点的计划：计数按全量算，格子按页摊。
    /// 1.2 万条种子 × 115 站 = 138 万格，整表摊开会把手绘端钉死，
    /// 所以这里存的是「每个站的分桶集合」，界面翻到某一页时只算那一页的格子。
    public struct CatalogPlan {
        /// 去重、体积倒序后的全量目录
        public var torrents: [LocalTorrent]
        public var siteIDs: [String]
        public var missTTLDays: Int
        /// 每个站还要检索多少次（算「照现在这个节奏还要跑多久」）
        public var pendingBySite: [String: Int]
        /// 逐站间隔与抖动、单轮预算：估算用的那三个数
        public var pace: (interval: TimeInterval, jitter: TimeInterval, roundBudget: Int)
        /// 组合总数（种子 × 站点）
        public var total: Int
        /// 会真去站内检索的格子数
        public var willSearch: Int
        /// 各类结论各有多少（含「会去站内检索」），按条数从多到少
        public var counts: [(reason: String, count: Int)]
        /// 整轮计数（不含本轮已发生的进展）
        public var tally: Tally

        var buckets: [String: SiteBucket]
        /// hash → 种子（队列与队列按钮要按 hash 找回是哪条）
        public var byHash: [String: LocalTorrent]

        init(torrents: [LocalTorrent] = [], siteIDs: [String] = [], missTTLDays: Int = 7,
                    pendingBySite: [String: Int] = [:],
                    pace: (interval: TimeInterval, jitter: TimeInterval, roundBudget: Int) = (8, 3, 200),
                    total: Int = 0, willSearch: Int = 0, counts: [(reason: String, count: Int)] = [],
                    tally: Tally = Tally(), buckets: [String: SiteBucket] = [:],
                    byHash: [String: LocalTorrent] = [:]) {
            self.torrents = torrents
            self.siteIDs = siteIDs
            self.missTTLDays = missTTLDays
            self.pendingBySite = pendingBySite
            self.pace = pace
            self.total = total
            self.willSearch = willSearch
            self.counts = counts
            self.tally = tally
            self.buckets = buckets
            self.byHash = byHash
        }

        /// counts 里跟着暂停名单变的两个键（暂停 ↔ 待检索来回挪的就是这两项）
        static let pausedKey = "本站已暂停"
        static let searchKey = "会去站内检索"

        /// 界面上随时能暂停/恢复某个站，而计划是按扫描那一刻的名单建的。
        /// 这里按当前名单把派生数推平一遍：待辅种 ↔ 已暂停、每站还要检索几次、
        /// counts、willSearch、分桶里的暂停标记一次全改，点一下卡片立刻见效，
        /// 不用重新扫描。名单没变就原样返回（那几万个 hash 集合只共享不复制）。
        public func applyingPaused(_ paused: Set<String>) -> CatalogPlan {
            let wants = Set(paused.filter { buckets[$0]?.unsupported != true })
            let baked = Set(buckets.filter { $0.value.pausedSite && !$0.value.unsupported }.keys)
            guard wants != baked else { return self }
            var copy = self
            var counts: [String: Int] = [:]
            for c in self.counts where c.count > 0 { counts[c.reason] = c.count }
            for id in siteIDs {
                guard let b = buckets[id], !b.unsupported else { continue }
                let now = wants.contains(id)
                if now == b.pausedSite { continue }
                // 这一站还欠着的格子 = 全站格子 − 已经有结论的
                let known = b.seeding.count + b.assisted.count + b.review.count
                    + b.rejected.count + b.missing.count + b.failed.count + b.filtered.count
                let left = max(0, torrents.count - known)
                if now {
                    copy.tally.decrease(.pending, left)
                    copy.tally.increase(.paused, left)
                    counts[Self.searchKey, default: 0] -= left
                    counts[Self.pausedKey, default: 0] += left
                    copy.pendingBySite[id] = 0
                    copy.willSearch = max(0, copy.willSearch - left)
                } else {
                    copy.tally.decrease(.paused, left)
                    copy.tally.increase(.pending, left)
                    counts[Self.pausedKey, default: 0] -= left
                    counts[Self.searchKey, default: 0] += left
                    copy.pendingBySite[id] = left
                    copy.willSearch += left
                }
                copy.buckets[id]?.pausedSite = now
            }
            copy.counts = counts.filter { $0.value > 0 }
                .sorted { $0.value > $1.value }
                .map { (reason: $0.key, count: $0.value) }
            return copy
        }

        /// 某一页的格子（一条种子 × 一个站，站点为外层，与执行顺序一致）
        public func rows(_ page: [LocalTorrent]) -> [PlanRow] {
            var out: [PlanRow] = []
            out.reserveCapacity(page.count * siteIDs.count)
            for id in siteIDs {
                guard let b = buckets[id] else { continue }
                for t in page {
                    let st = status(torrent: t, siteID: id)
                    out.append(PlanRow(siteID: id, hash: t.hash, torrentName: t.name,
                                       skipReason: skipText(st, bucket: b), planned: st))
                }
            }
            return out
        }

        /// 一格在计划阶段的结论
        public func status(torrent t: LocalTorrent, siteID: String) -> RowStatus {
            guard let b = buckets[siteID] else { return .pending }
            let h = t.hash.lowercased()
            if b.unsupported { return .unsupported }
            if b.seeding.contains(h) { return .seeding }
            if b.assisted.contains(h) { return .assisted }
            if b.review.contains(h) { return .review }
            if b.rejected.contains(h) { return .rejected }
            if b.missing.contains(h) { return .missing }
            if b.failed.contains(h) { return .failed }
            if b.filtered.contains(h) { return .filtered }
            if b.pausedSite { return .paused }
            return .pending
        }

        /// 全量计数 + 当前进展：跑过的格子按计划改记成进展那一类
        public func adjusted(live: [String: LiveRow]) -> Tally {
            var t = tally
            for (key, row) in live {
                let parts = key.split(separator: "|", maxSplits: 1)
                guard parts.count == 2,
                      let torrent = byHash[parts[1].lowercased()],
                      let now = AssistPipeline.status(live: row),
                      buckets[String(parts[0])] != nil else { continue }
                let planned = status(torrent: torrent, siteID: String(parts[0]))
                if planned == now { continue }
                t.decrease(planned)
                t.increase(now)
            }
            return t
        }

        /// 覆盖率与预计：计划计数叠加当前进展，两边看到的是同一个数
        public func coverage(live: [String: LiveRow] = [:]) -> Coverage {
            let t = adjusted(live: live)
            var c = Coverage()
            c.total = t.total
            c.resolved = t.resolved
            c.unresolved = t.unresolved
            c.searchesLeft = t.searchesLeft
            c.needsAction = t.needsAction
            c.paused = t.paused
            _ = siteProgress(live: live)      // 逐站进度与这段用的是同一次实时表
            // 执行是按站轮着来的，不是并发：逐站间隔乘以各自还要检索的次数，再累加
            let per = pace.interval + pace.jitter / 2
            var seconds: TimeInterval = 0
            var sites = 0
            for (_, n) in pendingBySite where n > 0 {
                sites += 1
                seconds += Double(n) * per
            }
            c.siteCount = sites
            c.secondsLeft = sites == 0 ? nil : seconds
            if pace.roundBudget > 0 {
                c.roundsLeft = Int((Double(c.searchesLeft) / Double(pace.roundBudget)).rounded(.up))
            }
            return c
        }

        /// 一个站的辅种进度：整站格子数、已判定、还要检索、是不是暂停/不支持检索。
        /// 「按站点」那张卡与覆盖率那句用的是同一份数。
        public struct SiteProgress: Equatable {
            public var siteID: String
            public var total: Int
            public var assisted = 0
            public var seeding = 0
            public var review = 0
            public var rejected = 0
            public var missing = 0
            public var failed = 0
            public var filtered = 0
            public var paused = 0
            public var pending = 0
            public var unsupported = false
            /// 这一站被人在界面上按了暂停
            public var pausedSite = false
            /// 不用再去站内敲门的格子
            public var resolved: Int { assisted + seeding + missing + rejected + filtered }
            /// 这一轮还会发几次检索
            public var searches: Int { pending + failed }
            public var percent: Double { total == 0 ? 1 : Double(resolved) / Double(total) }

            /// 卡片底色与排序按它走
            public var state: AssistPipeline.SiteState {
                if unsupported { return .unsupported }
                if pausedSite { return .paused }
                if failed > 0 { return .trouble }
                if review > 0 { return .review }
                return resolved >= total ? .done : .queued
            }

            /// 卡片第二行：判定到哪（一句放得下，别在卡片里被省略号砍掉）
            public var stateLine: String {
                unsupported ? "没有站内检索入口" : "已判定 \(grouped(resolved)) / \(grouped(total))"
            }

            /// 卡片第三行：接下来还有多少活儿；暂停站说清压着多少格
            public var nextLine: String {
                if unsupported { return "" }
                if pausedSite && paused > 0 { return "已暂停，压着 \(grouped(paused)) 格" }
                if searches > 0 { return "还要检索 \(grouped(searches))" }
                return resolved >= total ? "这一站已铺完" : ""
            }

            /// 卡片上那行红字；没事就是空串
            public var warnLine: String {
                [failed > 0 ? "失败 \(grouped(failed))" : "",
                 review > 0 ? "待复核 \(grouped(review))" : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
            }
        }

        /// 逐站进度（叠加本轮已发生的进展）
        public func siteProgress(live: [String: LiveRow] = [:]) -> [SiteProgress] {
            var out: [SiteProgress] = []
            for id in siteIDs {
                guard let b = buckets[id] else { continue }
                var sp = SiteProgress(siteID: id, total: torrents.count)
                if b.unsupported {
                    sp.unsupported = true
                    out.append(sp)
                    continue
                }
                sp.seeding = b.seeding.count
                sp.assisted = b.assisted.count
                sp.review = b.review.count
                sp.rejected = b.rejected.count
                sp.missing = b.missing.count
                sp.failed = b.failed.count
                sp.filtered = b.filtered.count
                let known = sp.seeding + sp.assisted + sp.review + sp.rejected
                    + sp.missing + sp.failed + sp.filtered
                let left = max(0, torrents.count - known)
                sp.pausedSite = b.pausedSite
                if b.pausedSite { sp.paused = left } else { sp.pending = left }
                out.append(sp)
            }
            var pos: [String: Int] = [:]
            for (i, sp) in out.enumerated() { pos[sp.siteID] = i }
            for (key, row) in live {
                let parts = key.split(separator: "|", maxSplits: 1)
                guard parts.count == 2, let i = pos[String(parts[0])],
                      let torrent = byHash[parts[1].lowercased()],
                      let now = AssistPipeline.status(live: row) else { continue }
                let planned = status(torrent: torrent, siteID: String(parts[0]))
                if planned == now { continue }
                Self.shift(&out[i], from: planned, to: now)
            }
            return out
        }

        /// 把一格从计划的结论挪到实际的结论：暂停、待辅种、校验中都算「还欠着」，
        /// 所以只有真有了结论才会推动那一站的百分比
        private static func shift(_ sp: inout SiteProgress, from: RowStatus, to: RowStatus) {
            add(&sp, from, -1)
            add(&sp, to, 1)
        }

        private static func add(_ sp: inout SiteProgress, _ st: RowStatus, _ n: Int) {
            switch st {
            case .assisted: sp.assisted += n
            case .seeding: sp.seeding += n
            case .review: sp.review += n
            case .rejected: sp.rejected += n
            case .missing: sp.missing += n
            case .failed: sp.failed += n
            case .filtered: sp.filtered += n
            case .paused: sp.paused += n
            case .pending, .verifying, .manual: sp.pending += n
            case .unsupported: break
            }
        }

        private func skipText(_ st: RowStatus, bucket b: SiteBucket) -> String? {
            if b.unsupported { return "该站暂不支持站内检索" }
            switch st {
            case .seeding: return "已在该站做种"
            case .assisted: return "此前已辅过"
            case .review: return "待复核（上次校验没等完）"
            case .rejected: return "人工判定不是同一种子"
            case .missing: return "站内没有（\(missTTLDays) 天内查过）"
            case .filtered: return "按本站筛选不辅（\(b.filteredReason[st.rawValue] ?? "")）"
            case .paused: return "本站已暂停（点这张站卡恢复）"
            default: return nil      // 失败的那格本轮还会再试，不算「跳过」
            }
        }
    }

    /// 建全量目录计划
    public func planCatalog(_ torrents: [LocalTorrent], siteIDs: [String]? = nil) -> CatalogPlan {
        let list = Self.catalog(torrents)
        guard let cfg = config.assist else { return CatalogPlan(torrents: list) }
        var ids: [String] = []
        var seen = Set<String>()
        for id in (siteIDs ?? cfg.siteIDs) where config.site(id) != nil && !seen.contains(id) {
            seen.insert(id)
            ids.append(id)
        }
        let hashSet = Set(list.map { $0.hash.lowercased() })
        // tracker host → 站点：一遍种子就能给各站分出「已在该站做种」
        var hostsToSites: [String: [String]] = [:]
        for id in ids {
            if let s = config.site(id), let host = AssistConfig.announceHost(of: s) {
                hostsToSites[host.lowercased(), default: []].append(id)
            }
        }
        var seeding: [String: Set<String>] = [:]
        for t in list {
            for host in t.trackerHosts {
                for id in hostsToSites[host.lowercased()] ?? [] {
                    seeding[id, default: []].insert(t.hash.lowercased())
                }
            }
        }
        let missTTL = Double(cfg.missTTLDays) * 86_400
        var buckets: [String: SiteBucket] = [:]
        var counts: [String: Int] = [:]
        var pendingBySite: [String: Int] = [:]
        var tally = Tally()
        for id in ids {
            guard let site = config.site(id) else { continue }
            var b = SiteBucket()
            b.seeding = seeding[id] ?? []
            if !adapterFactory(SiteRegistry.effectiveSite(site), client).canPrecheckDuplicate {
                b.unsupported = true
            } else {
                // 优先级与 preSkip 一致：已做种 > 已辅过 > 站内没有 > 上次失败
                b.assisted = state.assistedHashes(site: id).intersection(hashSet).subtracting(b.seeding)
                b.review = state.assistReviewHashes(site: id)
                    .intersection(hashSet).subtracting(b.seeding).subtracting(b.assisted)
                b.rejected = state.assistRejectHashes(site: id)
                    .intersection(hashSet).subtracting(b.seeding).subtracting(b.assisted)
                    .subtracting(b.review)
                if let f = cfg.assistFilter(id) {
                    for t in list {
                        let h = t.hash.lowercased()
                        if let why = f.reject(t.name, sizeGB: Double(t.totalSize) / 1_073_741_824) {
                            b.filtered.insert(h)
                            // 一格里放一条原因就够看：同一类原因合并成一句
                            b.filteredReason[RowStatus.filtered.rawValue] = why
                        }
                    }
                    b.filtered.subtracting(b.seeding).subtracting(b.assisted)
                }
                b.missing = state.assistMissHashes(site: id, ttlSeconds: missTTL)
                    .intersection(hashSet).subtracting(b.seeding).subtracting(b.assisted)
                    .subtracting(b.review).subtracting(b.rejected).subtracting(b.filtered)
                b.failed = state.assistFailHashes(site: id)
                    .intersection(hashSet).subtracting(b.seeding)
                    .subtracting(b.assisted).subtracting(b.missing)
                    .subtracting(b.review).subtracting(b.rejected).subtracting(b.filtered)
            }
            b.pausedSite = !b.unsupported && cfg.isPaused(id)
            buckets[id] = b
            if b.unsupported {
                counts["该站暂不支持站内检索", default: 0] += list.count
                tally.increase(.unsupported, list.count)
                continue
            }
            let pending = list.count - b.seeding.count - b.assisted.count
                - b.review.count - b.rejected.count - b.missing.count - b.failed.count
                - b.filtered.count
            if b.pausedSite {
                // 暂停：格子还欠着，但这一轮不算要检索的量
                tally.increase(.paused, max(0, pending))
                counts[CatalogPlan.pausedKey, default: 0] += max(0, pending)
                pendingBySite[id] = 0
                continue
            }
            pendingBySite[id] = max(0, pending)
            tally.increase(.seeding, b.seeding.count)
            tally.increase(.assisted, b.assisted.count)
            tally.increase(.review, b.review.count)
            tally.increase(.rejected, b.rejected.count)
            tally.increase(.missing, b.missing.count)
            tally.increase(.failed, b.failed.count)
            tally.increase(.filtered, b.filtered.count)
            tally.increase(.pending, max(0, pending))
            counts["已在该站做种", default: 0] += b.seeding.count
            counts["此前已辅过", default: 0] += b.assisted.count
            counts["待复核", default: 0] += b.review.count
            counts["人工已否决", default: 0] += b.rejected.count
            counts["站内没有（\(cfg.missTTLDays) 天内查过）", default: 0] += b.missing.count
            counts["上次检索失败", default: 0] += b.failed.count
            counts["按本站筛选不辅", default: 0] += b.filtered.count
            counts[CatalogPlan.searchKey, default: 0] += max(0, pending)
        }
        return CatalogPlan(torrents: list, siteIDs: ids, missTTLDays: cfg.missTTLDays,
                           pendingBySite: pendingBySite,
                           pace: (cfg.perSiteIntervalSec, cfg.jitterSec, cfg.roundBudget),
                           total: list.count * ids.count,
                           willSearch: counts[CatalogPlan.searchKey, default: 0],
                           counts: counts.sorted { $0.value > $1.value }
                               .map { (reason: $0.key, count: $0.value) },
                           tally: tally, buckets: buckets,
                           byHash: Dictionary(list.map { ($0.hash.lowercased(), $0) },
                                             uniquingKeysWith: { a, _ in a }))
    }

    public func plan(torrents: [LocalTorrent], siteIDs: [String]? = nil) -> [PlanRow] {
        guard let cfg = config.assist else { return [] }
        var rows: [PlanRow] = []
        for id in (siteIDs ?? cfg.siteIDs) {
            guard let site = config.site(id) else { continue }
            // 建适配器不发请求，可以拿它先问一句「这站有没有检索入口」
            let adapter = adapterFactory(SiteRegistry.effectiveSite(site), client)
            for t in torrents {
                var reason: String?
                if !adapter.canPrecheckDuplicate {
                    reason = "该站暂不支持站内检索"
                } else {
                    reason = preSkip(t, site: site, cfg: cfg)?.why
                }
                rows.append(PlanRow(siteID: site.id, hash: t.hash, torrentName: t.name,
                                    skipReason: reason, planned: Self.status(skipReason: reason)))
            }
        }
        return rows
    }

    /// 一条种子 × 一个站
    private func attempt(_ t: LocalTorrent, site: SiteConfig, adapter: any SiteAdapter,
                         cfg: AssistConfig, opts: Options) -> AssistOutcome {
        func out(_ level: AssistLevel, _ msg: String, url: String? = nil, done: Bool = false,
                 failed: Bool = false) -> AssistOutcome {
            AssistOutcome(siteID: site.id, torrentName: t.name, level: level,
                          detailURL: url, done: done, message: msg, failed: failed)
        }
        // 人工点了「采纳」：就算在负缓存期内、或此前辅过，也照着人的判断再走一遍
        let forced = opts.forceKeys.contains("\(site.id)|\(t.hash)")
        var relaxedHit = false
        // 先筛掉不该花请求的组合：白扔请求既慢又给站点添负载
        if !forced, let pre = preSkip(t, site: site, cfg: cfg) {
            return out(.skip(pre.why), pre.detail)
        }
        if !throttle.acquire(site.id) {
            return out(.skip("本轮检索预算用完"), "站点请求预算已用满，下次接着跑")
        }
        let query = ReleaseInfo(siteID: site.id, detailURL: site.url, name: t.name)
        // 「检索报错」与「站内没有」是两回事：cookie 失效、站点 500 这类不能记成
        // 「站内没有」，否则整站的格子被钉在负缓存里 7 天不再问
        var found: String?
        var missClean = true
        do {
            found = try adapter.searchExists(query)
        } catch {
            missClean = false
            return out(.skip("站内检索没问成"), "站内检索失败：\(error.localizedDescription)",
                       failed: true)
        }
        // 严格那档没命中就换宽松查询词再问一次（多花一次请求，只发生在没命中时）
        if found == nil, missClean, !stopRequested, cfg.relaxedRetrySearch,
           throttle.acquire(site.id) {
            found = try? adapter.searchExists(query, relaxed: true)
            relaxedHit = found != nil
        }
        guard let detail = found else {
            state.markAssistMiss(site: site.id, hash: t.hash)
            return out(.skip("站内无此种子"), "站内检索没找到同名种子")
        }
        if relaxedHit { relaxedHitCount += 1 }
        guard throttle.acquire(site.id),
              let info = try? adapter.fetchDetail(detailURL: detail),
              throttle.acquire(site.id),
              let (data, _) = try? adapter.downloadTorrentFile(info) else {
            return out(.skip("站点那条读不下来"), "详情或 .torrent 下载失败（cookie 可能失效）",
                       failed: true)
        }
        let foundNote = relaxedHit ? "（换宽松查询词才找到，站内标题与本地不同）" : ""
                guard let localFiles = try? downloader.torrentFiles(hash: t.hash), !localFiles.isEmpty else {
            return out(.nameOnly(info.name), "读不到本地种子的文件清单，没法逐文件比对")
        }
        let local = TorrentFingerprint(root: TorrentFingerprint.commonRoot(localFiles),
                                       files: localFiles)
        let (level, why) = AssistMatcher.judge(localHashes: t.allHashes, local: local,
                                              siteTorrentData: data, siteName: info.name)
        // 目录结构对不上时加进去会重下一整份：默认拦下来，人工采纳过就只当一句提醒
        let layoutNote: String? = {
            switch AssistMatcher.layout(localPaths: Set(localFiles.map { $0.path }),
                                        sitePaths: Set(Bencode.fileList(data)?.map { $0.path } ?? [])) {
            case .same: return nil
            case .rootDiffers: return "站点种子的内层目录名与本地不同"
            case .differs: return "站点种子的目录结构与本地不同"
            }
        }()

        /// 推下载器；原本会被拦下的两种情况，人工采纳过也走这里
        func admit(_ lvl: AssistLevel, _ reason: String) -> AssistOutcome {
            if opts.dryRun {
                return out(lvl, "可辅（dry-run 未推送）：\(reason)", url: detail)
            }
            var note = forced ? "已按人工采纳" : ""
            if forced, let layoutNote { note += "（\(layoutNote)，可能会重下一部分）" }
            if relaxedHit { note = note.isEmpty ? "换宽松查询词才找到" : note + "；换宽松查询词才找到" }
            return push(t, site: site, cfg: cfg, data: data, level: lvl, why: reason, detail: detail,
                        opts: opts, prefix: note.isEmpty ? "" : note + "：")
        }

        switch level {
        case .nameOnly:
            if forced { return admit(level, why) }
            return out(level, "名字对得上但文件清单对不上：\(why)\(foundNote)")
        case .skip(let why):
            // 判定明说不是同一种子：不因一句「采纳」就硬加
            return out(.skip(why), why)
        case .sameHash, .sameFiles:
            if case .sameFiles = level, !cfg.autoAcceptSameFiles, !forced {
                return out(.nameOnly(info.name), "站点重新打包过（hash 不同），按设置不自动采纳")
            }
            if !forced, let layoutNote {
                return out(level, "文件一致，但\(layoutNote)，直接加会重下一整份，先不动下载器"
                           + foundNote, url: detail)
            }
            return admit(level, why)
        }
    }

    /// 加进下载器 → 等校验 → 满 100% 才启动
    private func push(_ t: LocalTorrent, site: SiteConfig, cfg: AssistConfig, data: Data,
                      level: AssistLevel, why: String, detail: String, opts: Options,
                      prefix: String = "") -> AssistOutcome {
        func out(_ msg: String, url: String? = detail, done: Bool = false,
                 phaseLevel: AssistLevel? = nil) -> AssistOutcome {
            AssistOutcome(siteID: site.id, torrentName: t.name, level: phaseLevel ?? level,
                          detailURL: url, done: done, message: msg)
        }
        // 限速按辅种这台自己那份逐站表算：发种那台的逐站限速管不着这台
        let limit = config.effectiveUpLimit(siteID: site.id, downloader: config.assistDownloader)
        do {
            _ = try downloader.addTorrent(data: data, filename: (Bencode.infoName(data) ?? t.name) + ".torrent",
                                          savePath: t.savePath, category: t.category,
                                          skipChecking: false, upLimit: limit, paused: true)
        } catch {
            return AssistOutcome(siteID: site.id, torrentName: t.name, level: level,
                                 detailURL: detail,
                                 message: "加进下载器失败：\(error.localizedDescription)",
                                 failed: true)
        }
        // 记进「已辅过」表的级别：人工采纳的那种单标出来，日后好回看是怎么过的
        func levelTag() -> String {
            if case .sameHash = level { return "sameHash" }
            if case .sameFiles = level { return "sameFiles" }
            return "manual"
        }
        let siteHash = Bencode.infoHash(data)?.lowercased() ?? t.hash
        var waited: TimeInterval = 0
        let poll = TimeInterval(max(1, cfg.verifyPollSec))
        while waited < TimeInterval(cfg.verifyWaitSec) {
            if let p = try? downloader.torrentProgress(hash: siteHash) {
                if p.progress >= 0.999 {
                    try? downloader.setPaused(hashes: [siteHash], paused: false)
                    state.markAssisted(site: site.id, hash: t.hash, url: detail, level: levelTag())
                    state.note("assist[\(site.id)] OK \(t.name) \(levelTag())")
                    return AssistOutcome(siteID: site.id, torrentName: t.name, level: level,
                                         detailURL: detail, done: true,
                                         message: prefix + "校验到 100%，已启动（\(why)）")
                }
                // 校验跑完仍不满：文件对不上，留着它会自己重下一整份
                if waited > 0, !isChecking(p.state) {
                    if cfg.removeOnVerifyFail {
                        try? downloader.removeTorrent(hash: siteHash, keepFiles: true)
                        return AssistOutcome(siteID: site.id, torrentName: t.name, level: level,
                                             detailURL: detail,
                                             message: "校验后只到 \(Int(p.progress * 100))%，已删掉刚加的种子"
                                                    + "（文件保留）：内层路径与本地对不上",
                                             failed: true)
                    }
                    return AssistOutcome(siteID: site.id, torrentName: t.name, level: level,
                                         detailURL: detail,
                                         message: "校验后只到 \(Int(p.progress * 100))%，种子保持暂停："
                                                + "文件对不上，别让它开始重下",
                                         failed: true)
                }
            }
            opts.sleep(poll)
            waited += poll
        }
        // 落一张「待复核」：不落盘的话这一格重启就人间蒸发，那条暂停的种子也没人收尾
        state.markAssistReview(site: site.id, hash: t.hash, url: detail, siteHash: siteHash,
                               level: levelTag(), why: why)
        state.note("assist[\(site.id)] REVIEW \(t.name) \(levelTag())")
        return AssistOutcome(siteID: site.id, torrentName: t.name, level: level, detailURL: detail,
                             message: "校验还没跑完（等了 \(cfg.verifyWaitSec) 秒），"
                                    + "种子先留在下载器里暂停着，点「回查校验」看结果",
                             review: true)
    }

    /// 阶段名（桥接层与界面按这个名字比对，别随意改）
    public static func phaseName(_ p: Status.Phase) -> String {
        switch p {
        case .working: return "working"
        case .verifying: return "verifying"
        case .review: return "review"
        case .done: return "done"
        case .failed: return "failed"
        case .skipped: return "skipped"
        }
    }

    public static func phase(_ name: String) -> Status.Phase? {
        switch name {
        case "working": return .working
        case "verifying": return .verifying
        case "review": return .review
        case "done": return .done
        case "failed": return .failed
        case "skipped": return .skipped
        default: return nil
        }
    }

    private func isChecking(_ state: String) -> Bool {
        ["checking", "checkingFiles", "checkingResumeData", "allocating", "metadownload"].contains(state)
    }
}
