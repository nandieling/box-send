import XCTest
@testable import BoxSendKit

/// 种子目录：整库都要能翻，所以列全部；同一条种子在各站各有一份 .torrent，得先去重。
/// 计数按「每个站取一次表 + 集合运算」算，不一条条查状态，也不整表摊行。
final class AssistCatalogTests: XCTestCase {

    private func torrent(_ hash: String, _ name: String, _ size: Int64,
                         trackers: [String] = ["elsewhere.invalid"]) -> LocalTorrent {
        LocalTorrent(hash: hash, name: name, savePath: "/dl", totalSize: size,
                     progress: 1, trackerHosts: trackers)
    }

    private func config(_ sites: [SiteConfig]) -> AppConfig {
        var app = AppConfig.template()
        app.sourceSites = sites
        app.assist = AssistConfig(siteIDs: sites.map(\.id), perSiteIntervalSec: 0, jitterSec: 0)
        return app
    }

    private func site(_ id: String) -> SiteConfig {
        SiteConfig(id: id, name: id, url: "https://\(id).invalid/",
                   framework: .nexusPHP, enabled: true)
    }

    // MARK: 去重

    func testSameHashKeepsOneCopy() {
        let list = AssistPipeline.dedupe([torrent("AA", "Movie A", 10_000),
                                         torrent("aa", "Movie A", 10_000)])
        XCTAssertEqual(list.map(\.hash), ["aa"], "同一 hash 只留一条（hash 不分大小写）")
    }

    func testSameNameSameSizeIsOneTorrent() {
        // 同一条片子在两个站各下一遍：hash 不同（tracker 不同），名字与体积一样
        let list = AssistPipeline.dedupe([torrent("h1", "Movie.2010.1080p.BluRay-GRP.mkv", 5_000_000_000),
                                         torrent("h2", "Movie 2010 1080p BluRay GRP", 5_000_000_000)])
        XCTAssertEqual(list.count, 1, "名字归一化后相同、体积相同 = 同一条种子")
    }

    func testDifferentSizeKeepsBoth() {
        let list = AssistPipeline.dedupe([torrent("h1", "Movie.2010.1080p.BluRay-GRP.mkv", 5_000_000_000),
                                         torrent("h2", "Movie.2010.2160p.BluRay-GRP.mkv", 20_000_000_000)])
        XCTAssertEqual(list.count, 2, "同一片子不同版本是两条种子")
    }

    func testCatalogSortedBySize() {
        let list = AssistPipeline.catalog([torrent("h1", "A", 1_000), torrent("h2", "B", 9_000)])
        XCTAssertEqual(list.map(\.hash), ["h2", "h1"], "大的排前面，收益高的先做")
    }

    // MARK: 计数

    func testBucketsSplitTorrentsPerSite() throws {
        let sites = [site("s1"), site("s2")]
        let state = StateStore(dataDir: "/tmp/boxsend-cat-\(UUID().uuidString)")
        let pipe = AssistPipeline(config: config(sites), cookies: CookieStore(), state: state,
                                  downloader: EmptyTorrentDownloader())
        // s2 没有检索入口：这一站整列都算「不支持检索」
        var fakes: [String: NoSearchSite] = [:]
        pipe.adapterFactory = { s, client -> any SiteAdapter in
            if let hit = fakes[s.id] { return hit }
            let made = NoSearchSite(site: s, client: client, searchable: s.id == "s1")
            fakes[s.id] = made
            return made
        }
        state.markAssisted(site: "s1", hash: "h2", url: "u", level: "sameHash")
        state.markAssistMiss(site: "s1", hash: "h3")
        state.markAssistFail(site: "s1", hash: "h4")
        let list = [
            torrent("h1", "One", 5_000, trackers: ["s1.invalid"]),   // 已在该站做种
            torrent("h2", "Two", 4_000),
            torrent("h3", "Three", 3_000),
            torrent("h4", "Four", 2_000),
            torrent("h5", "Five", 1_000),
        ]
        let plan = pipe.planCatalog(list)
        XCTAssertEqual(plan.total, 10, "5 条种子 × 2 站")
        XCTAssertEqual(plan.tally.count(.seeding), 1)
        XCTAssertEqual(plan.tally.count(.assisted), 1)
        XCTAssertEqual(plan.tally.count(.missing), 1)
        XCTAssertEqual(plan.tally.count(.failed), 1, "上轮失败的单独一类，下轮还会再试")
        XCTAssertEqual(plan.tally.count(.unsupported), 5, "整站不支持检索")
        XCTAssertEqual(plan.tally.count(.pending), 1)
        XCTAssertEqual(plan.willSearch, 1)
        XCTAssertEqual(plan.tally.total, 10)

        // 单格结论与整轮计数必须说同一件事
        let rows = plan.rows(plan.torrents)
        XCTAssertEqual(rows.count, 10, "整份目录摊开 = 5 条种子 × 2 站")
        let seeding = rows.first { $0.siteID == "s1" && $0.hash == "h1" }
        XCTAssertEqual(seeding?.planned, .seeding)
        XCTAssertEqual(seeding?.skipReason, "已在该站做种", "跳过原因要跟着结论走")
        XCTAssertEqual(rows.first { $0.siteID == "s2" && $0.hash == "h5" }?.planned, .unsupported)
        XCTAssertEqual(rows.first { $0.siteID == "s1" && $0.hash == "h4" }?.planned, .failed)
        XCTAssertNil(rows.first { $0.siteID == "s1" && $0.hash == "h4" }?.skipReason,
                     "失败的那格本轮还会再试，不算「跳过」")
    }

