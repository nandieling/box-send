import XCTest
@testable import BoxSendKit

/// 题材标签的文案匹配：站点选项文案相近不等于同一题材。
/// 依据源站 LuckPT 46561《娜娜2》（豆瓣类别「剧情 / 爱情」）转唐PT：
/// 唐PT 的标签列表里有「情色」(27) 而没有「爱情」，以前 romance 的关键词把「情色」也算进去，
/// 爱情片就被勾成了情色。
final class GenreTagLabelTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func source() throws -> ReleaseInfo {
        let luck = SiteRegistry.prioritySites.first { $0.id == "luckpt" }!
        return try NexusPHPAdapter(site: luck, client: HTTPClient(cookies: CookieStore(), userAgent: "t"))
            .parseDetail(html: try fixture("luckpt-46561-webddp.html"),
                         detailURL: "https://pt.luckpt.de/details.php?id=46561")
    }

    private func tangptTags(_ info: ReleaseInfo) throws -> [String] {
        let site = SiteRegistry.prioritySites.first { $0.id == "tangpt" }!
        return try NexusPHPAdapter(site: site, client: HTTPClient(cookies: CookieStore(), userAgent: "t"))
            .buildUploadFields(info, page: try fixture("tangpt-upload.html"))
            .filter { $0.name == "tags[4][]" }.map { $0.value }
    }

    func testRomanceDoesNotCheckEroticBox() throws {
        let info = try source()
        XCTAssertEqual(info.genre, "剧情 / 爱情")
        XCTAssertEqual(QualityTokens.genreTags(info.genre), ["drama", "romance"])
        let tags = try tangptTags(info)
        XCTAssertFalse(tags.contains("27"), "本站的情色复选框不该被爱情片勾上，实际勾了 \(tags)")
        XCTAssertTrue(tags.contains("6"), "中字标签照旧要勾")
    }

    func testEroticGenreChecksEroticBox() throws {
        var info = try source()
        info.genre = "剧情 / 情色"
        XCTAssertEqual(QualityTokens.genreTags(info.genre), ["drama", "erotic"])
        XCTAssertTrue(try tangptTags(info).contains("27"), "源站类别写明情色，才勾本站的情色标签")
    }

    func testGenreVocabularySeparatesRomanceAndErotic() {
        XCTAssertEqual(QualityTokens.genreTags("爱情"), ["romance"])
        XCTAssertEqual(QualityTokens.genreTags("伦理"), ["erotic"])
        XCTAssertEqual(QualityTokens.genreTags("恐怖 / 情色"), ["horror", "erotic"])
    }
}
