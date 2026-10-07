import XCTest
@testable import BoxSendKit

/// 回归：猫（pterclub）转种标签。
/// 该站标签是拼音命名的独立复选框（zhongzi / jinzhuan / guanfang…），字段名里没有 tag，
/// 只能按复选框文案识别；源站详情页"标签"行（官方/中字/完结）是打标的权威依据。
final class PterTagTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func adapter(_ id: String, overrides: SiteOverride? = nil) -> NexusPHPAdapter {
        let s = SiteRegistry.prioritySites.first { $0.id == id }
            ?? SiteConfig(id: id, name: id, url: "https://example.net/",
                          framework: .nexusPHP, enabled: true, overrides: overrides ?? .nexusCN)
        return NexusPHPAdapter(site: s, client: HTTPClient(cookies: CookieStore(), userAgent: "box-send-test"))
    }

    private func pairs(_ fields: [HTTPClient.MultipartField]) -> Set<String> {
        Set(fields.map { "\($0.name)=\($0.value)" })
    }

    private func luckpt56812() throws -> ReleaseInfo {
        try adapter("luckpt").parseDetail(html: fixture("luckpt-56812-ajax.html"),
                                         detailURL: "https://pt.luckpt.de/details.php?id=56812&hit=1")
    }

    // MARK: - 源站"标签"行

    func testSourceTagRowParsed() throws {
        let info = try luckpt56812()
        XCTAssertEqual(info.sourceTags, ["官方", "中字", "完结"])
    }

    func testSourceTagsFeedCanonicalTags() throws {
        let info = try luckpt56812()
        let tags = QualityTokens.canonicalTags(info)
        XCTAssertTrue(tags.contains("chinese_sub"), "\(tags)")
        XCTAssertFalse(tags.contains("official"), "官方是源站概念，不该作为目标站标签外打：\(tags)")
        XCTAssertFalse(tags.contains("diy"), "\(tags)")
    }

    // MARK: - 猫上传页复选框

    func testPterCheckboxLabelsReadable() throws {
        let boxes = HTMLUtil.checkboxes(try fixture("pter-upload.html"))
        let dict = Dictionary(uniqueKeysWithValues: boxes.map { ($0.name, $0.label) })
        XCTAssertEqual(dict["zhongzi"], "中字")
        XCTAssertEqual(dict["guanfang"], "官方")
        XCTAssertEqual(dict["diy"], "DIY原盘")
    }

    func testPterPicksChineseSubButNotOfficial() throws {
        let info = try luckpt56812()
        let got = pairs(try adapter("pter").buildUploadFields(info, page: fixture("pter-upload.html")))
        XCTAssertTrue(got.contains("zhongzi=yes"), "未勾选中字：\(got.filter { $0.contains("zhong") })")
        XCTAssertFalse(got.contains("guanfang=yes"), "官种只有源站能标，转出去的种子不是官种")
        XCTAssertFalse(got.contains("jinzhuan=yes"), "不该勾禁转")
        XCTAssertFalse(got.contains("diy=yes"), "不该勾 DIY原盘")
        XCTAssertFalse(got.contains("ensub=yes"), "不该勾英字")
    }

    func testPterTagCheckboxMapCoversPinyinFields() {
        let map = SiteOverride.pter.tagCheckboxes ?? [:]
        XCTAssertEqual(map["chinese_sub"], "zhongzi")
        XCTAssertEqual(map["forbid"], "jinzhuan")
        XCTAssertEqual(map["official"], "guanfang")
    }

    // MARK: - 通用动态标签（无逐站配置时按文案识别）

    func testDynamicTagsMatchPinyinNamesByExactLabel() throws {
        let page = """
        <form action="takeupload.php">
        <input type="checkbox" name="zhongzi" value="yes" /><label for="zhongzi"><a class="t">中字</a></label>
        <input type="checkbox" name="remark" value="1" /><label for="remark">本页含中文字幕说明</label>
        </form>
        """
        let info = ReleaseInfo(siteID: "luckpt", detailURL: "https://x/details.php?id=1",
                               name: "Some Release 2015 1080p WEB-DL-GRP",
                               subtitle: "摇曳百合 第三季 [内封中字]")
        let got = pairs(try adapter("fakesite").buildUploadFields(info, page: page))
        XCTAssertTrue(got.contains("zhongzi=yes"), "按文案精确匹配应勾选 zhongzi：\(got)")
        XCTAssertFalse(got.contains("remark=1"), "字段名不含 tag 且文案非精确匹配，不应勾选")
    }

    func testDynamicTagsStillMatchTagNamedFieldsBySubstring() throws {
        let page = """
        <form action="takeupload.php">
        <input type="checkbox" name="tags[]" value="11" /><label for="t1">内嵌中字</label>
        </form>
        """
        let info = ReleaseInfo(siteID: "luckpt", detailURL: "https://x/details.php?id=1",
                               name: "Some Release 2015 1080p WEB-DL-GRP",
                               subtitle: "[内封中字]")
        let got = pairs(try adapter("fakesite").buildUploadFields(info, page: page))
        XCTAssertTrue(got.contains("tags[]=11"), "tag 命名字段仍按包含匹配：\(got)")
    }
}
