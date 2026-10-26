import XCTest
@testable import BoxSendKit

/// 假站点：只回答辅种要用的那几件事（检索、详情、下载 .torrent）
private final class FakeSite: SiteAdapter {
    let site: SiteConfig
    let client: HTTPClient
    var override: SiteOverride? { site.overrides }

    /// 站内那条种子的 .torrent 内容；nil = 站内检索不到
    var torrentData: Data?
    var searchCalls = 0
    var detailCalls = 0
    var downloadCalls = 0

    init(site: SiteConfig, client: HTTPClient, torrentData: Data?) {
        self.site = site
        self.client = client
        self.torrentData = torrentData
    }

    var canPrecheckDuplicate = true

    func fetchTorrentList() throws -> [ReleaseInfo] { [] }
    func fetchDetail(detailURL: String) throws -> ReleaseInfo {
        detailCalls += 1
        return ReleaseInfo(siteID: site.id, detailURL: detailURL,
                           name: Bencode.infoName(torrentData ?? Data()) ?? "站内那条",
                           torrentURL: site.url + "download.php?id=1")
    }
    func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String) {
        downloadCalls += 1
        guard let d = torrentData else { throw BoxSendError.badInput("没有种子文件") }
        return (d, "site.torrent")
    }
    func searchExists(_ info: ReleaseInfo) throws -> String? {
        searchCalls += 1
        return torrentData == nil ? nil : site.url + "details.php?id=1"
    }
    func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
        UploadOutcome(success: false, message: "辅种不上传", detailURL: nil)
    }
}

/// 假下载器：文件清单、校验进度脚本、加/删/暂停都记下来
private final class FakeDownloader: Downloader {
    var torrents: [LocalTorrent] = []
    var files: [(path: String, size: Int64)] = []
    /// 按次返回的校验进度；用完重复最后一项
    var progressScript: [(Double, String)] = [(1.0, "stalledUP")]
    private var progressReads = 0

    private(set) var addedPaused: [Bool] = []
    private(set) var addedSkipChecking: [Bool] = []
    private(set) var addedSavePaths: [String] = []
    private(set) var resumed: [String] = []
    private(set) var removed: [(hash: String, keepFiles: Bool)] = []

    func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                    skipChecking: Bool, upLimit: Int64) throws -> AddTorrentResult {
        try addTorrent(data: data, filename: filename, savePath: savePath, category: category,
                       skipChecking: skipChecking, upLimit: upLimit, paused: false)
    }
    func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                    skipChecking: Bool, upLimit: Int64, paused: Bool) throws -> AddTorrentResult {
        addedPaused.append(paused)
        addedSkipChecking.append(skipChecking)
        addedSavePaths.append(savePath ?? "")
        return AddTorrentResult(id: Bencode.infoHash(data) ?? "hash")
    }
    func testConnection() throws -> String { "fake" }
    func listTorrents() throws -> [LocalTorrent] { torrents }
    func torrentFiles(hash: String) throws -> [(path: String, size: Int64)] { files }
    func setPaused(hashes: [String], paused: Bool) throws {
        if !paused { resumed.append(contentsOf: hashes) }
    }
    func removeTorrent(hash: String, keepFiles: Bool) throws {
        removed.append((hash, keepFiles))
    }
    func torrentProgress(hash: String) throws -> (progress: Double, state: String)? {
        let i = min(progressReads, progressScript.count - 1)
        progressReads += 1
        return progressScript[i]
    }
}

final class AssistPipelineTests: XCTestCase {

    // MARK: 夹具

    /// host 传完整域名（不带 scheme）；不传则用 <id>.invalid
    private func site(_ id: String, host: String? = nil) -> SiteConfig {
        SiteConfig(id: id, name: id, url: "https://\(host ?? id + ".invalid")/",
                   framework: .nexusPHP, enabled: true)
    }

    private func localTorrent(hash: String, host: String = "luckpt.invalid") -> LocalTorrent {
        LocalTorrent(hash: hash, name: "Movie.2020.1080p", savePath: "/dl/Movie.2020",
                     totalSize: 300, progress: 1, trackerHosts: [host])
    }

    /// 站点那份 .torrent：一律按「一个目录装若干文件」造（实测猫站单文件种子也是这么打的，
    /// info.name 是目录名），这样清单路径与下载器报的路径口径一致
    private func torrent(root: String, files: [(String, Int64)], source: String) -> Data {
        let info: [String: Any] = ["name": root, "piece length": 262144, "pieces": "0000",
                                   "private": 1, "source": source,
                                   "files": files.map {
                                       ["length": Int($0.1), "path": [$0.0] as [Any]] as [String: Any]
                                   }]
        return BEnc.enc(["info": info, "announce": "https://t/announce"])
    }

