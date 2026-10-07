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
    /// 源简介 fieldset 引用块的纯文本形态（附加信息区块应随后带上）
    private let srcQuoteBlock = "原盘来自U2:[摇曳百合 第三季][Yuru Yuri San Hai!][ゆるゆり さん☆ハイ!][BDMV][Vol.1-Vol.6 Fin](#28882)\n字幕来自华盟字幕社"


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

    /// 官种自动致谢已移除：不勾选源站引用就不往简介里塞任何东西
    func testNoManualQuoteAddsNoAutoPrefix() throws {
        let d = try descr("crabpt", source())!
        XCTAssertFalse(d.contains("感谢发布者"),
                       "源站是官种但没勾选源站引用：不该自动加转载自，实际开头: \(d.prefix(120))")
    }

    /// cmct 的 descr 实为「附加信息」：手填引用在最前，源简介引用块随后，都不套引用块
    func testReseedSourceStyleTakesRawText() throws {
        let d = try descr("cmct", source(quote: manual))
        XCTAssertEqual(d, manual + "\n" + srcQuoteBlock)
    }

    /// 不勾选源站引用：附加信息取源简介自带的引用块（两处都没有才留空并提示）
    func testReseedSourceStyleFallsBackToSourceQuote() throws {
        XCTAssertEqual(try descr("cmct", source()), srcQuoteBlock)
    }

    /// 源简介也没有引用块时附加信息才是空的（流水线据此提示）
    func testReseedSourceTextEmptyWithoutAnyQuote() throws {
        var info = try source()
        info.descr = info.descr.replacingOccurrences(
            of: "<fieldset>[\\s\\S]*?</fieldset>", with: "", options: .regularExpression)
        XCTAssertEqual(SiteRegistry.reseedSourceText(for: info), "")
    }

    /// MediaInfo 引用框不算制作信息：那是技术信息，目标站有独立输入框
    func testMediainfoQuoteIsSkipped() throws {
        let html = """
        <div><fieldset><legend> MediaInfo </legend>General<br />Unique ID : 25738105<br />
        Format : MPEG-4<br />File size : 77.4 GiB<br />Duration : 25 mn<br /></fieldset>
        <p>正文</p></div>
        """
        XCTAssertEqual(NexusPHPAdapter.sourceQuoteBlocks(html), [])
    }

    /// 引用块正文：去 legend/标签、<br> 转换行、压掉空行与 CRLF
    func testQuoteBlockText() throws {
        let html = "<legend> 引用 </legend><br /><br />\n原盘来自U2：U2 原盘<br />\r\n字幕来自华盟字幕社<br />\n"
        XCTAssertEqual(NexusPHPAdapter.quoteBlockText(html), "原盘来自U2：U2 原盘\n字幕来自华盟字幕社")
    }

    /// 提示的判定依据：只有「附加信息 = 转种来源」型站点需要手填源站引用
    func testNeedsSourceQuoteFieldOnlyForThoseSites() throws {
        for id in ["cmct", "ptlgs"] {
            let s = SiteRegistry.prioritySites.first { $0.id == id }!
            XCTAssertTrue(SiteRegistry.needsSourceQuoteField(s), id)
        }
        XCTAssertFalse(SiteRegistry.needsSourceQuoteField(SiteRegistry.prioritySites.first { $0.id == "crabpt" }!))
        // 用户配置里的旧快照（overrides 没带 descrStyle）也要按内置表判定
        var stale = SiteRegistry.prioritySites.first { $0.id == "cmct" }!
        stale.overrides = SiteOverride()
        XCTAssertTrue(SiteRegistry.needsSourceQuoteField(stale))
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
