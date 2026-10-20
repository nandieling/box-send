import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import BoxSendKit

/// 海胆实测（LuckPT 46566 亡国的阿基德第1章）：详情页把同片三个版本并列在一页里，
/// 排在最前的是 2020 年别人发的 BDRip。当时推给下载器的就是这条 28902，
/// 而站内本次这条是 80106。「已存在」链接必须按发布名认，不能取页面第一条。
final class HaidanDuplicateLinkTests: XCTestCase {
    private static let ours =
        "Code Geass: Boukoku no Akito 1 - Yokuryuu wa Maiorita 2012 1080p Blu-ray AVC DTS-HD MA 5.1-LuckAni"
    /// 站内那条旧标题只多了个 2Audios 备注
    private static let oursRetitled =
        "Code Geass: Boukoku no Akito 1 - Yokuryuu wa Maiorita 2012 1080p Blu-ray AVC DTS-HD MA 5.1 2Audios-LuckAni"
    /// 同片另一版本（2020 年 VCB-Studio 压制）
    private static let otherVersion =
        "Code Geass Akito The Exiled 2012 BDRip 1080 TV Series VCB-S&philosophy-raws"

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func haidanSite() -> SiteConfig {
        SiteRegistry.effectiveSite(SiteConfig(id: "haidan", name: "海胆", url: "https://www.haidan.cc/",
                                              framework: .haidan, enabled: true))
    }

    private func client(_ handler: @escaping (URLRequest) -> HTTPClient.Response) -> HTTPClient {
        let c = HTTPClient(cookies: CookieStore(), userAgent: "boxsend-test")
        c.performOverride = { req in handler(req) }
        return c
    }

    private func resp(_ body: String) -> HTTPClient.Response {
        HTTPClient.Response(status: 200, data: Data(body.utf8), headers: [:],
                            finalURL: "https://www.haidan.cc/x")
    }

    private var release: ReleaseInfo {
        ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=46566",
                    name: Self.ours, kind: .movie, sourceName: "LuckPT")
    }

    /// 并列的版本块要逐个解析出 id 与发布名
    func testGroupPageListsEveryVersion() throws {
        let titles = try HaidanAdapter(site: haidanSite(), client: client { _ in self.resp("") })
            .torrentTitles(on: try fixture("haidan-details-codegeass-group.html"))
        XCTAssertEqual(titles["28902"], Self.otherVersion)
        XCTAssertEqual(titles["75407"], Self.oursRetitled)
        XCTAssertEqual(titles["80106"], Self.ours)
    }

    /// 页面并列多条种子时：站点给的链接指向别的版本也要能改认回本次这条
    func testDuplicateOutcomePicksOurVersionAmongListings() throws {
        let body = try fixture("haidan-details-codegeass-group.html")
        let titles = HaidanAdapter(site: haidanSite(), client: client { _ in self.resp("") })
            .torrentTitles(on: body)
        let dup = NexusPHPAdapter.duplicateOutcome(body: body, uploadURL: "https://www.haidan.cc/takeupload.php",
                                                  detailPattern: NexusPHPAdapter.defaultDetailHrefPattern,
                                                  releaseName: Self.ours, torrentTitles: titles)
        XCTAssertEqual(dup?.detailURL, "https://www.haidan.cc/details.php?id=80106",
                       "名称严格对得上的那条优先，不能取排在最前的 28902")
    }

    /// 页面上没有本次这条时不猜：留给调用方回站内按名重查
    func testDuplicateOutcomeRefusesToGuessForeignRelease() {
        let body = "<a href=\"download.php?id=1&passkey=x\">d</a><a href=\"download.php?id=2&passkey=x\">d</a>"
        XCTAssertNil(NexusPHPAdapter.duplicatePageTorrentID(body, releaseName: Self.ours),
                     "页面并列两条又认不出名字时不能瞎取一条")
        XCTAssertEqual(NexusPHPAdapter.duplicatePageTorrentID(body, releaseName: Self.ours),
                       NexusPHPAdapter.duplicatePageTorrentID(body, releaseName: Self.ours))
        XCTAssertEqual(NexusPHPAdapter.duplicatePageTorrentID(
            "<a href=\"download.php?id=7&passkey=x\">d</a>", releaseName: Self.ours), "7",
            "页面只有一条种子时它就是站点提示的那条")
    }

    /// BDRip 与 Blu-ray 是两个版本：光看 medium() 认不出（BDRip 也归碟片系，且没写 1080p）
    func testDiscFormSeparatesRipFromDisc() throws {
        XCTAssertTrue(NexusPHPAdapter.conflictingVersion(Self.ours, Self.otherVersion),
                      "本次是原盘 1080p AVC，站内那条是 BDRip，不能算同一条种子")
        XCTAssertFalse(NexusPHPAdapter.conflictingVersion(Self.ours, Self.oursRetitled),
                       "同版本多个备注不算冲突")
        XCTAssertEqual(NexusPHPAdapter.discForm(Self.ours), "raw")
        XCTAssertEqual(NexusPHPAdapter.discForm(Self.otherVersion), "pressed")
    }

    /// 海胆结果行不放详情链接（只有 details.php?group_id=…&torrent_id=…），
    /// 所以只能拿行内的 download.php?id= 逐条复核
    func testSearchPageGivesOnlyTorrentIDsToWorkWith() throws {
        let page = try fixture("haidan-search-codegeass-2rows.html")
        XCTAssertTrue(NexusPHPAdapter.detailAnchors(
            page, hrefPattern: NexusPHPAdapter.defaultDetailHrefPattern).isEmpty,
            "这条结果页没有可用的详情链接，应退到按 id 复核")
        XCTAssertEqual(NexusPHPAdapter.resultTorrentIDs(page), ["75407", "80106"])
        XCTAssertEqual(NexusPHPAdapter.resultTorrentIDs(page, limit: 1), ["75407"], "限制条数别把站点打爆")
    }

    /// 端到端：检索页拿到两个版本 id，逐条打开复核，返回本次这条 80106
    func testSearchExistsPicksExactVersion() throws {
        let search = try fixture("haidan-search-codegeass-2rows.html")
        let group = try fixture("haidan-details-codegeass-group.html")
        var seen: [String] = []
        let adapter = HaidanAdapter(site: haidanSite(), client: client { req in
            let url = req.url!.absoluteString
            seen.append(url)
            return self.resp(url.contains("details.php?id=") ? group : search)
        })
        XCTAssertEqual(try adapter.searchExists(release), "https://www.haidan.cc/details.php?id=80106")
        XCTAssertEqual(adapter.duplicateHitTitle, Self.ours)
        XCTAssertTrue(seen.filter { $0.contains("details.php?id=") }.count <= 3, "复核次数要有上限")
    }
}
