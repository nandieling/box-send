import XCTest
@testable import BoxSendKit

/// 猫站实测（LuckPT 46440 黑礁第一季 Blu-ray Remux）：站内早被别人发过，
/// 但「已存在」页认错了种子（指到页首横幅广告那条），也没把站内那条推给下载器。
/// 查重要认得对、显示要说清是哪条、已存在的种子要照常推。
final class DuplicatePushTests: XCTestCase {
    private let client = HTTPClient(cookies: CookieStore(), userAgent: "BoxSendTest")

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private var pter: SiteConfig {
        SiteConfig(id: "pter", name: "猫", url: "https://pterclub.net/",
                   framework: .nexusPHP, enabled: true)
    }

    /// 源站详情标题（站内那条把它写成 BluRay）
    private let ours = "Black Lagoon S01 2006 1080p Blu-ray Remux AVC LPCM 2.0-LuckAni"

    // MARK: - 1 「已存在」页：认站点指的那条，不是横幅广告

    func testPTerDuplicatePagePointsAtTheExistingTorrent() throws {
        let dup = NexusPHPAdapter.duplicateOutcome(
            body: try fixture("pter-duplicate-page.html"),
            uploadURL: "https://pterclub.net/takeupload.php",
            detailPattern: NexusPHPAdapter.defaultDetailHrefPattern,
            releaseName: ours)
        XCTAssertEqual(dup?.detailURL, "https://pterclub.net/details.php?id=768037",
                       "要指向提示块里那条（torrent-exists-tbl），实际 \(dup?.detailURL ?? "nil")")
        XCTAssertFalse((dup?.detailURL ?? "").contains("617819"), "617819 是页首横幅广告")
        XCTAssertFalse((dup?.detailURL ?? "").contains("2257"), "2257 是注释掉的 Banner")
    }

    func testPTerDuplicateMessageNamesTheExistingTorrent() throws {
        let dup = NexusPHPAdapter.duplicateOutcome(
            body: try fixture("pter-duplicate-page.html"),
            uploadURL: "https://pterclub.net/takeupload.php",
            detailPattern: NexusPHPAdapter.defaultDetailHrefPattern,
            releaseName: ours) ?? UploadOutcome(success: false, message: "", detailURL: nil)
        XCTAssertTrue(dup.message.contains("Black Lagoon S01 2006 1080p BluRay Remux AVC LPCM 2.0-LuckAni"),
                      "提示里要写清重复的是哪一条，实际：\(dup.message)")
    }

    /// 织梦那次的行为不能变：提示页展开的种子以它自己的下载链接为准（382434）
    func testNoticePageStillPrefersTorrentsOwnDownloadLink() throws {
        let body = try fixture("zmpt-duplicate-page.html")
        let dup = NexusPHPAdapter.duplicateOutcome(
            body: body, uploadURL: "https://zmpt.cc/takeupload.php",
            detailPattern: NexusPHPAdapter.defaultDetailHrefPattern,
            releaseName: "Nagato Yuki-chan no Shoshitsu S01 2015.1080p Blu-ray Remux AVC AC3-LuckAni")
        XCTAssertEqual(dup?.detailURL, "https://zmpt.cc/details.php?id=382434")
    }

    // MARK: - 2 站内检索：写法差异与查询词

    /// 站内把 Blu-ray 写成 BluRay：去分隔符后是 blurray，必须还认得是同一种子
    func testBluRaySpellingVariantStillMatches() {
        let site = "Black Lagoon S01 2006 1080p BluRay Remux AVC LPCM 2.0-LuckAni"
        XCTAssertTrue(NexusPHPAdapter.searchNamesMatch(site, ours),
                      "BluRay / Blu-ray 是同一份介质，不该判成两个版本")
        XCTAssertFalse(NexusPHPAdapter.searchNamesMatch(
            "Black Lagoon 2006 S01 Complete 1080p Blu-ray AVC LPCM 2.0-U2", ours),
            "同剧另一版本（没有 Remux、组名不同）仍要判成不同种子")
    }

