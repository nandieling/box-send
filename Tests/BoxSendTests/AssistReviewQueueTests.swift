import XCTest
@testable import BoxSendKit

/// 这一轮的四件事：待复核要落盘并能回查、否决要真的挡住检索、
/// 覆盖率要给出「还剩多少、还要多久」、待处理队列要能一条一行点掉。
final class AssistReviewQueueTests: XCTestCase {

    // MARK: 夹具

    private final class RSite: SiteAdapter {
        let site: SiteConfig
        let client: HTTPClient
        var override: SiteOverride? { site.overrides }
        var torrentData: Data?
        var searchCalls = 0
        var canPrecheckDuplicate = true

        init(site: SiteConfig, client: HTTPClient, torrentData: Data?) {
            self.site = site; self.client = client; self.torrentData = torrentData
        }
        func fetchTorrentList() throws -> [ReleaseInfo] { [] }
        func fetchDetail(detailURL: String) throws -> ReleaseInfo {
            ReleaseInfo(siteID: site.id, detailURL: detailURL,
                        name: Bencode.infoName(torrentData ?? Data()) ?? "站内那条",
                        torrentURL: site.url + "download.php?id=1")
        }
        func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String) {
            guard let d = torrentData else { throw BoxSendError.badInput("没有种子文件") }
            return (d, "site.torrent")
        }
        func searchExists(_ info: ReleaseInfo) throws -> String? {
            searchCalls += 1
            return torrentData == nil ? nil : site.url + "details.php?id=9"
        }
        func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
            UploadOutcome(success: false, message: "辅种不上传", detailURL: nil)
        }
    }

    /// 校验进度可脚本化的下载器：recheck 与 push 都靠它回话
    private final class RDL: Downloader {
        var torrents: [LocalTorrent] = []
        var files: [(path: String, size: Int64)] = []
        var progressScript: [(Double, String)] = [(0.5, "checkingFiles")]
        private var reads = 0
        private(set) var resumed: [String] = []
        private(set) var removed: [(hash: String, keepFiles: Bool)] = []

        func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                        skipChecking: Bool, upLimit: Int64) throws -> AddTorrentResult {
            try addTorrent(data: data, filename: filename, savePath: savePath, category: category,
                           skipChecking: skipChecking, upLimit: upLimit, paused: false)
        }
        func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                        skipChecking: Bool, upLimit: Int64, paused: Bool) throws -> AddTorrentResult {
            AddTorrentResult(id: Bencode.infoHash(data) ?? "hash")
        }
        func testConnection() throws -> String { "fake" }
        func listTorrents() throws -> [LocalTorrent] { torrents }
        func torrentFiles(hash: String) throws -> [(path: String, size: Int64)] { files }
        func setPaused(hashes: [String], paused: Bool) throws {
            if !paused { resumed.append(contentsOf: hashes) }
        }
        func removeTorrent(hash: String, keepFiles: Bool) throws { removed.append((hash, keepFiles)) }
        func torrentProgress(hash: String) throws -> (progress: Double, state: String)? {
            let i = min(reads, progressScript.count - 1)
            reads += 1
            return progressScript[i]
        }
    }

    private func site(_ id: String) -> SiteConfig {
        SiteConfig(id: id, name: id, url: "https://\(id).invalid/",
                   framework: .nexusPHP, enabled: true)
    }

    private func site(_ id: String, host: String) -> SiteConfig {
        SiteConfig(id: id, name: id, url: "https://\(host)/", framework: .nexusPHP, enabled: true)
    }

    private func torrent(root: String, source: String) -> Data {
        let info: [String: Any] = ["name": root, "piece length": 262144, "pieces": "0000",
                                   "source": source,
                                   "files": [["length": 100, "path": ["a.mkv"] as [Any]] as [String: Any]]]
        return BEnc.enc(["info": info, "announce": "https://t/announce"])
    }

    private func local(_ hash: String, host: String = "elsewhere.invalid") -> LocalTorrent {
        // 名字带上 hash：目录会按「名字 + 体积」去重，同名同体积会被并成一条
        LocalTorrent(hash: hash, name: "Movie.\(hash).1080p", savePath: "/dl", totalSize: 300,
                     progress: 1, trackerHosts: [host])
    }

    /// 节奏清零：单测不该真等逐站间隔（否则一条用例要跑十几秒）
    private func quickCfg(_ ids: [String] = ["target"]) -> AssistConfig {
        AssistConfig(siteIDs: ids, perSiteIntervalSec: 0, jitterSec: 0, roundBudget: 50,
                     verifyWaitSec: 2, verifyPollSec: 1)
    }

    private func pipe(_ cfg: AssistConfig, _ dl: RDL, _ s: SiteConfig, _ data: Data?,
                      dir: String) -> (AssistPipeline, RSite, StateStore) {
        var app = AppConfig.template()
        app.sourceSites = [s]
        app.assist = cfg
        let state = StateStore(dataDir: dir)
        let p = AssistPipeline(config: app, cookies: CookieStore(), state: state, downloader: dl)
        let fake = RSite(site: s, client: HTTPClient(cookies: CookieStore(), userAgent: "t"),
                         torrentData: data)
        p.adapterFactory = { _, _ in fake }
        return (p, fake, state)
    }

    /// 跑到校验超时：种子已进下载器，但进度一直不满
    private func runUntilReview(_ s: String, dir: String? = nil) throws
        -> (AssistPipeline, RSite, RDL, StateStore, String) {
        let data = torrent(root: "Movie.2020", source: "Target")
        let dl = RDL()
        dl.files = [("Movie.2020/a.mkv", 100)]
        dl.progressScript = [(0.5, "checkingFiles")]      // 永远在校验 → 等超时
        let dir = dir ?? "/tmp/boxsend-rev-\(UUID().uuidString)"
        let (p, fake, state) = pipe(quickCfg(), dl, site(s), data, dir: dir)
        var o = AssistPipeline.Options(); o.sleep = { _ in }
        let report = p.run(torrents: [local(Bencode.infoHash(data)!)], opts: o)
        return (p, fake, dl, state, report.reviewCount == 1 ? Bencode.infoHash(data)! : "")
    }

    // MARK: 待复核

    /// 等不到校验结果不该当作「什么都没发生」：要落一张待复核表
    func testVerifyTimeoutRecordsReview() throws {
        let (_, _, _, state, hash) = try runUntilReview("target")
        XCTAssertEqual(hash.nonEmpty, true, "这一轮应判定为待复核")
        let recs = state.assistReviewRecs(site: "target")
        XCTAssertEqual(recs.count, 1)
        XCTAssertFalse(recs[hash]?.url.isEmpty ?? true, "站内详情页要留着，回查时才找得着")
        XCTAssertFalse(state.isAssisted(site: "target", hash: hash), "没校验到 100% 不算辅成")
    }

    /// 待复核要重启还在，并且下一轮不再去站内重搜（会加出第二条）
    func testReviewSurvivesRestartAndBlocksResearch() throws {
        let dir = "/tmp/boxsend-rev2-\(UUID().uuidString)"
        let (_, fake, _, _, hash) = try runUntilReview("target", dir: dir)
        XCTAssertEqual(hash.nonEmpty, true)
        fake.searchCalls = 0

        let reopened = StateStore(dataDir: dir)
        XCTAssertEqual(reopened.assistReviewRecs(site: "target").count, 1, "换一份状态表读同一份文件")

        var app = AppConfig.template()
        app.sourceSites = [site("target")]
        app.assist = quickCfg()
        let again = AssistPipeline(config: app, cookies: CookieStore(), state: reopened,
                                   downloader: RDL())
        again.adapterFactory = { s, c in RSite(site: s, client: c, torrentData: nil) }
        var o = AssistPipeline.Options(); o.sleep = { _ in }
        let report = again.run(torrents: [local(hash)], opts: o)
        XCTAssertEqual(fake.searchCalls, 0, "待复核的格子本轮不该再检索")
        XCTAssertEqual(report.skippedCount, 1)

        let plan = again.planCatalog([local(hash)])
        XCTAssertEqual(plan.status(torrent: local(hash), siteID: "target"), .review)
    }

    // MARK: 回查校验

    /// 校验已经跑满：回查就该补上「已辅种」并启动
    func testRecheckVerifiesFinishedTorrent() throws {
        let (p, _, dl, state, hash) = try runUntilReview("target")
        let rdl = dl
        rdl.progressScript = [(1.0, "stalledUP")]
        let report = p.recheckReviews(names: [hash: "Movie.2020.1080p"])
        XCTAssertEqual(report.verified, 1)
        XCTAssertEqual(report.dropped, 0)
        XCTAssertTrue(state.isAssisted(site: "target", hash: hash))
        XCTAssertTrue(state.assistReviewRecs(site: "target").isEmpty, "收尾完就该从待复核表里摘掉")
        XCTAssertEqual(rdl.resumed.count, 1, "复核到 100% 要启动，别让它一直暂停")
    }

    /// 校验早停了却不满意：回查要回滚并把原因写进失败记录
    func testRecheckRollsBackStalledTorrent() throws {
        let (p, _, dl, state, hash) = try runUntilReview("target")
        dl.progressScript = [(0.4, "stalledDL")]
        let report = p.recheckReviews(names: [hash: "Movie"])
        XCTAssertEqual(report.dropped, 1)
        XCTAssertEqual(dl.removed.count, 1, "按设置删掉刚加的那条，文件留着")
        XCTAssertFalse(state.isAssisted(site: "target", hash: hash))
        let why = state.assistQueueEntries().first(where: { $0.kind == .failed })?.why ?? ""
        XCTAssertTrue(why.contains("40%"), "失败原因要说清只到百分之几，实际：\(why)")
    }

    /// 只回查点名那一条，别的保持待复核
    func testRecheckHonoursKeyFilter() throws {
        let dir = "/tmp/boxsend-rev3-\(UUID().uuidString)"
        let state = StateStore(dataDir: dir)
        state.markAssistReview(site: "target", hash: "h1", url: "u1", siteHash: "h1",
                               level: "sameHash", why: "w")
        state.markAssistReview(site: "target", hash: "h2", url: "u2", siteHash: "h2",
                               level: "sameHash", why: "w")
        var app = AppConfig.template()
        app.sourceSites = [site("target")]
        app.assist = quickCfg()
        let dl = RDL()
        dl.progressScript = [(1.0, "stalledUP")]
        let p = AssistPipeline(config: app, cookies: CookieStore(), state: state, downloader: dl)
        let report = p.recheckReviews(keys: ["target|h2"])
        XCTAssertEqual(report.checked, 1)
        XCTAssertEqual(state.assistReviewRecs(site: "target").keys.sorted(), ["h1"],
                       "没点名的那条不该被顺手收尾")
    }

    // MARK: 人工否决

    /// 否决过的组合：计划里标「已否决」，跑起来一次请求都不发；撤销后恢复待检索
    func testRejectBlocksSearchAndUndoRestores() throws {
        let dir = "/tmp/boxsend-rej-\(UUID().uuidString)"
        let data = torrent(root: "Movie.2020", source: "Target")
        let (p, fake, state) = pipe(quickCfg(), RDL(), site("target"), data, dir: dir)
        p.setRejected("target|aa", rejected: true)
        XCTAssertTrue(state.isAssistRejected(site: "target", hash: "aa"))

        XCTAssertEqual(p.planCatalog([local("aa")]).status(torrent: local("aa"), siteID: "target"),
                       .rejected)
        var o = AssistPipeline.Options(); o.sleep = { _ in }
        _ = p.run(torrents: [local("aa")], opts: o)
        XCTAssertEqual(fake.searchCalls, 0, "否决过还去检索，纯属白跑")

        p.setRejected("target|aa", rejected: false)
        XCTAssertFalse(state.isAssistRejected(site: "target", hash: "aa"))
        XCTAssertEqual(p.planCatalog([local("aa")]).status(torrent: local("aa"), siteID: "target"),
                       .pending)
    }

    // MARK: 覆盖率

    /// 覆盖率：已判定 = 已辅 + 已做种 + 站内没有 + 已否决；预计按逐站间隔串行累加
    func testCoverageMath() throws {
        let dir = "/tmp/boxsend-cov-\(UUID().uuidString)"
        let state = StateStore(dataDir: dir)
        var app = AppConfig.template()
        app.sourceSites = [site("s1", host: "s1.invalid"), site("s2", host: "s2.invalid")]
        app.assist = AssistConfig(siteIDs: ["s1", "s2"], perSiteIntervalSec: 8, jitterSec: 4,
                                 roundBudget: 10, missTTLDays: 7)
        let p = AssistPipeline(config: app, cookies: CookieStore(), state: state,
                               downloader: RDL())
        let list = (1...4).map { local("h\($0)") }
        state.markAssisted(site: "s1", hash: "h1", url: "u", level: "sameHash")
        state.markAssistMiss(site: "s1", hash: "h2")
        let plan = p.planCatalog(list)
        let cov = plan.coverage()
        XCTAssertEqual(cov.total, 8, "4 条种子 × 2 个站")
        XCTAssertEqual(cov.resolved, 2, "s1 上已辅过 + 站内没有")
        XCTAssertEqual(cov.searchesLeft, 6)
        XCTAssertEqual(cov.percent, 0.25, accuracy: 0.0001)
        XCTAssertEqual(cov.siteCount, 2)
        XCTAssertEqual(cov.secondsLeft ?? 0, 60, accuracy: 1,
                       "6 次检索 ×（8 秒间隔 + 2 秒抖动均值）")
        XCTAssertEqual(cov.roundsLeft, 1, "单轮预算 10 次，6 次一轮就够")
        XCTAssertTrue(cov.line.contains("25.0%"), cov.line)
    }

    /// 待复核与待确认都算「等人处理」，覆盖率不该把它们算成已判定
    func testReviewCountsAsNeedsAction() throws {
        let state = StateStore(dataDir: "/tmp/boxsend-cov2-\(UUID().uuidString)")
        state.markAssistReview(site: "s1", hash: "h1", url: "u", siteHash: "h1",
                               level: "sameHash", why: "校验没跑完")
        var app = AppConfig.template()
        app.sourceSites = [site("s1", host: "s1.invalid")]
        app.assist = AssistConfig(siteIDs: ["s1"], perSiteIntervalSec: 0, jitterSec: 0)
        let p = AssistPipeline(config: app, cookies: CookieStore(), state: state, downloader: RDL())
        let cov = p.planCatalog([local("h1")]).coverage()
        XCTAssertEqual(cov.resolved, 0)
        XCTAssertEqual(cov.needsAction, 1)
        XCTAssertTrue(cov.line.contains("等人处理 1 条"), cov.line)
    }

    // MARK: 待处理队列

    /// 队列：待确认排最前，下载器里已经没掉的条目不收，原因原样带出来
    func testQueueOrdersAndFilters() throws {
        var app = AppConfig.template()
        app.sourceSites = [site("s1", host: "s1.invalid")]
        let entries = [
            AssistQueueEntry(siteID: "s1", hash: "h1", kind: .failed, why: "详情读不下来", time: 100),
            AssistQueueEntry(siteID: "s1", hash: "h2", kind: .review, why: "校验没跑完", time: 200,
                             url: "https://s1.invalid/details.php?id=2"),
            AssistQueueEntry(siteID: "s1", hash: "h3", kind: .rejected, why: "", time: 300),
            AssistQueueEntry(siteID: "s1", hash: "gone", kind: .failed, why: "目录里已经没这条", time: 400),
        ]
        let torrents = ["h1": local("h1"), "h2": local("h2"), "h3": local("h3"),
                          "h9": local("h9")]
        let live = ["s1|h9": AssistPipeline.LiveRow(phase: .skipped, text: "待人工确认：文件名一样")]
        let items = AssistPipeline.queueItems(entries, live: live,
                                             siteNames: { _ in "站一" }, torrents: torrents,
                                             timeText: { _ in "时间" })
        XCTAssertEqual(items.map(\.hash), ["h9", "h2", "h1", "h3"],
                       "待确认 > 待复核 > 失败 > 已否决；下载器里没掉的条目才收")
        XCTAssertEqual(items[0].status, .manual)
        XCTAssertEqual(items[1].url, "https://s1.invalid/details.php?id=2")
        XCTAssertEqual(items[2].why, "详情读不下来")
        XCTAssertTrue(items[0].canAdopt && items[1].canRecheck && items[2].canRetry)
        XCTAssertTrue(items[3].canUndo && !items[3].canReject)
    }

    /// 队列有条数上限：几万条失败时界面不该整个摊开
    func testQueueRespectsLimit() {
        let entries = (0...400).map {
            AssistQueueEntry(siteID: "s1", hash: "h\($0)", kind: .failed, why: "", time: Double($0))
        }
        let torrents = Dictionary(uniqueKeysWithValues: entries.map { ($0.hash, local($0.hash)) })
        let items = AssistPipeline.queueItems(entries, siteNames: { _ in "s" }, torrents: torrents,
                                             timeText: { _ in "" }, limit: 50)
        XCTAssertEqual(items.count, 50)
        XCTAssertEqual(items.first?.hash, "h400", "按时间倒序，最新的排前面")
    }

    /// 旧版 state.json 的失败表只存一个时间戳：要读得动，别整张表丢
    func testLegacyFailTableStillReads() throws {
        let dir = "/tmp/boxsend-legacy-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let json = """
        {"assistFail":{"s1":{"h1":1234.5}},"assistMiss":{"s1":{"h2":1234.5}}}
        """
        try json.write(toFile: dir + "/state.json", atomically: true, encoding: .utf8)
        let state = StateStore(dataDir: dir)
        let entries = state.assistQueueEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.kind, .failed)
        XCTAssertEqual(entries.first?.why, "", "旧记录没原因，留空而不是崩")
        XCTAssertNotNil(state.assistMissedAt(site: "s1", hash: "h2", ttlSeconds: 1e12),
                        "同版本的负缓存表照旧能读")
    }
}

private extension String {
    var nonEmpty: Bool { !isEmpty }
}

/// 逐站筛选：整库 × 全站的分母靠这个砍，规则在核心库里判，两端只填表
final class AssistSiteFilterTests: XCTestCase {
    private func site(_ id: String) -> SiteConfig {
        SiteConfig(id: id, name: id, url: "https://\(id).invalid/",
                   framework: .nexusPHP, enabled: true)
    }

    private func torrent(_ hash: String, _ name: String, gb: Double) -> LocalTorrent {
        LocalTorrent(hash: hash, name: name, savePath: "/dl",
                     totalSize: Int64(gb * 1_073_741_824), progress: 1,
                     trackerHosts: ["elsewhere.invalid"])
    }

    private func cfg(_ filters: [String: AssistConfig.SiteFilter]) -> AppConfig {
        var app = AppConfig.template()
        app.sourceSites = [site("s1"), site("s2")]
        app.assist = AssistConfig(siteIDs: ["s1", "s2"], perSiteIntervalSec: 0, jitterSec: 0,
                                  siteFilters: filters)
        return app
    }

    /// 关键词不分大小写；排除与体积上下限都算原因
    func testFilterJudgement() {
        let movie = AssistConfig.SiteFilter(include: ["BluRay", "1080p"], exclude: ["剧集"])
        XCTAssertNil(movie.reject("Movie.2020.1080p.BluRay", sizeGB: 20))
        XCTAssertEqual(movie.reject("Movie.2020.x264.WEB-DL", sizeGB: 20), "没有本站要的关键词")
        XCTAssertEqual(movie.reject("剧集.2020.1080p.BluRay", sizeGB: 20), "命中本站排除词「剧集」")
        let cap = AssistConfig.SiteFilter(minSizeGB: 0, maxSizeGB: 30)
        XCTAssertNil(cap.reject("A", sizeGB: 29.9))
        XCTAssertEqual(cap.reject("A", sizeGB: 31)?.contains("上限"), true)
        XCTAssertTrue(AssistConfig.SiteFilter().isEmpty, "什么都没填 = 这个站不设限")
        XCTAssertNil(AssistConfig.SiteFilter(exclude: [" "]).reject("任意名字", sizeGB: 1),
                     "只有空白的关键词不算设过规则")
    }

    /// 计划里那一格标「本站不辅」，且算已判定（不用再去敲门）
    func testPlanMarksFilteredCells() throws {
        let app = cfg(["s1": AssistConfig.SiteFilter(include: ["电影"])])
        let p = AssistPipeline(config: app, cookies: CookieStore(),
                              state: StateStore(dataDir: "/tmp/boxsend-f-\(UUID().uuidString)"),
                              downloader: RDLStub())
        let list = [torrent("h1", "电影 A", gb: 10), torrent("h2", "剧集 B", gb: 10)]
        let plan = p.planCatalog(list)
        XCTAssertEqual(plan.status(torrent: list[0], siteID: "s1"), .pending)
        XCTAssertEqual(plan.status(torrent: list[1], siteID: "s1"), .filtered)
        XCTAssertEqual(plan.status(torrent: list[1], siteID: "s2"), .pending, "另一个站没设规则")
        let cov = plan.coverage()
        XCTAssertEqual(cov.total, 4)
        XCTAssertEqual(cov.resolved, 1, "本站不辅的那格算已判定")
        XCTAssertEqual(cov.searchesLeft, 3, "分母真的少了这一格")
        XCTAssertEqual(plan.rows(list).first { $0.hash == "h2" && $0.siteID == "s1" }?
                       .skipReason?.contains("筛选不辅"), true)
    }

    /// 跑起来一次请求都不该发：白检索既慢又给站点添负载
    func testFilteredCellSendsNoRequest() throws {
        let data = BEnc.enc(["info": ["name": "X", "piece length": 262144, "pieces": "0000",
                                     "files": [["length": 1, "path": ["a"] as [Any]] as [String: Any]]]])
        var app = cfg(["s1": AssistConfig.SiteFilter(exclude: ["剧集"])])
        app.assist?.siteIDs = ["s1"]   // 只留这一个站，别把没设规则的站的检索也算进来
        let state = StateStore(dataDir: "/tmp/boxsend-f2-\(UUID().uuidString)")
        let p = AssistPipeline(config: app, cookies: CookieStore(), state: state,
                               downloader: RDLStub())
        let fake = FilterProbeSite(site: site("s1"),
                                   client: HTTPClient(cookies: CookieStore(), userAgent: "t"),
                                   data: data)
        p.adapterFactory = { _, _ in fake }
        var o = AssistPipeline.Options(); o.sleep = { _ in }
        let report = p.run(torrents: [torrent("h2", "剧集 B", gb: 10)], opts: o)
        XCTAssertEqual(fake.searches, 0)
        XCTAssertEqual(report.skippedCount, 1)
    }
}

/// 只报「检索发了几次」的假站点 / 空下载器
private final class FilterProbeSite: SiteAdapter {
    let site: SiteConfig
    let client: HTTPClient
    var override: SiteOverride? { site.overrides }
    var canPrecheckDuplicate = true
    var searches = 0
    private let data: Data
    init(site: SiteConfig, client: HTTPClient, data: Data) {
        self.site = site; self.client = client; self.data = data
    }
    func fetchTorrentList() throws -> [ReleaseInfo] { [] }
    func fetchDetail(detailURL: String) throws -> ReleaseInfo {
        ReleaseInfo(siteID: site.id, detailURL: detailURL, name: "站内那条",
                    torrentURL: site.url + "download.php?id=1")
    }
    func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String) {
        (data, "site.torrent")
    }
    func searchExists(_ info: ReleaseInfo) throws -> String? {
        searches += 1
        return site.url + "details.php?id=1"
    }
    func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
        UploadOutcome(success: false, message: "", detailURL: nil)
    }
}

private final class RDLStub: Downloader {
    func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                    skipChecking: Bool, upLimit: Int64) throws -> AddTorrentResult { AddTorrentResult(id: "") }
    func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                    skipChecking: Bool, upLimit: Int64, paused: Bool) throws -> AddTorrentResult {
        AddTorrentResult(id: "")
    }
    func testConnection() throws -> String { "fake" }
    func listTorrents() throws -> [LocalTorrent] { [] }
    func torrentFiles(hash: String) throws -> [(path: String, size: Int64)] { [] }
    func setPaused(hashes: [String], paused: Bool) throws {}
    func removeTorrent(hash: String, keepFiles: Bool) throws {}
    func torrentProgress(hash: String) throws -> (progress: Double, state: String)? { nil }
}
