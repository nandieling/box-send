import XCTest
@testable import BoxSendKit

/// HD-Space（xbtit 皮肤）搜索结果页查重：
/// 结果行是 <a href="index.php?page=torrent-details&amp;id=<40位sha1>">名称</a>，
/// & 被转义、id 是 sha1（40 位）而非 32 位，且开标签属性里带 ">"（onmouseover overlib）。
final class GazelleSearchTests: XCTestCase {

    private func fixture(_ name: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures").appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8) else {
            XCTFail("fixture 缺失: \(name)"); return ""
        }
        return s
    }

    private var html: String { fixture("hdspace-search.html") }
    private var base: URL { URL(string: "https://hd-space.org/")! }

    /// 属性值中的 ">" 不能截断开标签，否则锚文本会混进 onmouseover 残片
    func testAnchorTextIgnoresAngleBracketInsideAttributes() {
        let anchors = HTMLUtil.anchorText(html, hrefPattern: GazelleAdapter.detailHrefPattern)
        let named = anchors.filter { $0.text.count >= 8 }
        XCTAssertGreaterThanOrEqual(named.count, 5, "应解析出结果行的名称锚点")
        // 站点展示名会把 "." "-" 换成空格，这里只要求没有属性残片
        XCTAssertTrue(named.contains { $0.text == "Naruto Shippuden S20 H264 MPEG 4 AVC" },
                      "锚文本应干净，实际: \(named.prefix(2).map(\.text))")
    }

    func testSearchExistsMatchesRealResultRow() {
        let hit = NexusPHPAdapter.searchNameInResults(
            html: html, releaseName: "Naruto Shippuden S20 H264 MPEG-4 AVC",
            base: base, hrefPattern: GazelleAdapter.detailHrefPattern)
        let url = HTMLUtil.resolveURL(hit?.href ?? "", against: base)
        XCTAssertEqual(url, "https://hd-space.org/index.php?page=torrent-details&id=4b932d4e36c08f34e69d86211cc6b0f698e1dd46")
    }

    /// 站点用下划线/点分写名称时，归一化后仍应命中
    func testSearchExistsMatchesDottedVariant() {
        let hit = NexusPHPAdapter.searchNameInResults(
            html: html, releaseName: "Naruto_Shippuden_S20_H264_MPEG-4_AVC",
            base: base, hrefPattern: GazelleAdapter.detailHrefPattern)
        XCTAssertNotNil(hit)
    }

    func testSearchExistsNoFalsePositive() {
        let none = NexusPHPAdapter.searchNameInResults(
            html: html, releaseName: "Yuru Yuri S03 2015.1080p BluRay Remux AVC LPCM 2.0-LuckAni",
            base: base, hrefPattern: GazelleAdapter.detailHrefPattern)
        XCTAssertNil(none)
    }
}

extension GazelleSearchTests {
    /// xbtit 用 info_hash 当种子 id：上传响应不给链接时也能拼出详情页（HD-Space 实测有效）
    func testInfoHashDerivedDetailURL() throws {
        let torrent = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/food.torrent"))
        let hash = try XCTUnwrap(Bencode.infoHash(torrent))
        XCTAssertEqual(hash.count, 40)
        let cfg = SiteConfig(id: "hdspace", name: "HD-Space", url: "https://hd-space.org/",
                             framework: .gazelle, enabled: true, overrides: .hdspace)
        let adapter = GazelleAdapter(site: cfg, client: HTTPClient(cookies: CookieStore(), userAgent: "ua"))
        XCTAssertEqual(adapter.infoHashDetailURL(torrent),
                       "https://hd-space.org/index.php?page=torrent-details&id=" + hash)
    }
}

extension GazelleSearchTests {
    /// 肉丝（PeerGo）查重关键词：多词会被当整短语匹配不到，只给发布名首个词
    func testPeerGoSearchKeyword() {
        XCTAssertEqual(PeerGoAdapter.searchKeyword("Yuru Yuri S03 2015.1080p BluRay Remux AVC LPCM 2.0-LuckAni"), "Yuru")
        XCTAssertEqual(PeerGoAdapter.searchKeyword("凡人修仙传 全30集"), "凡人修仙传")
        // 版本号一类短词做不了搜索词时退回截断
        XCTAssertEqual(PeerGoAdapter.searchKeyword("S03"), "S03")
        XCTAssertNil(PeerGoAdapter.searchKeyword("S2"))
    }
}