    /// 站点检索按词匹配，整名里的「Blu-」会把 BluRay 那条劈掉：补一条去标点词元查询
    func testWordQueryDropsPunctuationThatSiteSearchCannotHandle() {
        XCTAssertEqual(NexusPHPAdapter.wordQuery(ours),
                       "black lagoon s01 2006 1080p bluray")
        XCTAssertNil(NexusPHPAdapter.wordQuery("Food.torrent"), "词太少就别查了")
    }

    /// 用中文副标题查（猫站结果行写的还是英文发布名）：复核要拿发布名一起看
    func testSubtitleSearchIsVerifiedAgainstReleaseName() throws {
        let hit = NexusPHPAdapter.searchNameInResults(
            html: try fixture("pter-search-blacklagoon-luckani.html"),
            releaseNames: NexusPHPAdapter.matchNames("黑礁 第一季", releaseName: ours),
            base: URL(string: "https://pterclub.net/torrents.php")!,
            hrefPattern: NexusPHPAdapter.defaultDetailHrefPattern, relaxed: true)
        XCTAssertTrue(hit?.href.contains("768037") ?? false, "应指向 768037，实际 \(hit?.href ?? "nil")")
    }

    /// 同一次查重里另一页只有同剧另一版本（U2 原盘），不能被当成「已存在」
    func testOtherVersionPageIsNotAHit() throws {
        let hit = NexusPHPAdapter.searchNameInResults(
            html: try fixture("pter-search-blacklagoon-u2.html"),
            releaseNames: NexusPHPAdapter.matchNames(ours, releaseName: ours),
            base: URL(string: "https://pterclub.net/torrents.php")!,
            hrefPattern: NexusPHPAdapter.defaultDetailHrefPattern, relaxed: true)
        XCTAssertNil(hit, "只有一条同剧不同版本的种子时不算命中")
    }

    // MARK: - 3 已存在的种子也要推下载器（第二次运行补链接再推）