    private func makePipe(cfg: AssistConfig, downloader: FakeDownloader, site: SiteConfig,
                          torrentData: Data?)
        -> (AssistPipeline, FakeSite, StateStore) {
        var app = AppConfig.template()
        app.sourceSites = [site]
        app.assist = cfg
        let state = StateStore(dataDir: "/tmp/boxsend-assist-\(UUID().uuidString)")
        let pipe = AssistPipeline(config: app, cookies: CookieStore(), state: state,
                                  downloader: downloader)
        let fake = FakeSite(site: site, client: HTTPClient(cookies: CookieStore(), userAgent: "t"),
                            torrentData: torrentData)
        pipe.adapterFactory = { _, _ in fake }
        return (pipe, fake, state)
    }

    private var quickCfg: AssistConfig {
        AssistConfig(siteIDs: ["target"], perSiteIntervalSec: 0, jitterSec: 0,
                     roundBudget: 50, verifyWaitSec: 3, verifyPollSec: 1)
    }

    /// 站内没找到时默认还会换宽松查询词再问一次（AssistSearchErrorRetryTests 专门测它）。
    /// 只数「问了几次、有没有被负缓存拦住」的测试用这一份，次数才对得上
    private var quietCfg: AssistConfig {
        var cfg = quickCfg
        cfg.relaxedRetrySearch = false
        return cfg
    }

    private func noSleep(_ seconds: TimeInterval) {}

    // MARK: A 级：hash 相同，校验到 100% 才算成

    func testSameHashAssistsAfterVerify() throws {
        let data = torrent(root: "Movie.2020", files: [("Movie.2020.mkv", 100)], source: "Target")
        let dl = FakeDownloader()
        dl.files = [("Movie.2020/Movie.2020.mkv", 100)]
        dl.progressScript = [(0.5, "checkingFiles"), (1.0, "stalledUP")]
        let (pipe, fake, state) = makePipe(cfg: quickCfg, downloader: dl,
                                          site: site("target"), torrentData: data)
        let t = localTorrent(hash: Bencode.infoHash(data)!)
        var o = AssistPipeline.Options(); o.sleep = noSleep
        let report = pipe.run(torrents: [t], opts: o)

        XCTAssertEqual(report.assistedCount, 1, "应辅种成功")
        XCTAssertEqual(dl.addedPaused, [true], "必须先暂停加进去")
        XCTAssertEqual(dl.addedSkipChecking, [false], "必须让下载器真校验，不能跳过")
        XCTAssertEqual(dl.addedSavePaths, ["/dl/Movie.2020"], "沿用本地那条的保存路径")
        XCTAssertEqual(dl.resumed.count, 1, "校验到 100% 才启动")
        XCTAssertTrue(state.isAssisted(site: "target", hash: t.hash))
        XCTAssertEqual(fake.searchCalls, 1)
    }

    // MARK: 校验不满 → 回滚，别让它重下一整份

    func testIncompleteVerifyRollsBack() throws {
        let data = torrent(root: "Movie.2020", files: [("Movie.2020.mkv", 100)], source: "Target")
        let dl = FakeDownloader()
        dl.files = [("Movie.2020/Movie.2020.mkv", 100)]
        dl.progressScript = [(0.5, "checkingFiles"), (0.62, "pausedDL")]
        let (pipe, _, state) = makePipe(cfg: quickCfg, downloader: dl,
                                       site: site("target"), torrentData: data)
        var o = AssistPipeline.Options(); o.sleep = noSleep
        let report = pipe.run(torrents: [localTorrent(hash: Bencode.infoHash(data)!)], opts: o)

        XCTAssertEqual(report.assistedCount, 0)
        XCTAssertEqual(dl.removed.count, 1, "校验不满要删掉刚加的种子")
        XCTAssertEqual(dl.removed.first?.keepFiles, true, "只删种子，文件要留着")
        XCTAssertTrue(dl.resumed.isEmpty, "不满 100% 不启动")
        XCTAssertFalse(state.isAssisted(site: "target", hash: data.hexHashPrefix),
                       "没辅成就不记账")
    }

    // MARK: 站点筛选：一分请求都不该发

