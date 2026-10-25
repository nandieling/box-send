import XCTest
@testable import BoxSendKit

/// 站点换域名 + 「跳到站内种子页」那条链接：都是界面要点得到、错了很显眼的小东西，
/// 但都得有测试兜着，免得下次改注册表或改事件时悄悄丢掉。
final class DolbyDomainAndSeedLinkTests: XCTestCase {

    // MARK: 1. 杜比搬到 uhddolby.com

    func testDolbyBuiltinsPointToNewDomain() {
        guard let dolby = SiteRegistry.prioritySites.first(where: { $0.id == "hddolby" }) else {
            return XCTFail("站点表里没有杜比")
        }
        XCTAssertTrue(dolby.url.hasPrefix("https://www.uhddolby.com/"), dolby.url)
    }

    /// 老配置里存的还是 www.hddolby.com：读取时按 id 认回新域名，用户不用重填
    func testLegacyDolbyHostIsRelocated() {
        var saved = SiteConfig(id: "hddolby", name: "杜比", url: "https://www.hddolby.com/",
                               framework: .nexusPHP, enabled: true)
        XCTAssertEqual(SiteRegistry.effectiveSite(saved).url, "https://www.uhddolby.com/")
        // 用户自己填的第三方镜像不该被改写
        saved.url = "https://mirror.example/"
        XCTAssertEqual(SiteRegistry.effectiveSite(saved).url, "https://mirror.example/")
    }

    /// 站点分组里显示的网址来自配置文件：光在读取时改写不够，那份配置本身也得换过来
    func testStoredLegacyURLIsRewritten() throws {
        var cfg = AppConfig.template()
        cfg.sourceSites = [SiteConfig(id: "hddolby", name: "杜比", url: "https://www.hddolby.com/",
                                      framework: .nexusPHP, enabled: true)]
        XCTAssertEqual(cfg.mergedWithRoster().site("hddolby")?.url, "https://www.uhddolby.com/")
        // 用户自己填的第三方镜像不动
        cfg.sourceSites[0].url = "https://mirror.example/"
        XCTAssertEqual(cfg.mergedWithRoster().site("hddolby")?.url, "https://mirror.example/")
    }

    /// 改写要落盘：否则下次启动还是老地址，界面上永远显示旧域名
    func testRewrittenURLIsSavedBack() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("boxsend-relocate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var cfg = AppConfig.template()
        cfg.sourceSites = [SiteConfig(id: "hddolby", name: "杜比", url: "https://www.hddolby.com/",
                                      framework: .nexusPHP, enabled: true)]
        let file = dir.appendingPathComponent("boxsend.json")
        try JSONEncoder().encode(cfg).write(to: file)

        XCTAssertNotNil(AppConfig.load(path: file.path))
        let saved = String(data: try Data(contentsOf: file), encoding: .utf8) ?? ""
        XCTAssertTrue(saved.contains("www.uhddolby.com"), saved.prefix(200).description)
        XCTAssertFalse(saved.contains("www.hddolby.com"), saved.prefix(200).description)
    }

    // MARK: 2. 逐站事件带站内链接

    /// 上传前查重命中：卡片上那句「站内已有该种子（别人先发或此前已发）」去掉，
    /// 但详情里要留站内那条的标题与链接，事件本身也得带 url（界面靠它放跳转按钮）
    func testPrecheckDuplicateEventCarriesURL() throws {
        var cfg = AppConfig.template()
        cfg.sourceSites = [SiteConfig(id: "src", name: "src", url: "https://src.invalid/",
                                      framework: .nexusPHP, enabled: true),
                           SiteConfig(id: "pter", name: "猫", url: "https://pterclub.net/",
                                      framework: .nexusPHP, enabled: true)]
        cfg.targetSites = ["pter"]
        let pipe = ReseedPipeline(config: cfg, cookies: CookieStore(),
                                 state: StateStore(dataDir: "/tmp/boxsend-link-\(UUID().uuidString)"),
                                 downloader: LinkDownloader())
        pipe.adapterFactory = { s, client, _ -> any SiteAdapter in
            FoundOnSite(site: s, client: client)
        }
        var events: [ReseedPipeline.SiteStatus] = []
        var o = ReseedPipeline.Options()
        o.onSiteEvent = { events.append($0) }
        o.onSitePush = { events.append($0) }
        _ = try pipe.run(detailURL: "https://src.invalid/details.php?id=1",
                         sourceSiteID: "src", opts: o)

        let exists = events.first { $0.text == "种子已存在，跳过" }
        guard let exists else { return XCTFail("没有「种子已存在，跳过」事件：\(events.map(\.text))") }
        XCTAssertTrue(exists.url.contains("details.php?id=768037"), exists.url)
        XCTAssertFalse(exists.detail.contains("站内已有该种子（别人先发或此前已发）"), exists.detail)
        XCTAssertTrue(exists.detail.contains("https://pterclub.net/details.php?id=768037"), exists.detail)

        let pushed = events.first { $0.text == "推送已有种子" }
        guard let pushed else { return XCTFail("没有「推送已有种子」事件：\(events.map(\.text))") }
        XCTAssertTrue(pushed.url.contains("details.php?id=768037"), pushed.url)
    }
}

/// 站内一定查得到、且不给上传机会的假站
private final class FoundOnSite: SiteAdapter {
    let site: SiteConfig
    let client: HTTPClient
    var override: SiteOverride? { site.overrides }
    init(site: SiteConfig, client: HTTPClient) { self.site = site; self.client = client }
    var canPrecheckDuplicate: Bool { true }
    var duplicateHitTitle: String? { "站内已有那条的标题" }
    func fetchTorrentList() throws -> [ReleaseInfo] { [] }
    func fetchDetail(detailURL: String) throws -> ReleaseInfo {
        ReleaseInfo(siteID: site.id, detailURL: detailURL, name: "T",
                    torrentName: "\(site.id).torrent", torrentURL: detailURL)
    }
    func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String) {
        (Data("seed".utf8), "\(site.id).torrent")
    }
    func searchExists(_ info: ReleaseInfo) throws -> String? {
        site.id == "pter" ? "details.php?id=768037" : nil
    }
    func torrentOwnership(detailURL: String, uploadedAt: Date?) -> TorrentOwnership { .theirs }
    func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
        XCTFail("站内已查到就不该再上传")
        return UploadOutcome(success: false, message: "不该上传", detailURL: nil)
    }
}

private final class LinkDownloader: Downloader {
    var items: [String] = []
    func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                    skipChecking: Bool, upLimit: Int64) throws -> AddTorrentResult {
        items.append(filename)
        return AddTorrentResult(id: "hash")
    }
    func testConnection() throws -> String { "fake" }
}