    private final class ExistsAdapter: SiteAdapter {
        let site: SiteConfig
        let client: HTTPClient
        var override: SiteOverride? { nil }
        /// 第一次宽松回查查不到（站点提示页也没给链接），第二次才补到
        let relaxedCalls: DupCounter
        /// 重跑时「站内这条归谁」的答案
        var owned: TorrentOwnership = .unknown
        init(site: SiteConfig, client: HTTPClient, relaxedCalls box: DupCounter) {
            self.site = site; self.client = client; self.relaxedCalls = box
        }
        func fetchTorrentList() throws -> [ReleaseInfo] { [] }
        func fetchDetail(detailURL: String) throws -> ReleaseInfo {
            ReleaseInfo(siteID: site.id, detailURL: detailURL, name: "T",
                        torrentName: "\(site.id).torrent", torrentURL: detailURL)
        }
        func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String) {
            (Data("seed".utf8), "\(site.id).torrent")
        }
        func searchExists(_ info: ReleaseInfo) throws -> String? { nil }
        func searchExists(_ info: ReleaseInfo, relaxed: Bool) throws -> String? {
            guard relaxed else { return nil }
            relaxedCalls.n += 1
            return relaxedCalls.n >= 2 ? "details.php?id=768037" : nil
        }
        var canPrecheckDuplicate: Bool { true }
        func torrentOwnership(detailURL: String, uploadedAt: Date?) -> TorrentOwnership { owned }
        func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
            UploadOutcome(success: true, message: "站点回「种子已存在」，本次未新发种",
                          detailURL: nil, alreadyExists: true)
        }
    }

    private final class FakeDownloader: Downloader {
        var items: [String] = []
        func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                        skipChecking: Bool, upLimit: Int64) throws -> AddTorrentResult {
            items.append("push:\(filename)")
            return AddTorrentResult(id: "hash")
        }
        func testConnection() throws -> String { "fake" }
    }

    func testExistingTorrentGetsPushedOnTheNextRun() throws {
        var cfg = AppConfig.template()
        cfg.sourceSites = [SiteConfig(id: "src", name: "src", url: "https://src.invalid/",
                                      framework: .nexusPHP, enabled: true),
                           SiteConfig(id: "pter", name: "猫", url: "https://pterclub.net/",
                                      framework: .nexusPHP, enabled: true)]
        cfg.targetSites = ["pter"]
        let state = StateStore(dataDir: "/tmp/boxsend-dup-\(UUID().uuidString)")
        let dl = FakeDownloader()
        let calls = DupCounter()
        let pipe = ReseedPipeline(config: cfg, cookies: CookieStore(), state: state, downloader: dl)
        pipe.adapterFactory = { s, client, _ in ExistsAdapter(site: s, client: client, relaxedCalls: calls) }
        var events: [String] = []
        var o = ReseedPipeline.Options()
        o.onSiteEvent = { e in events.append("\(e.siteID)/\(e.text)") }
        o.onSitePush = { e in events.append("\(e.siteID)/\(e.text)") }

        // 第一次：站点说已存在、链接没找回 -> 只标状态，不假装推过
        _ = try pipe.run(detailURL: "https://src.invalid/details.php?id=1", sourceSiteID: "src", opts: o)
        let firstTargetPushes = dl.items.filter { $0.contains("pter") }
        XCTAssertTrue(firstTargetPushes.isEmpty, "\(dl.items)")
        XCTAssertTrue(state.isExisting(site: "pter", key: stateTestKey), "要记下这次是「站内已有」")

        // 第二次：补查站内链接并把那条种子推给下载器
        events.removeAll()
        _ = try pipe.run(detailURL: "https://src.invalid/details.php?id=1", sourceSiteID: "src", opts: o)
        XCTAssertEqual(dl.items.filter { $0.contains("pter") }, ["push:pter.torrent"],
                       "补到链接后要把站内那条推下去：\(dl.items)")
        XCTAssertTrue(events.contains("pter/站内已有该种子"), "\(events)")
        XCTAssertTrue(events.contains("pter/推送已有种子"), "\(events)")
    }

    // MARK: - 4 重跑：回站内看清那条是谁发的

    private let nav = "<span>欢迎回来, <a href=\"userdetails.php?id=14368\">andie</a></span>"

    func testOwnershipReadsUploaderLine() {
        let mine = nav + "<td>由 <a href=\"userdetails.php?id=14368\">andie</a> 发布于"
            + "<span title=\"2026-03-07 22:23:12\">7月12天前</span></td>"
        XCTAssertEqual(NexusPHPAdapter.reseedOwnership(mine, torrentID: "768037"), .ours)
        let theirs = nav + "<td>由 <a href=\"userdetails.php?id=99999\">someone</a> 发布于"
            + "<span title=\"2026-03-07 22:23:12\">7月12天前</span></td>"
        XCTAssertEqual(NexusPHPAdapter.reseedOwnership(theirs, torrentID: "768037"), .theirs)
    }

    /// 猫站允许匿名发布：发布者一行写「匿名」，只能看发布时间与本地记下转种的时间差多久
    func testOwnershipFallsBackToPublishTimeAndEditLink() {
        let anon = nav + "<td>由&nbsp;<i>匿名</i>发布于<span title=\"2026-03-07 22:23:12\">7月12天前</span></td>"
        let today = Date(timeIntervalSince1970: 1_792_100_000)     // 2026-10-16
        XCTAssertEqual(NexusPHPAdapter.reseedOwnership(anon, torrentID: "768037", uploadedAt: today),
                       .theirs, "站里那条比本次转种早半年，不可能是我们发的")
        XCTAssertEqual(NexusPHPAdapter.reseedOwnership(anon, torrentID: "768037", uploadedAt: nil),
                       .unknown, "认不出发布者也没时间参照时不下结论")
        XCTAssertEqual(NexusPHPAdapter.reseedOwnership(anon + "<a href=\"edit.php?id=768037\">编辑</a>",
                                                      torrentID: "768037", uploadedAt: today),
                       .ours, "页面上有我自己的编辑入口，就是这条是我发的")
        let fresh = nav + "<td>由&nbsp;<i>匿名</i>发布于<span title=\"2026-10-16 10:00:00\">1小时前</span></td>"
        XCTAssertEqual(NexusPHPAdapter.reseedOwnership(fresh, torrentID: "768037", uploadedAt: today),
                       .unknown, "时间对得上时不判成别人的")
    }

    /// 早前那次只记下「已转种」，站内这条其实是别人发的：重跑要显示「站内已有该种子」并推那条
    func testRerunReportsDuplicateWhenSiteCopyIsNotOurs() throws {
        var cfg = AppConfig.template()
        cfg.sourceSites = [SiteConfig(id: "src", name: "src", url: "https://src.invalid/",
                                      framework: .nexusPHP, enabled: true),
                           SiteConfig(id: "pter", name: "猫", url: "https://pterclub.net/",
                                      framework: .nexusPHP, enabled: true)]
        cfg.targetSites = ["pter"]
        let state = StateStore(dataDir: "/tmp/boxsend-dup-\(UUID().uuidString)")
        let key = stateTestKey
        state.markUploaded(site: "pter", key: key)
        state.markTargetURL(site: "pter", key: key, url: "https://pterclub.net/details.php?id=768037")
        let dl = FakeDownloader()
        let pipe = ReseedPipeline(config: cfg, cookies: CookieStore(), state: state, downloader: dl)
        pipe.adapterFactory = { s, client, _ in
            let a = ExistsAdapter(site: s, client: client, relaxedCalls: DupCounter())
            a.owned = s.id == "pter" ? .theirs : .unknown
            return a
        }
        var events: [String] = []
        var o = ReseedPipeline.Options()
        o.onSiteEvent = { e in events.append("\(e.siteID)/\(e.text)") }
        o.onSitePush = { e in events.append("\(e.siteID)/\(e.text)") }

        let report = try pipe.run(detailURL: "https://src.invalid/details.php?id=1",
                                  sourceSiteID: "src", opts: o)
        XCTAssertTrue(events.contains("pter/站内已有该种子"), "\(events)")
        XCTAssertTrue(events.contains("pter/推送已有种子"), "\(events)")
        XCTAssertTrue(report.outcomes.contains { $0.site == "pter" && $0.message.contains("768037") })
        XCTAssertTrue(state.isExisting(site: "pter", key: key), "看清是别人的之后就记下「站内已有」")
    }

    /// 站内那条确实是自己发的：保持「转种成功（此前已转种）」，别乱标重复
    func testRerunKeepsSuccessWhenSiteCopyIsOurs() throws {
        var cfg = AppConfig.template()
        cfg.sourceSites = [SiteConfig(id: "src", name: "src", url: "https://src.invalid/",
                                      framework: .nexusPHP, enabled: true),
                           SiteConfig(id: "pter", name: "猫", url: "https://pterclub.net/",
                                      framework: .nexusPHP, enabled: true)]
        cfg.targetSites = ["pter"]
        let state = StateStore(dataDir: "/tmp/boxsend-dup-\(UUID().uuidString)")
        state.markUploaded(site: "pter", key: stateTestKey)
        state.markTargetURL(site: "pter", key: stateTestKey, url: "https://pterclub.net/details.php?id=1")
        state.markExisting(site: "pter", key: stateTestKey)
        let pipe = ReseedPipeline(config: cfg, cookies: CookieStore(), state: state,
                                  downloader: FakeDownloader())
        pipe.adapterFactory = { s, client, _ in
            let a = ExistsAdapter(site: s, client: client, relaxedCalls: DupCounter())
            a.owned = .ours
            return a
        }
        var events: [String] = []
        var o = ReseedPipeline.Options()
        o.onSiteEvent = { e in events.append("\(e.siteID)/\(e.text)") }

        _ = try pipe.run(detailURL: "https://src.invalid/details.php?id=1", sourceSiteID: "src", opts: o)
        XCTAssertTrue(events.contains("pter/转种成功"), "\(events)")
        XCTAssertFalse(state.isExisting(site: "pter", key: stateTestKey), "认出是自己的种子就撤掉重复标记")
    }

}

/// 跨适配器实例共享的宽松回查计数
final class DupCounter { var n = 0 }

/// 与 ReleaseInfo.dedupKey 对齐：源站详情标题由测试适配器固定给成 "T"
private let stateTestKey = ReleaseInfo(siteID: "src", detailURL: "https://src.invalid/details.php?id=1",
                                       name: "T", torrentName: "src.torrent",
                                       torrentURL: "https://src.invalid/details.php?id=1").dedupKey
