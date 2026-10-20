import XCTest
@testable import BoxSendKit

/// 套（TTG）的标题写法：站方把「.」当分隔符（站方示例标题没有点），
/// 直接发点会被换成空格（"DTS-HD MA 5.1" 存成 "MA 5 1"），点号要写成 "{@}"；
/// 副标题方括号是站方自己的排版，括号里的字幕说明该走 highlight 框。
final class TTGTitleTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func adapter(_ id: String) -> NexusPHPAdapter {
        NexusPHPAdapter(site: SiteRegistry.prioritySites.first { $0.id == id }!,
                        client: HTTPClient(cookies: CookieStore(), userAgent: "box-send-test"))
    }

    private func source() throws -> ReleaseInfo {
        try adapter("luckpt").parseDetail(html: try fixture("luckpt-46566.html"),
                                         detailURL: "https://pt.luckpt.de/details.php?id=46566")
    }

    private func fields(_ siteID: String, fixtureName: String) throws -> [(String, String)] {
        try adapter(siteID).buildUploadFields(source(), page: try fixture(fixtureName))
            .map { ($0.name, $0.value) }
    }

    private func first(_ fields: [(String, String)], _ name: String) -> String? {
        fields.first(where: { $0.0 == name })?.1
    }

    /// 实测页：标题里的点走站方保留写法，副标题只留片名，字幕说明进 highlight
    func testRealFormEscapesDotsAndSplitsSubtitle() throws {
        let f = try fields("ttg", fixtureName: "ttg-upload.html")
        XCTAssertEqual(first(f, "name"),
                       "Code Geass: Boukoku no Akito 1 - Yokuryuu wa Maiorita 2012 1080p Blu-ray AVC DTS-HD MA 5{@}1-LuckAni",
                       "点号写 {@}，否则站点存成「MA 5 1」")
        XCTAssertEqual(first(f, "subtitle"), "亡国的阿基德第1章：翼龙降临")
        XCTAssertEqual(first(f, "highlight"), "*内封中字")
    }

    /// 站内已有的种子名写的是 "{@}"，我们发的是 "."，复核重复时要能认出是同一条
    func testStoredDotEscapeStillMatchesForDuplicateCheck() throws {
        let stored = "Code Geass: Boukoku no Akito 1 - Yokuryuu wa Maiorita 2012 1080p Blu-ray "
            + "AVC DTS-HD MA 5{@}1-LuckAni"
        let mine = try source().name
        XCTAssertTrue(NexusPHPAdapter.searchNamesMatch(stored, mine), "已存在种子要能命中")
        XCTAssertNotNil(NexusPHPAdapter.wordQuery(mine))
        XCTAssertFalse(NexusPHPAdapter.wordQuery(mine)!.contains("."), "查询词不带标点，不受写法影响")
    }

    /// 没有配 titleDotAs 的站不受影响
    func testOtherSitesKeepPlainDots() throws {
        let f = try fields("wtsakura", fixtureName: "wtsakura-upload.html")
        XCTAssertTrue((first(f, "name") ?? "").contains("DTS-HD MA 5.1"),
                      "冬樱的标题照旧写 5.1，实际：\(first(f, "name") ?? "-")")
    }

    func testSplitSubtitleNoteCases() {
        XCTAssertEqual(NexusPHPAdapter.splitSubtitleNote("亡国的阿基德第1章：翼龙降临 [内封中字]").main,
                       "亡国的阿基德第1章：翼龙降临")
        XCTAssertEqual(NexusPHPAdapter.splitSubtitleNote("亡国的阿基德第1章：翼龙降临 [内封中字]").note, "*内封中字")
        XCTAssertEqual(NexusPHPAdapter.splitSubtitleNote("摇曳百合 第三季 【全12集】").note, "*全12集")
        XCTAssertNil(NexusPHPAdapter.splitSubtitleNote("旋风管家 第一季").note, "没有括号就不动")
        XCTAssertEqual(NexusPHPAdapter.splitSubtitleNote("神之山岭 [内封简繁字幕]").note, "*内封简繁字幕",
                       "站方示例的 highlight 写法带 *，缺了才补")
    }

    /// 站方限长的字段按 maxlength 裁（套的副标题 maxlength=55）
    func testSubtitleRespectsFieldMaxlength() {
        let long = String(repeating: "字", count: 60)
        let page = """
        <form action="takeupload.php"><input name="name" />
        <input type="text" name="subtitle" maxlength='55' />
        <input type="text" name="highlight" /></form>
        """
        let info = ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=1",
                               name: "Some Movie 2013 1080p Blu-ray AVC DTS-HD MA 5.1-LuckAni",
                               kind: .movie, sourceName: "LuckPT")
        var copy = info
        copy.subtitle = long
        XCTAssertEqual(NexusPHPAdapter.inputMaxlength(page, name: "subtitle"), 55, "先确认读到了站方限长")
        let f = adapter("ttg").buildUploadFields(copy, page: page).map { ($0.name, $0.value) }
        XCTAssertEqual(first(f, "subtitle")?.count, 55)
        XCTAssertEqual(first(f, "name"),
                       "Some Movie 2013 1080p Blu-ray AVC DTS-HD MA 5{@}1-LuckAni")
    }
}