    /// 跑过的格子按进展改记：全量计数不能被计划里的旧结论钉住
    func testAdjustedMovesCountedCells() throws {
        let sites = [site("s1")]
        let pipe = AssistPipeline(config: config(sites), cookies: CookieStore(),
                                  state: StateStore(dataDir: "/tmp/boxsend-cat-\(UUID().uuidString)"),
                                  downloader: EmptyTorrentDownloader())
        let plan = pipe.planCatalog([torrent("h1", "One", 1_000), torrent("h2", "Two", 900)])
        XCTAssertEqual(plan.tally.count(.pending), 2)
        let live = ["s1|h1": AssistPipeline.LiveRow(phase: .done, text: "辅种成功")]
        let t = plan.adjusted(live: live)
        XCTAssertEqual(t.count(.assisted), 1)
        XCTAssertEqual(t.count(.pending), 1)
        XCTAssertEqual(t.total, 2, "总数不因进展而变")
    }

    // MARK: 界面上暂停一个站

    /// 点一下卡片上的暂停不该要求重新扫描：派生数（待辅种 ↔ 已暂停、还要检索几次、
    /// 覆盖率、每站那一行、单格结论）当场全部推平
    func testPausingASiteTakesEffectWithoutRescan() throws {
        let sites = [site("s1"), site("s2")]
        let state = StateStore(dataDir: "/tmp/boxsend-cat-\(UUID().uuidString)")
        var fakes: [String: NoSearchSite] = [:]
        let pipe = AssistPipeline(config: config(sites), cookies: CookieStore(), state: state,
                                  downloader: EmptyTorrentDownloader())
        pipe.adapterFactory = { sn, client -> any SiteAdapter in
            if let hit = fakes[sn.id] { return hit }
            let made = NoSearchSite(site: sn, client: client, searchable: sn.id == "s1")
            fakes[sn.id] = made
            return made
        }
        state.markAssisted(site: "s1", hash: "h2", url: "u", level: "sameHash")
        state.markAssistMiss(site: "s1", hash: "h3")
        let list = [torrent("h1", "One", 5_000), torrent("h2", "Two", 4_000),
                    torrent("h3", "Three", 3_000), torrent("h4", "Four", 2_000)]
        let plan = pipe.planCatalog(list)
        XCTAssertEqual(plan.tally.count(.pending), 2, "4 条里 1 已辅过、1 站内没有")
        XCTAssertEqual(plan.willSearch, 2)

        let paused = plan.applyingPaused(["s1"])
        XCTAssertEqual(paused.tally.count(.pending), 0)
        XCTAssertEqual(paused.tally.count(.paused), 2, "暂停站里那两格算「压着」，仍没结论")
        XCTAssertEqual(paused.willSearch, 0, "暂停站不计入要检索的量")
        XCTAssertEqual(paused.pendingBySite["s1"], 0)
        XCTAssertEqual(paused.tally.total, plan.tally.total, "推平不搬走格子，只换归类")
        XCTAssertNil(paused.counts.first { $0.reason == "会去站内检索" }?.count)
        XCTAssertEqual(paused.counts.first { $0.reason == "本站已暂停" }?.count, 2)

        let cov = paused.coverage()
        XCTAssertEqual(cov.searchesLeft, 0)
        XCTAssertEqual(cov.paused, 2)
        XCTAssertEqual(cov.siteCount, 0, "没有站有活儿，就不该说「在跑的站 1 个」")
        XCTAssertTrue(cov.line.contains("暂停站里压着 2 格"), "\(cov.line)")

        let sp = paused.siteProgress().first { $0.siteID == "s1" }
        XCTAssertEqual(sp?.state, .paused)
        XCTAssertEqual(sp?.searches, 0)
        XCTAssertEqual(sp?.nextLine, "已暂停，压着 2 格")
        XCTAssertEqual(sp?.pausedSite, true)

        let cell = paused.rows([list[3]]).first { $0.siteID == "s1" }
        XCTAssertEqual(cell?.planned, .paused, "格子也跟着改结论")
        XCTAssertEqual(cell?.skipReason, "本站已暂停（点这张站卡恢复）")

        // 取消暂停：回到原来那份数
        let resumed = paused.applyingPaused([])
        XCTAssertEqual(resumed.tally.count(.pending), 2)
        XCTAssertEqual(resumed.tally.count(.paused), 0)
        XCTAssertEqual(resumed.willSearch, 2)
        XCTAssertEqual(resumed.pendingBySite["s1"], 2)

        // 名单没变：原样返回，不复制那几万个 hash 集合
        let same = plan.applyingPaused([])
        XCTAssertEqual(same.tally, plan.tally)
        XCTAssertEqual(same.counts.map(\.reason), plan.counts.map(\.reason))

        // 不支持检索的站：暂停它没有意义，数一格都不该动
        let pauseUnsupported = plan.applyingPaused(["s2", "s1"])
        XCTAssertEqual(pauseUnsupported.siteProgress().first { $0.siteID == "s2" }?.state,
                       .unsupported)
        XCTAssertEqual(pauseUnsupported.tally, paused.tally)
    }

