import XCTest
@testable import BoxSendKit

/// 「批量转种」页的源站引用（可选项）：文本置顶并用引用包裹
final class SourceQuoteTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// LuckPT 56812：源站打了「官方」标签，默认会自动加一句转载自致谢
    private func source(quote: String = "") throws -> ReleaseInfo {
        let luck = SiteRegistry.prioritySites.first { $0.id == "luckpt" }!
        var info = try NexusPHPAdapter(site: luck, client: HTTPClient(cookies: CookieStore(), userAgent: "t"))
            .parseDetail(html: try fixture("luckpt-56812-ajax.html"),
                         detailURL: "https://pt.luckpt.de/details.php?id=56812&hit=1")
        info.extraQuote = quote
        return info
    }

    private func descr(_ siteID: String, _ info: ReleaseInfo) throws -> String? {
        let s = SiteRegistry.prioritySites.first { $0.id == siteID }!
        let a = NexusPHPAdapter(site: s, client: HTTPClient(cookies: CookieStore(), userAgent: "t"))
        return try a.buildUploadFields(info, page: try fixture("\(siteID)-upload.html"))
            .first { $0.name == "descr" }?.value
    }

    private let manual = "转载自LuckPT，感谢发布者。原盘来自U2:摇曳百合 第三季\n字幕来自华盟字幕社"

    func testManualQuoteOnTopOfBBCodeDescr() throws {
        let d = try descr("crabpt", source(quote: manual))
        XCTAssertNotNil(d)
        XCTAssertTrue(d!.hasPrefix("[quote]\n转载自LuckPT，感谢发布者。原盘来自U2:摇曳百合 第三季\n字幕来自华盟字幕社\n[/quote]\n"),
                      "手填引用应原样置顶包裹，实际开头: \(d!.prefix(120))")
    }

    func testManualQuoteReplacesAutoOfficialPrefix() throws {
        let d = try descr("crabpt", source(quote: manual))!
        XCTAssertEqual(d.components(separatedBy: "感谢发布者").count - 1, 1,
                       "手填引用应取代自动官种致谢，不该出现两句转载自")
    }

    func testNoManualQuoteKeepsAutoPrefix() throws {
        let d = try descr("crabpt", source())!
        XCTAssertTrue(d.hasPrefix("[quote]\n转载自LuckPT，感谢发布者。\n[/quote]\n"),
                      "未勾选时保持原有行为（官种自动注明出处），实际开头: \(d.prefix(120))")
    }

    /// cmct 的 descr 实为「附加信息」：手填引用直接作为该区块内容，不再套引用块
    func testReseedSourceStyleTakesRawText() throws {
        let d = try descr("cmct", source(quote: manual))
        XCTAssertEqual(d, manual)
    }

    func testExtraQuoteSurvivesCodableRoundTrip() throws {
        let info = try source(quote: "转载自测试站")
        let data = try JSONEncoder().encode(info)
        let back = try JSONDecoder().decode(ReleaseInfo.self, from: data)
        XCTAssertEqual(back.extraQuote, "转载自测试站")
        // 旧 state/旧缓存里没有这个字段：应解成空串而不是报错
        let legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var m = legacy; m["extraQuote"] = nil
        let oldData = try JSONSerialization.data(withJSONObject: m)
        let old = try JSONDecoder().decode(ReleaseInfo.self, from: oldData)
        XCTAssertEqual(old.extraQuote, "")
        XCTAssertEqual(old.extraQuoteBBCode, "")
    }

    /// 源页没解析出简介（版式特殊/页面异常）：不能提交空简介，
    /// 否则整批目标站一起回「你必须填写简介！」
    func testEmptyDescrFallsBackToReseedNote() throws {
        var info = ReleaseInfo(siteID: "ttg", detailURL: "https://totheglory.im/details.php?id=836735",
                               name: "Food Inc 2009", descr: "", sourceName: "TTG")
        info.kind = .movie
        let s = SiteRegistry.prioritySites.first { $0.id == "cspt" }!
        let a = NexusPHPAdapter(site: s, client: HTTPClient(cookies: CookieStore(), userAgent: "t"))
        let descr = try a.buildUploadFields(info, page: try fixture("cspt-upload.html"))
            .first { $0.name == "descr" }?.value
        XCTAssertEqual(descr, "转载自TTG，感谢发布者。\n源站链接：https://totheglory.im/details.php?id=836735")
        // 手填引用优先于兜底文本
        info.extraQuote = "转载自TTG，感谢发布者"
        let d2 = try a.buildUploadFields(info, page: try fixture("cspt-upload.html"))
            .first { $0.name == "descr" }?.value
        XCTAssertEqual(d2, "[quote]\n转载自TTG，感谢发布者\n[/quote]\n")
    }

    func testQuoteMarkupHelpers() {
        let plain = ReleaseInfo(siteID: "x", detailURL: "https://x/", name: "n", extraQuote: "  第一行\n第二行  ")
        XCTAssertEqual(plain.extraQuoteBBCode, "[quote]\n第一行\n第二行\n[/quote]\n")
        XCTAssertEqual(plain.extraQuoteHTML, "<blockquote>第一行<br />第二行</blockquote><br />\n")
        XCTAssertEqual(plain.extraQuoteMarkdown, "> 第一行\n> 第二行\n\n")
        let empty = ReleaseInfo(siteID: "x", detailURL: "https://x/", name: "n", extraQuote: "   \n ")
        XCTAssertTrue(empty.extraQuoteBBCode.isEmpty)
        XCTAssertTrue(empty.extraQuoteHTML.isEmpty)
        XCTAssertTrue(empty.extraQuoteMarkdown.isEmpty)
    }
}