    func testAlreadySeedingOnSiteSendsNoRequest() throws {
        let data = torrent(root: "Movie.2020", files: [("a.mkv", 100)], source: "Target")
        let dl = FakeDownloader()
        let (pipe, fake, _) = makePipe(cfg: quickCfg, downloader: dl,
                                       site: site("target", host: "target.invalid"),
                                       torrentData: data)
        let t = localTorrent(hash: "aa", host: "target.invalid")   // tracker 里已有本站
        var o = AssistPipeline.Options(); o.sleep = noSleep
        let report = pipe.run(torrents: [t], opts: o)

        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertEqual(fake.searchCalls, 0, "已在该站做种还去检索，纯属白跑")
    }

    // MARK: 计划：不发请求就能看出哪些组合会跑

    func testPlanMarksSearchableAndSkipped() throws {
        let dl = FakeDownloader()
        let (pipe, fake, _) = makePipe(cfg: quietCfg, downloader: dl,
                                       site: site("target", host: "target.invalid"),
                                       torrentData: nil)
        var o = AssistPipeline.Options(); o.sleep = noSleep
        _ = pipe.run(torrents: [localTorrent(hash: "cc")], opts: o)    // 先跑一轮，站内没有会记进负缓存

        let rows = pipe.plan(torrents: [
            localTorrent(hash: "aa", host: "target.invalid"),   // 已在该站做种
            localTorrent(hash: "cc"),                            // 站内没有（上轮记的）
            localTorrent(hash: "dd"),                            // 没查过：会检索
        ])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].skipReason, "已在该站做种")
        XCTAssertTrue(rows[1].skipReason?.contains("站内没有") == true, "负缓存期内不该再排进检索")
        XCTAssertNil(rows[2].skipReason, "没查过的才该排进检索")
        XCTAssertEqual(fake.searchCalls, 1, "出计划不该再敲站点")
    }

    /// 站点没有检索入口：计划里直接标出来，而不是跑完才发现
    func testPlanMarksSiteWithoutSearch() throws {
        let dl = FakeDownloader()
        let (pipe, fake, _) = makePipe(cfg: quickCfg, downloader: dl,
                                       site: site("target"), torrentData: nil)
        fake.canPrecheckDuplicate = false
        let rows = pipe.plan(torrents: [localTorrent(hash: "ee")])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].skipReason, "该站暂不支持站内检索")
    }

    /// 站内没有：记负缓存，第二次跑不再检索
    func testMissIsCachedAndNotResearched() throws {
        let dl = FakeDownloader()
        let (pipe, fake, _) = makePipe(cfg: quietCfg, downloader: dl,
                                       site: site("target"), torrentData: nil)
        var o = AssistPipeline.Options(); o.sleep = noSleep
        _ = pipe.run(torrents: [localTorrent(hash: "bb")], opts: o)
        XCTAssertEqual(fake.searchCalls, 1)
        _ = pipe.run(torrents: [localTorrent(hash: "bb")], opts: o)
        XCTAssertEqual(fake.searchCalls, 1, "负缓存期内不该再搜")
    }

    /// 预算用完就收工
    func testBudgetExhaustionSkipsRest() throws {
        let data = torrent(root: "Movie.2020", files: [("a.mkv", 100)], source: "Target")
        let dl = FakeDownloader()
        var cfg = quickCfg
        cfg.roundBudget = 1
        let (pipe, fake, _) = makePipe(cfg: cfg, downloader: dl,
                                       site: site("target"), torrentData: data)
        var o = AssistPipeline.Options(); o.sleep = noSleep
        let report = pipe.run(torrents: [localTorrent(hash: "c1"), localTorrent(hash: "c2")], opts: o)
        XCTAssertEqual(fake.searchCalls, 1, "只够一次检索")
        XCTAssertTrue(report.outcomes.contains { $0.message.contains("预算") },
                      "预算用完要说清")
    }

    // MARK: B 级：站点重新打包

    func testSameFilesDifferentHashAssists() throws {
        let localData = torrent(root: "Movie.2020", files: [("Movie.2020.mkv", 100)], source: "LuckPT")
        let siteData = torrent(root: "Movie.2020", files: [("Movie.2020.mkv", 100)], source: "Target")
        XCTAssertNotEqual(Bencode.infoHash(localData), Bencode.infoHash(siteData))
        let dl = FakeDownloader()
        dl.files = [("Movie.2020/Movie.2020.mkv", 100)]
        let (pipe, _, _) = makePipe(cfg: quickCfg, downloader: dl,
                                    site: site("target"), torrentData: siteData)
        var o = AssistPipeline.Options(); o.sleep = noSleep
        let report = pipe.run(torrents: [localTorrent(hash: Bencode.infoHash(localData)!)], opts: o)
        XCTAssertEqual(report.assistedCount, 1, "逐文件清单全等就该辅")
    }

    /// hash 相同但内层目录名不同：不动下载器，避免重下一整份
    func testRootFolderMismatchKeepsDownloaderUntouched() throws {
        let data = torrent(root: "Movie.2020.Chs", files: [("Movie.2020.mkv", 100)], source: "Target")
        let dl = FakeDownloader()
        dl.files = [("Movie.2020/Movie.2020.mkv", 100)]     // 本地目录名少了 .Chs
        let (pipe, _, _) = makePipe(cfg: quickCfg, downloader: dl,
                                    site: site("target"), torrentData: data)
        var o = AssistPipeline.Options(); o.sleep = noSleep
        let report = pipe.run(torrents: [localTorrent(hash: Bencode.infoHash(data)!)], opts: o)

        XCTAssertTrue(dl.addedPaused.isEmpty, "布局对不上就别加")
        XCTAssertTrue(report.outcomes.contains { $0.message.contains("内层目录名") },
                      "要说清为什么没动")
    }

    /// dry-run：只报告，下载器一点不变
    func testDryRunDoesNotTouchDownloader() throws {
        let data = torrent(root: "Movie.2020", files: [("Movie.2020.mkv", 100)], source: "Target")
        let dl = FakeDownloader()
        dl.files = [("Movie.2020/Movie.2020.mkv", 100)]
        let (pipe, _, state) = makePipe(cfg: quickCfg, downloader: dl,
                                        site: site("target"), torrentData: data)
        var o = AssistPipeline.Options(); o.sleep = noSleep; o.dryRun = true
        let report = pipe.run(torrents: [localTorrent(hash: Bencode.infoHash(data)!)], opts: o)

        XCTAssertTrue(dl.addedPaused.isEmpty)
        XCTAssertEqual(report.assistedCount, 0)
        XCTAssertFalse(state.isAssisted(site: "target", hash: data.hexHashPrefix))
    }

    /// 扫描筛选：没下完的、大小不在区间的都不参与
    func testScanFilters() throws {
        let dl = FakeDownloader()
        dl.torrents = [
            LocalTorrent(hash: "a", name: "big", savePath: "/dl/big", totalSize: 200 * 1 << 30, progress: 1),
            LocalTorrent(hash: "b", name: "small", savePath: "/dl/small", totalSize: 1 << 30, progress: 1),
            LocalTorrent(hash: "c", name: "undone", savePath: "/dl/c", totalSize: 200 << 30, progress: 0.4),
        ]
        var cfg = quickCfg
        cfg.minSizeGB = 10
        let (pipe, _, _) = makePipe(cfg: cfg, downloader: dl, site: site("target"), torrentData: nil)
        let got = try pipe.scanCandidates().map(\.hash)
        XCTAssertEqual(got, ["a"], "未下完与太小的都要筛掉")
    }

    // MARK: 人工采纳（界面上的「采纳」按钮）

    /// 清单对不上默认只报「待人工确认」；点了采纳就照人的判断推一次
    func testManualAdoptPushesDespiteFileListMismatch() throws {
        let data = torrent(root: "Movie.2020", files: [("Movie.2020.mkv", 100)], source: "Target")
        let dl = FakeDownloader()
        // 本地多一条字幕：清单对不上，布局也不完全一致
        dl.files = [("Movie.2020/Movie.2020.mkv", 100), ("Movie.2020/chs.srt", 20)]
        let (pipe, _, state) = makePipe(cfg: quickCfg, downloader: dl,
                                        site: site("target"), torrentData: data)
        let local = localTorrent(hash: "aaaa".replacingOccurrences(of: "a", with: "a"))
        var o = AssistPipeline.Options(); o.sleep = noSleep
        var report = pipe.run(torrents: [local], opts: o)
        XCTAssertEqual(report.pendingCount, 1, "默认该交人工")
        XCTAssertTrue(dl.addedPaused.isEmpty)

        var forced = AssistPipeline.Options(); forced.sleep = noSleep
        forced.forceKeys = ["target|\(local.hash)"]
        report = pipe.run(torrents: [local], opts: forced)
        XCTAssertEqual(report.assistedCount, 1, "采纳之后就是一次完整推送")
        XCTAssertEqual(report.pendingCount, 0, "采纳过的不该再算待确认")
        XCTAssertEqual(dl.addedPaused, [true], "仍旧先暂停加进去等校验")
        XCTAssertTrue(report.outcomes[0].message.contains("已按人工采纳"),
                      "要说清这条是人工放行才推的")
        XCTAssertEqual(state.assistCountsBySite()["target"], 1)
    }

    /// 负缓存拦不住人工采纳：人既然比对过，就再去站内看一次
    func testManualAdoptIgnoresNegativeCache() throws {
        let data = torrent(root: "Movie.2020", files: [("Movie.2020.mkv", 100)], source: "Target")
        let dl = FakeDownloader()
        dl.files = [("Movie.2020/Movie.2020.mkv", 100)]
        let (pipe, fake, _) = makePipe(cfg: quickCfg, downloader: dl,
                                       site: site("target"), torrentData: nil)
        let local = localTorrent(hash: Bencode.infoHash(data)!)
        var o = AssistPipeline.Options(); o.sleep = noSleep
        _ = pipe.run(torrents: [local], opts: o)          // 站内没有 → 记进负缓存
        let searchesAfterMiss = fake.searchCalls

        fake.torrentData = data                            // 站点后来补了同一种子
        var normal = AssistPipeline.Options(); normal.sleep = noSleep
        _ = pipe.run(torrents: [local], opts: normal)
        XCTAssertEqual(fake.searchCalls, searchesAfterMiss, "负缓存期内普通重跑不该发请求")

        var forced = AssistPipeline.Options(); forced.sleep = noSleep
        forced.forceKeys = ["target|\(local.hash)"]
        let report = pipe.run(torrents: [local], opts: forced)
        XCTAssertEqual(fake.searchCalls, searchesAfterMiss + 1, "采纳就要重新去站内查一次")
        XCTAssertEqual(report.assistedCount, 1)
    }

    /// 布局对不上时人工采纳会照推，但要把「可能重下一部分」留在结论里
    func testManualAdoptOverridesLayoutGuardWithWarning() throws {
        let data = torrent(root: "Movie.2020.Chs", files: [("Movie.2020.mkv", 100)], source: "Target")
        let dl = FakeDownloader()
        dl.files = [("Movie.2020/Movie.2020.mkv", 100)]    // 内层目录名与站点不同
        let (pipe, _, _) = makePipe(cfg: quickCfg, downloader: dl,
                                    site: site("target"), torrentData: data)
        let local = localTorrent(hash: "bb" + String(repeating: "0", count: 38))
        var o = AssistPipeline.Options(); o.sleep = noSleep
        let blocked = pipe.run(torrents: [local], opts: o)
        XCTAssertTrue(blocked.outcomes[0].message.contains("内层目录名"), "默认拦下并说明原因")
        XCTAssertTrue(dl.addedPaused.isEmpty)

        var forced = AssistPipeline.Options(); forced.sleep = noSleep
        forced.forceKeys = ["target|\(local.hash)"]
        let report = pipe.run(torrents: [local], opts: forced)
        XCTAssertEqual(report.assistedCount, 1, "人工点头就推")
        XCTAssertTrue(report.outcomes[0].message.contains("内层目录名"),
                      "风险要留在结论里，别悄悄重下")
    }
}

