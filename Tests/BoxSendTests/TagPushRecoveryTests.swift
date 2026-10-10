import XCTest
@testable import BoxSendKit

/// 第三批实测反馈（同一颗银魂剧场版 DIY 原盘）：
/// 龙要按豆瓣评分打「高分」、按码率打「高码」；吐鲁番来源不许落到 0DAY/Scene；
/// 站点回「发布成功」却没给新种子链接时要能把链接找回来并真的推 Download；
/// 下载器里已有同 hash 种子时必须把本站 tracker 补挂上，否则跨种等于没生效。
final class TagPushRecoveryTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private let client = HTTPClient(cookies: CookieStore(), userAgent: "BoxSendTest")

    private func adapter(_ id: String) -> NexusPHPAdapter {
        let site = SiteRegistry.prioritySites.first { $0.id == id }
            ?? SiteConfig(id: id, name: id, url: "https://example.com/", framework: .nexusPHP, enabled: true)
        return NexusPHPAdapter(site: SiteRegistry.effectiveSite(site), client: client)
    }

    private func values(_ fields: [HTTPClient.MultipartField], _ name: String) -> [String] {
        fields.filter { $0.name == name }.map { $0.value }
    }
    private func value(_ fields: [HTTPClient.MultipartField], _ name: String) -> String? {
        values(fields, name).last
    }

    /// 真种子：DIY 蓝光 + DTS-HD MA + 中字，简介里豆瓣评分 9.3、BDInfo 总码率 46.11 Mbps
    private func sourceRelease() throws -> ReleaseInfo {
        try adapter("luckpt").parseDetail(
            html: try fixture("luckpt-43749-bdinfo.html"),
            detailURL: "https://pt.luckpt.de/details.php?id=43749")
    }

    // MARK: - 4 龙：高分 / 高码

    func testLongptChecksHighRatingAndHighBitrate() throws {
        let info = try sourceRelease()
        XCTAssertEqual(QualityTokens.doubanRating(info), 9.3)
        XCTAssertEqual(QualityTokens.videoBitrateMbps(info) ?? 0, 46.11, accuracy: 0.01)

        let f = adapter("longpt").buildUploadFields(info, page: try fixture("longpt-upload.html"))
        let tags = values(f, "tags[4][]")
        XCTAssertTrue(tags.contains("13"), "13=高分（豆瓣 9.3）；实际勾了 \(tags)")
        XCTAssertTrue(tags.contains("15"), "15=高码（1080p 46 Mbps ≥ 9）；实际勾了 \(tags)")
        XCTAssertTrue(tags.contains("6"), "中字标签照旧")
        XCTAssertTrue(tags.contains("4"), "DIY 标签照旧")
    }

    func testHighTagsRespectThresholds() {
        // 豆瓣 7.3：到不了 8 分门槛
        XCTAssertEqual(QualityTokens.rating(from: "◎豆瓣评分　7.3/10 from 3821 users"), 7.3)
        var low = ReleaseInfo(siteID: "x", detailURL: "https://x/", name: "Show 2020 720p WEB-DL H264-X")
        low.descr = "<p>◎豆瓣评分　7.3/10</p><p>Overall bit rate : 3.2 Mb/s</p>"
        XCTAssertFalse(QualityTokens.canonicalTags(low).contains("highrating"), "低分不打高分")
        XCTAssertFalse(QualityTokens.canonicalTags(low).contains("highbitrate"), "720p 3.2 Mbps 不算高码")
        XCTAssertEqual(QualityTokens.rating(from: "❁ 豆瓣评分: 8.5/10 from 34670 users"), 8.5)
        // 码率单位与千分位
        XCTAssertEqual(QualityTokens.declaredBitrateMbps("Total Bitrate:          46.11 Mbps") ?? -1, 46.11,
                       accuracy: 0.01)
        XCTAssertEqual(QualityTokens.declaredBitrateMbps("Overall bit rate                         : 25.7 Mb/s") ?? -1,
                       25.7, accuracy: 0.01)
        XCTAssertEqual(QualityTokens.declaredBitrateMbps("Total Bitrate: 3 552 kb/s") ?? -1, 3.552, accuracy: 0.01)

        func shot(_ name: String, _ mbps: Double) -> ReleaseInfo {
            var i = ReleaseInfo(siteID: "x", detailURL: "https://x/", name: name)
            i.mediainfo = "Overall bit rate : \(mbps) Mb/s"
            return i
        }
        XCTAssertTrue(QualityTokens.isHighBitrateRelease(shot("Movie 2020 2160p WEB-DL HEVC-X", 15)))
        XCTAssertFalse(QualityTokens.isHighBitrateRelease(shot("Movie 2020 2160p WEB-DL HEVC-X", 14.9)))
        XCTAssertTrue(QualityTokens.isHighBitrateRelease(shot("Movie 2020 1080p WEB-DL H264-X", 9)))
        XCTAssertFalse(QualityTokens.isHighBitrateRelease(shot("Movie 2020 1080p WEB-DL H264-X", 8)))
        XCTAssertTrue(QualityTokens.isHighBitrateRelease(shot("Movie 2020 720p WEB-DL H264-X", 4)))
        // 480p 不设门槛
        XCTAssertFalse(QualityTokens.isHighBitrateRelease(shot("Movie 2020 480p WEB-DL H264-X", 30)))
    }

    func testBitrateFallsBackToSizeOverRuntime() {
        var info = ReleaseInfo(siteID: "x", detailURL: "https://x/",
                               name: "Gekijouban Gintama 2013 1080p Blu-ray AVC DTS-HD MA 5.1-LuckDIY")
        info.size = 38_237_134_848            // 35.61 GiB
        info.descr = "<p>◎片　　长　110分钟</p>"
        XCTAssertEqual(QualityTokens.videoBitrateMbps(info) ?? 0, 46.3, accuracy: 1.0)
        XCTAssertTrue(QualityTokens.isHighBitrateRelease(info))
    }

    // MARK: - 2 吐鲁番：来源不勾 0DAY/Scene

    func testTlfSourcePicksP2PNotScene() throws {
        let info = try sourceRelease()
        let f = adapter("tlf").buildUploadFields(info, page: try fixture("tlf-upload.html"))
        XCTAssertEqual(value(f, "source_sel"), "17", "17=P2P/Non-Scene，转种不是 0day 发布")
    }

    // MARK: - 5 海胆：响应页里唯一详情链接

    func testSoleDetailURLOnlyWhenUnambiguous() {
        let base = URL(string: "https://www.haidan.cc/upload.php")!
        let one = "<p>发布成功</p><a href=\"details.php?id=79788\">点此查看</a>"
            + "<a href=\"details.php?id=79788&hit=1\">再次查看</a>"
        XCTAssertEqual(NexusPHPAdapter.soleDetailURL(body: one, base: base,
                                                     hrefPattern: "details\\.php\\?id=\\d+"),
                       "https://www.haidan.cc/details.php?id=79788")
        let two = "<a href=\"details.php?id=1\">a</a><a href=\"details.php?id=2\">b</a>"
        XCTAssertNil(NexusPHPAdapter.soleDetailURL(body: two, base: base,
                                                   hrefPattern: "details\\.php\\?id=\\d+"))
        XCTAssertNil(NexusPHPAdapter.soleDetailURL(body: "<p>发布成功</p>", base: base,
                                                   hrefPattern: "details\\.php\\?id=\\d+"))
    }

    // MARK: - 1 hd-space：同 hash 种子要能补挂 tracker

    func testAnnounceURLsFromTorrent() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("food.torrent")
        let data = try Data(contentsOf: url)
        let announce = Bencode.announceURLs(data)
        XCTAssertFalse(announce.isEmpty, "种子文件里应能读出 tracker")
        XCTAssertTrue(announce.allSatisfy { $0.hasPrefix("http") }, "\(announce)")
    }

    // MARK: - 站点没回链接：站内回查补链接并照常推送

    private final class SilentAdapter: SiteAdapter {
        let site: SiteConfig
        let client: HTTPClient
        var override: SiteOverride? { nil }
        var pushed: [String] = []
        init(site: SiteConfig, client: HTTPClient) { self.site = site; self.client = client }
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
            relaxed ? "details.php?id=999" : nil
        }
        var canPrecheckDuplicate: Bool { true }
        func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
            pushed.append("reseed:\(site.id)")
            // 海胆：只说"发布成功"，既不跳转也不给链接
            return UploadOutcome(success: true, message: "发布成功", detailURL: nil)
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

    func testMissingDetailURLIsRecoveredBySiteSearchAndPushed() throws {
        var cfg = AppConfig.template()
        cfg.sourceSites = [SiteConfig(id: "src", name: "src", url: "https://src.invalid/",
                                      framework: .nexusPHP, enabled: true),
                           SiteConfig(id: "haidan", name: "海胆", url: "https://www.haidan.cc/",
                                      framework: .nexusPHP, enabled: true)]
        cfg.targetSites = ["haidan"]
        let dl = FakeDownloader()
        let pipe = ReseedPipeline(config: cfg, cookies: CookieStore(),
                                  state: StateStore(dataDir: "/tmp/boxsend-recover-\(UUID().uuidString)"),
                                  downloader: dl)
        pipe.adapterFactory = { s, client, _ in SilentAdapter(site: s, client: client) }
        var events: [String] = []
        var warnings: [String] = []
        var o = ReseedPipeline.Options()
        o.onSiteEvent = { e in events.append("\(e.siteID)/\(e.text)") }
        o.onSitePush = { e in events.append("\(e.siteID)/\(e.text)") }
        o.onSiteWarning = { site, w in warnings.append("\(site)/\(w)") }

        let report = try pipe.run(detailURL: "https://src.invalid/details.php?id=1",
                                  sourceSiteID: "src", opts: o)
        XCTAssertEqual(dl.items, ["push:src.torrent", "push:haidan.torrent"],
                       "站内回查补到链接后必须照常推送")
        XCTAssertTrue(events.contains("haidan/已推送"), "\(events)")
        XCTAssertTrue(report.outcomes.contains { $0.site == "haidan" && $0.ok })
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
    }

    func testUnrecoverableDetailURLWarnsInsteadOfStayingSilent() throws {
        var cfg = AppConfig.template()
        cfg.sourceSites = [SiteConfig(id: "src", name: "src", url: "https://src.invalid/",
                                      framework: .nexusPHP, enabled: true),
                           SiteConfig(id: "haidan", name: "海胆", url: "https://www.haidan.cc/",
                                      framework: .nexusPHP, enabled: true)]
        cfg.targetSites = ["haidan"]
        let dl = FakeDownloader()
        let pipe = ReseedPipeline(config: cfg, cookies: CookieStore(),
                                  state: StateStore(dataDir: "/tmp/boxsend-recover-\(UUID().uuidString)"),
                                  downloader: dl)
        pipe.adapterFactory = { s, client, _ in SilentAdapterSearchNil(site: s, client: client) }
        var warnings: [String] = []
        var o = ReseedPipeline.Options()
        o.onSiteWarning = { site, w in warnings.append("\(site)") }

        _ = try pipe.run(detailURL: "https://src.invalid/details.php?id=1", sourceSiteID: "src", opts: o)
        XCTAssertEqual(dl.items, ["push:src.torrent"], "找不到链接就不该假装推过")
        XCTAssertEqual(warnings, ["haidan"], "没推送必须给出可见提醒")
    }

    // MARK: - 海胆：站点只回「发布成功」时别把用户主页当新种子链接

    /// 海胆的成功页里只有 userdetails.php?id=（本人 UID），它包含 "details.php?id="，
    /// 早先会被当成刚发的种子链接，推送时解析失败：「无法解析 HAIDAN 标题」
    func testSoleDetailURLIgnoresUserPages() throws {
        let base = URL(string: "https://www.haidan.cc/upload.php")!
        let userPage = #"""
        <a href="userdetails.php?id=22440">nan</a> <a href="invite.php?id=22440">邀请</a>
        """#
        XCTAssertNil(NexusPHPAdapter.soleDetailURL(body: userPage, base: base,
                                                  hrefPattern: NexusPHPAdapter.defaultDetailHrefPattern),
                     "页里只有用户页链接时不该猜成新种子")
        let withSeed = #"""
        <a href="userdetails.php?id=22440">nan</a>
        <a href="details.php?id=98291&hit=1">刚发的种子</a>
        """#
        XCTAssertEqual(NexusPHPAdapter.soleDetailURL(body: withSeed, base: base,
                                                    hrefPattern: NexusPHPAdapter.defaultDetailHrefPattern),
                       "https://www.haidan.cc/details.php?id=98291&hit=1")
    }

    // MARK: - HD-Space：qBittorrent 5.x 的 tracker 接口参数

    func testQBTrackerAPIParamsCoverBothVersions() {
        // 5.x（WebAPI 2.11+）只认 hash，给 hashes 会回 400「缺少必需参数：hash」；4.x 用 infohash
        XCTAssertEqual(QBittorrent.trackerHashParams, ["hash", "infohash"])
        let f = QBittorrent.trackerPatchFields(hash: "abc", add: ["http://a/announce", "http://b/announce"])
        XCTAssertEqual(f["hash"], "abc")
        XCTAssertEqual(f["hashes"], "abc")
        XCTAssertEqual(f["urls"], "http://a/announce\nhttp://b/announce")
    }

    /// 实站（BOXSEND_LIVE=1）：真的读一次现有 tracker，参数名错了这里就会红
    func testLiveTrackerReadAgainstRealDownloader() throws {
        guard ProcessInfo.processInfo.environment["BOXSEND_LIVE"] != nil else {
            throw XCTSkip("实站验证需 BOXSEND_LIVE=1")
        }
        let support = NSHomeDirectory() + "/Library/Application Support/BoxSend"
        guard let cfg = AppConfig.load(path: support + "/boxsend.json"),
              cfg.downloader.type == .qbittorrent else { throw XCTSkip("没有本机配置") }
        let client = HTTPClient(cookies: CookieStore(), userAgent: "BoxSendTest")
        let qb = QBittorrent(client: client, baseURL: cfg.downloader.url,
                            username: cfg.downloader.username ?? "", password: cfg.downloader.password ?? "")
        _ = try qb.testConnection()
        let info = try client.get("\(qb.baseURL)/api/v2/torrents/info?limit=1", referer: cfg.downloader.url)
        guard let arr = try? JSONSerialization.jsonObject(with: info.data) as? [[String: Any]],
              let hash = arr.first?["hash"] as? String else {
            throw XCTSkip("下载器里没有种子")
        }
        XCTAssertNotNil(qb.trackerURLs(hash: hash), "读 tracker 失败：参数名或版本不匹配")
    }
}

/// 站点既没回链接、站内也查不到：只提醒，不静默
class SilentAdapterSearchNil: SiteAdapter {
    let site: SiteConfig
    let client: HTTPClient
    var override: SiteOverride? { nil }
    init(site: SiteConfig, client: HTTPClient) { self.site = site; self.client = client }
    func fetchTorrentList() throws -> [ReleaseInfo] { [] }
    func fetchDetail(detailURL: String) throws -> ReleaseInfo {
        ReleaseInfo(siteID: site.id, detailURL: detailURL, name: "T",
                    torrentName: "\(site.id).torrent", torrentURL: detailURL)
    }
    func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String) {
        (Data("seed".utf8), "\(site.id).torrent")
    }
    func searchExists(_ info: ReleaseInfo) throws -> String? { nil }
    func searchExists(_ info: ReleaseInfo, relaxed: Bool) throws -> String? { nil }
    var canPrecheckDuplicate: Bool { true }
    func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
        UploadOutcome(success: true, message: "发布成功", detailURL: nil)
    }

    // MARK: - 海胆：站点只回「发布成功」时别把用户主页当新种子链接

    /// 海胆的成功页里只有 userdetails.php?id=（本人 UID），它包含 "details.php?id="，
    /// 早先会被当成刚发的种子链接，推送时解析失败：「无法解析 HAIDAN 标题」
    func testSoleDetailURLIgnoresUserPages() throws {
        let base = URL(string: "https://www.haidan.cc/upload.php")!
        let userPage = #"""
        <a href="userdetails.php?id=22440">nan</a> <a href="invite.php?id=22440">邀请</a>
        """#
        XCTAssertNil(NexusPHPAdapter.soleDetailURL(body: userPage, base: base,
                                                  hrefPattern: NexusPHPAdapter.defaultDetailHrefPattern),
                     "页里只有用户页链接时不该猜成新种子")
        let withSeed = #"""
        <a href="userdetails.php?id=22440">nan</a>
        <a href="details.php?id=98291&hit=1">刚发的种子</a>
        """#
        XCTAssertEqual(NexusPHPAdapter.soleDetailURL(body: withSeed, base: base,
                                                    hrefPattern: NexusPHPAdapter.defaultDetailHrefPattern),
                       "https://www.haidan.cc/details.php?id=98291&hit=1")
    }

    // MARK: - HD-Space：qBittorrent 5.x 的 tracker 接口参数

    func testQBTrackerAPIParamsCoverBothVersions() {
        // 5.x（WebAPI 2.11+）只认 hash，给 hashes 会回 400「缺少必需参数：hash」；4.x 用 infohash
        XCTAssertEqual(QBittorrent.trackerHashParams, ["hash", "infohash"])
        let f = QBittorrent.trackerPatchFields(hash: "abc", add: ["http://a/announce", "http://b/announce"])
        XCTAssertEqual(f["hash"], "abc")
        XCTAssertEqual(f["hashes"], "abc")
        XCTAssertEqual(f["urls"], "http://a/announce\nhttp://b/announce")
    }

    /// 实站（BOXSEND_LIVE=1）：真的读一次现有 tracker，参数名错了这里就会红
    func testLiveTrackerReadAgainstRealDownloader() throws {
        guard ProcessInfo.processInfo.environment["BOXSEND_LIVE"] != nil else {
            throw XCTSkip("实站验证需 BOXSEND_LIVE=1")
        }
        let support = NSHomeDirectory() + "/Library/Application Support/BoxSend"
        guard let cfg = AppConfig.load(path: support + "/boxsend.json"),
              cfg.downloader.type == .qbittorrent else { throw XCTSkip("没有本机配置") }
        let client = HTTPClient(cookies: CookieStore(), userAgent: "BoxSendTest")
        let qb = QBittorrent(client: client, baseURL: cfg.downloader.url,
                            username: cfg.downloader.username ?? "", password: cfg.downloader.password ?? "")
        _ = try qb.testConnection()
        let info = try client.get("\(qb.baseURL)/api/v2/torrents/info?limit=1", referer: cfg.downloader.url)
        guard let arr = try? JSONSerialization.jsonObject(with: info.data) as? [[String: Any]],
              let hash = arr.first?["hash"] as? String else {
            throw XCTSkip("下载器里没有种子")
        }
        XCTAssertNotNil(qb.trackerURLs(hash: hash), "读 tracker 失败：参数名或版本不匹配")
    }
}