    // MARK: 失败记账

    func testFailureIsCountedAndRetried() throws {
        let sites = [site("s1")]
        let state = StateStore(dataDir: "/tmp/boxsend-cat-\(UUID().uuidString)")
        let pipe = AssistPipeline(config: config(sites), cookies: CookieStore(), state: state,
                                  downloader: EmptyTorrentDownloader())
        let broken = BrokenSite(site: sites[0],
                               client: HTTPClient(cookies: CookieStore(), userAgent: "test"))
        pipe.adapterFactory = { _, _ -> any SiteAdapter in broken }
        let list = [torrent("h1", "One", 1_000)]
        var o = AssistPipeline.Options()
        o.sleep = { _ in }
        _ = pipe.run(torrents: list, opts: o)
        XCTAssertEqual(broken.downloadCalls, 1)
        XCTAssertEqual(pipe.planCatalog(list).tally.count(.failed), 1)

        // 失败不该被预筛拦住：下一轮还要再去试一次
        _ = pipe.run(torrents: list, opts: o)
        XCTAssertEqual(broken.downloadCalls, 2, "失败不记进负缓存，下轮照常重试")
    }

    /// 辅成功要把失败记录清掉：同一格不该同时算已辅和失败
    func testSuccessClearsFailure() {
        let state = StateStore(dataDir: "/tmp/boxsend-cat-\(UUID().uuidString)")
        state.markAssistFail(site: "s1", hash: "h1")
        XCTAssertEqual(state.assistFailHashes(site: "s1"), ["h1"])
        state.markAssisted(site: "s1", hash: "h1", url: "u", level: "sameHash")
        XCTAssertTrue(state.assistFailHashes(site: "s1").isEmpty)
    }
}

/// 不读下载器的假下载器（计划与计数不碰下载器）
final class EmptyTorrentDownloader: Downloader {
    var torrents: [LocalTorrent] = []
    func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                    skipChecking: Bool, upLimit: Int64) throws -> AddTorrentResult {
        AddTorrentResult(id: "")
    }
    func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                    skipChecking: Bool, upLimit: Int64, paused: Bool) throws -> AddTorrentResult {
        AddTorrentResult(id: "")
    }
    func testConnection() throws -> String { "fake" }
    func listTorrents() throws -> [LocalTorrent] { torrents }
    func torrentFiles(hash: String) throws -> [(path: String, size: Int64)] { [] }
    func setPaused(hashes: [String], paused: Bool) throws {}
    func removeTorrent(hash: String, keepFiles: Bool) throws {}
}

/// 可指定「有没有检索入口」的假站点
private final class NoSearchSite: SiteAdapter {
    let site: SiteConfig
    let client: HTTPClient
    var override: SiteOverride? { site.overrides }
    let searchable: Bool
    init(site: SiteConfig, client: HTTPClient, searchable: Bool) {
        self.site = site; self.client = client; self.searchable = searchable
    }
    var canPrecheckDuplicate: Bool { searchable }
    func fetchTorrentList() throws -> [ReleaseInfo] { [] }
    func fetchDetail(detailURL: String) throws -> ReleaseInfo {
        ReleaseInfo(siteID: site.id, detailURL: detailURL, name: "T")
    }
    func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String) {
        (Data(), "s.torrent")
    }
    func searchExists(_ info: ReleaseInfo) throws -> String? { nil }
    func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
        UploadOutcome(success: false, message: "辅种不上传", detailURL: nil)
    }
}

/// 检索得到、但 .torrent 读不下来的站：辅种要按失败记一笔
final class BrokenSite: SiteAdapter {
    let site: SiteConfig
    let client: HTTPClient
    var override: SiteOverride? { site.overrides }
    private(set) var downloadCalls = 0
    init(site: SiteConfig, client: HTTPClient) { self.site = site; self.client = client }
    var canPrecheckDuplicate: Bool { true }
    func fetchTorrentList() throws -> [ReleaseInfo] { [] }
    func fetchDetail(detailURL: String) throws -> ReleaseInfo {
        ReleaseInfo(siteID: site.id, detailURL: detailURL, name: "T",
                    torrentURL: site.url + "download.php?id=1")
    }
    func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String) {
        downloadCalls += 1
        throw BoxSendError.badInput("站点那条读不下来")
    }
    func searchExists(_ info: ReleaseInfo) throws -> String? { site.url + "details.php?id=1" }
    func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
        UploadOutcome(success: false, message: "辅种不上传", detailURL: nil)
    }
}