private extension Data {
    /// 记录里用的 hash（测试断言 helper）
    var hexHashPrefix: String { Bencode.infoHash(self) ?? "" }
}

/// 定时自动跑的钟：两端共用，逻辑就这几行，测清楚比读代码快
final class AssistAutoRunTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOffMeansNeverDue() {
        let clock = AssistAutoRun(now: now)
        XCTAssertFalse(clock.due(minutes: 0, now: now.addingTimeInterval(86_400)))
        XCTAssertNil(clock.minutesLeft(minutes: 0, now: now))
    }

    func testDueOnlyAfterFullInterval() {
        var clock = AssistAutoRun(now: now)
        XCTAssertFalse(clock.due(minutes: 30, now: now.addingTimeInterval(29 * 60)))
        XCTAssertEqual(clock.minutesLeft(minutes: 30, now: now.addingTimeInterval(29 * 60)), 1)
        XCTAssertTrue(clock.due(minutes: 30, now: now.addingTimeInterval(30 * 60)))
        clock.noteRun(now: now.addingTimeInterval(30 * 60))
        XCTAssertFalse(clock.due(minutes: 30, now: now.addingTimeInterval(40 * 60)))
        XCTAssertEqual(clock.minutesLeft(minutes: 30, now: now.addingTimeInterval(40 * 60)), 20)
    }

    /// 老配置没有这个字段：默认不自动跑，别升级完自己动起来
    func testAutoRunMinutesDefaultsToOff() throws {
        let legacy = try JSONDecoder().decode(AssistConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.autoRunMinutes, 0)
        let on = try JSONDecoder().decode(AssistConfig.self,
                                         from: Data(#"{"autoRunMinutes":45}"#.utf8))
        XCTAssertEqual(on.autoRunMinutes, 45)
    }
}
