import XCTest
@testable import BoxSendKit

/// 织梦实测（LuckPT 43834 小长门有希的消失 S01 BD Remux）：站点回「种子已存在」，
/// 但「已存在」页刮到的第一条详情链接是 115285（WEB-DL，同剧另一版本），
/// 站内真正已有的那条是 382434（BD Remux）。拿错链接会把别的种子的 tracker 推给下载器。
final class DuplicateLinkVerifyTests: XCTestCase {
    private let client = HTTPClient(cookies: CookieStore(), userAgent: "BoxSendTest")

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private var zmpt: SiteConfig {
        SiteConfig(id: "zmpt", name: "织梦", url: "https://zmpt.cc/", framework: .nexusPHP, enabled: true)
    }

    /// 本次要转的发布名（源站详情标题）
    private let ours = "Nagato Yuki-chan no Shoshitsu S01 2015.1080p Blu-ray Remux AVC AC3-LuckAni"

    func testExistingPageLinkNameIsParsed() throws {
        let info = try NexusPHPAdapter(site: zmpt, client: client).parseDetail(
            html: try fixture("zmpt-details-115285-webdl.html"),
            detailURL: "https://zmpt.cc/details.php?id=115285")
        XCTAssertEqual(info.name,
                       "The Disappearance of Nagato Yuki-chan S01 2015 1080p CR WEB-DL H.264 AAC-FROGWeb",
                       "验证链接前先要能解析出页面上的发布名")
    }

    func testWEBDLPageConflictsWithOurBlurayRemux() throws {
        let page = try fixture("zmpt-details-115285-webdl.html")
        let found = try NexusPHPAdapter(site: zmpt, client: client)
            .parseDetail(html: page, detailURL: "https://zmpt.cc/details.php?id=115285").name
        XCTAssertTrue(NexusPHPAdapter.conflictingVersion(ours, found),
                      "WEB-DL / H.264 / AAC 与本次的 BD Remux / AVC / AC3 明显是两个版本")
    }

    func testSameReleaseRetitledDoesNotConflict() {
        // 站内那条真种子的标题只是把 Blu-ray 写成 BluRay、多了「2.0 3Audios」
        let real = "Nagato Yuki-chan no Shoshitsu S01 2015 1080p BluRay Remux AVC AC3 2.0 3Audios-LuckAni"
        XCTAssertFalse(NexusPHPAdapter.conflictingVersion(ours, real), "同版本换写法不该判成冲突")
        XCTAssertFalse(NexusPHPAdapter.conflictingVersion(ours, "小长门有希的消失 第一季"),
                       "认不出版本信息时不下结论，维持站点给的链接")
    }

    /// 织梦的「该种子已存在！」页把已有种子整个展开在提示下：它的下载链接指向 382434，
    /// 而页面上唯一的 details 链接是同剧另一版本 115285——必须按下载链接认种子
    func testDuplicatePagePrefersExistingTorrentDownloadLink() throws {
        let body = try fixture("zmpt-duplicate-page.html")
        let dup = NexusPHPAdapter.duplicateOutcome(
            body: body, uploadURL: "https://zmpt.cc/takeupload.php",
            detailPattern: NexusPHPAdapter.defaultDetailHrefPattern)
        XCTAssertEqual(dup?.detailURL, "https://zmpt.cc/details.php?id=382434",
                       "要指向站点提示的那条种子，不是「同剧其他种子」列表里的 115285")
        XCTAssertFalse((dup?.detailURL ?? "").contains("115285"))
    }

    /// 海胆的成功页是种子详情页本身，页面上没有指向自己的 details 链接：
    /// 种子 id 只在 download.php?id=N / edit.php?id=N 上（实测 79964）
    func testSuccessPageRevealsNewTorrentID() throws {
        let body = try fixture("haidan-upload-success.html")
        XCTAssertEqual(NexusPHPAdapter.pageTorrentID(body), "79964",
                       "要能从海胆的发布成功页认出新种子 id，否则推送下载器找不回这条种子")
        XCTAssertFalse((try fixture("zmpt-duplicate-page.html")).isEmpty)
        XCTAssertEqual(NexusPHPAdapter.pageTorrentID(try fixture("zmpt-duplicate-page.html")), "382434")
    }

    /// 海胆的检索结果行不写发布名（只有「[全集] Blu-ray / H.264 …」拼装文案），
    /// 名称匹配判不了；结果页只有一条种子时按 download.php?id= 认它，再回详情页复核
    func testSingleSearchRowIsUsedAsLastResort() throws {
        XCTAssertEqual(NexusPHPAdapter.singleResultTorrentID(try fixture("haidan-search-codegeass.html")), "79964")
        XCTAssertNil(NexusPHPAdapter.singleResultTorrentID(
            "<a href=\"download.php?id=1\">a</a><a href=\"download.php?id=2\">b</a>"),
            "结果不止一条时不能瞎猜")
        XCTAssertNil(NexusPHPAdapter.singleResultTorrentID("<p>没有种子</p>"))
    }

    /// 丢掉错链接后，流水线会回站内按名重查（relaxed）：结果页那一条就是真种子 382434
    func testRelaxedLookupFindsTheRealExistingSeed() throws {
        let html = try fixture("zmpt-search-nagato.html")
        let hit = NexusPHPAdapter.searchNameInResults(
            html: html, releaseName: ours, base: URL(string: "https://zmpt.cc/torrents.php")!,
            hrefPattern: NexusPHPAdapter.defaultDetailHrefPattern, relaxed: true)
        XCTAssertNotNil(hit, "按词元放宽后要能在结果页认出截断/改写过的同名种子")
        XCTAssertTrue(hit?.href.contains("382434") ?? false, "应指向 382434，实际 \(hit?.href ?? "nil")")
    }
}
