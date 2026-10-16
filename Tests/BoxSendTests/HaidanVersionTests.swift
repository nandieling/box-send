import XCTest
@testable import BoxSendKit

/// 海把一个影片的每个版本并列在同一张详情页里（每个 torrent-wrap 一块）。
/// 实测黑礁 S01 Remux（本次发的 80033）排在 2020 年的 BDrip（1036）后面，
/// 整页去读标题/发布时间会读到 1036，刚发的新种被误判「不是本次发布的」，
/// 推给下载器的是同页另一条种子。所以解析与归属判定都要先裁到本条那一块。
final class HaidanVersionTests: XCTestCase {

    private var page: String!
    private var adapter: HaidanAdapter!

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("detail-haidan-two-versions.html")
        page = try String(contentsOf: url, encoding: .utf8)
        let site = SiteConfig(id: "haidan", name: "HAIDAN", url: "https://www.haidan.cc/",
                              framework: .haidan, enabled: true, overrides: .haidan)
        adapter = HaidanAdapter(site: SiteRegistry.effectiveSite(site),
                                client: HTTPClient(cookies: CookieStore(), userAgent: "BoxSendTest"))
    }

    private func stamped(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)!
    }

    /// 本次这条（80033）那一段：只该有自己的下载链接和发布时间
    func testBlockIsolatesOwnVersion() throws {
        let block = try XCTUnwrap(HaidanAdapter.torrentBlock(forID: "80033", in: page))
        XCTAssertTrue(block.contains("download.php?id=80033"))
        XCTAssertFalse(block.contains("download.php?id=1036"), "不该把同页另一条也圈进来")
        // 发布时间认第一条：本块里排在前面的就是自己那条（评论区里的旧日期不算）
        XCTAssertEqual(NexusPHPAdapter.pageCreatedAt(block), stamped("2026-10-16 15:09:02"))
        XCTAssertNil(HaidanAdapter.torrentBlock(forID: "999999", in: page), "页面上没这个 id 就返回 nil")
    }

    /// 解析本条：标题是 Remux 那条，下载链接也指本条
    func testParseDetailScopesToRequestedTorrent() throws {
        let info = try adapter.parseDetail(html: page,
                                          detailURL: "https://www.haidan.cc/details.php?id=80033&hit=1")
        XCTAssertEqual(info.name, "Black Lagoon S01 2006 1080p Blu-ray Remux AVC LPCM 2.0-LuckAni")
        XCTAssertTrue(info.torrentURL.contains("download.php?id=80033&passkey="),
                      "下载链接: \(info.torrentURL)")
    }

    /// 同一页另一条（1036）解析出来是它自己
    func testParseDetailSamePageOtherVersion() throws {
        let info = try adapter.parseDetail(html: page,
                                          detailURL: "https://www.haidan.cc/details.php?id=1036&hit=1")
        XCTAssertTrue(info.name.contains("BDrip"), "同一页另一条版本: \(info.name)")
        XCTAssertTrue(info.torrentURL.contains("download.php?id=1036&passkey="))
    }

    /// 页面上找不到这个 id（改版、单块页）时退回整页，别解析失败
    func testParseDetailFallsBackToWholePage() throws {
        let info = try adapter.parseDetail(html: page,
                                          detailURL: "https://www.haidan.cc/details.php?id=999999&hit=1")
        XCTAssertFalse(info.name.isEmpty)
    }

    /// 刚发一分钟就回页面看归属：本条那一段有我自己的编辑入口，认成本次的
    func testOwnershipOfOurVersionRightAfterUpload() {
        let block = HaidanAdapter.torrentBlock(forID: "80033", in: page)!
        let now = stamped("2026-10-16 15:10:00")
        XCTAssertEqual(NexusPHPAdapter.pageOwnership(block, torrentID: "80033", ourHash: nil, now: now),
                       .ours)
        // 整页（改前的读法）会先撞上 2020 年那条的发布时间，判成别人的
        XCTAssertEqual(NexusPHPAdapter.pageOwnership(page, torrentID: "80033", ourHash: nil, now: now),
                       .theirs)
    }

    /// 同页那条 2020 年的种子：发布时间比本次上传早六年，判别人的
    func testOwnershipOfOlderVersion() {
        let block = HaidanAdapter.torrentBlock(forID: "1036", in: page)!
        XCTAssertEqual(NexusPHPAdapter.pageOwnership(block, torrentID: "1036", ourHash: nil,
                                                    now: stamped("2026-10-16 15:10:00")), .theirs)
    }

    /// 重跑时的归属判定同样只认本条那一段
    func testReseedOwnershipScoped() {
        let when = stamped("2026-10-16 15:09:02")
        XCTAssertEqual(NexusPHPAdapter.reseedOwnership(HaidanAdapter.torrentBlock(forID: "80033", in: page)!,
                                                      torrentID: "80033", uploadedAt: when), .ours)
        XCTAssertEqual(NexusPHPAdapter.reseedOwnership(HaidanAdapter.torrentBlock(forID: "1036", in: page)!,
                                                      torrentID: "1036", uploadedAt: when), .theirs)
    }

    /// 「响应页给的链接指向另一部片子」必须能判出来（那次指到爱宠大机密2）
    func testConflictingVersionRejectsUnrelatedMovie() {
        XCTAssertTrue(NexusPHPAdapter.conflictingVersion(
            "Black Lagoon S01 2006 1080p Blu-ray Remux AVC LPCM 2.0-LuckAni",
            "The Secret Life of Pets 2016 UHD BluRay 2160p MultiAudio TrueHD Atmos 7.1 x265 10bit HDR-BeiTai"))
    }
}
