import XCTest
@testable import BoxSendKit

/// 馒头（Unit3D）发种的简介格式。
///
/// 站方 descr 存的是 BBCode：站台上每条种子的简介都是 `[img]`/`[url=]`/`[quote]`/`[color]`，
/// 没有一条带 HTML 标签。以前直接把源站 HTML 发过去，交给站方转 BBCode，而那一转是有损的
/// （LuckPT 52931 实测：海报与三张视频截图整枚消失、`<a>` 被压成纯文本且查询串里的 `&`
/// 变成 `&amp;`/`@`、`&nbsp;` 原样留在正文里）。现在自己转，站方照单存。
final class MTeamDescrBBCodeTests: XCTestCase {
    private func fixture(_ name: String) -> String {
        let p = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name).path
        return (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
    }

    private func mteam(descrFormat: String? = nil) -> SiteConfig {
        var raw = SiteConfig(id: "mteam", name: "馒头", url: "https://kp.m-team.cc/",
                             framework: .unit3D, enabled: true)
        raw.apiKey = "test-key"
        if let descrFormat {
            var ov = SiteOverride.mteam
            ov.descrFormat = descrFormat
            raw.overrides = ov
        }
        return SiteRegistry.effectiveSite(raw)
    }

    private var client: HTTPClient { HTTPClient(cookies: CookieStore(), userAgent: "boxsend-test") }

    /// LuckPT 52931 真实详情页：海报在主题海报块里，三张截图在简介末尾，
    /// 每张都挂着源站的 onload/onerror/data-zoomable。
    private func reseedDescr(descrFormat: String? = nil) throws -> String {
        let page = fixture("luckpt-52931-poster.html")
        XCTAssertTrue(page.contains("751429435_03-2.png"), "fixture 应是那条种子")
        let luck = SiteRegistry.prioritySites.first { $0.id == "luckpt" }!
        let info0 = try NexusPHPAdapter(site: SiteRegistry.effectiveSite(luck), client: client)
            .parseDetail(html: page, detailURL: "https://pt.luckpt.de/details.php?id=52931&hit=1")
        var info = info0
        info.extraQuote = "转载自LuckPT，感谢发布者"
        return Unit3DAdapter(site: mteam(descrFormat: descrFormat), client: client).uploadDescr(info)
    }

    /// 海报与三张截图都要在，且是站方认的 `[img]` 写法（不是会被站方丢掉的 `<img>`）
    func testPosterAndScreenshotsSurviveAsBBCodeImages() throws {
        let d = try reseedDescr()
        XCTAssertEqual(d.components(separatedBy: "<img").count - 1, 0, "不该再把 HTML img 发给站方")
        XCTAssertEqual(d.components(separatedBy: "[img]").count - 1, 4, "海报 1 张 + 截图 3 张")
        XCTAssertTrue(d.contains("[img]https://doubaninfo.com/dbposter/doubaninfo_com_3703209.jpg[/img]"), d)
        for n in ["751429428_01-2", "751429431_02-2", "751429435_03-2"] {
            XCTAssertTrue(d.contains("[img]https://img2.pixhost.to/images/9517/\(n).png[/img]"),
                          "缺截图 \(n)：\n\(d)")
        }
    }

    /// 源页把海报同时放在主题海报块和正文里：转出来只留一条，站台卡片上不会连贴两张
    func testDuplicatedPosterImageCollapsesToOne() throws {
        let d = try reseedDescr()
        let poster = "https://doubaninfo.com/dbposter/doubaninfo_com_3703209.jpg"
        let hits = d.components(separatedBy: "[img]").dropFirst().filter { $0.hasPrefix(poster) }
        XCTAssertEqual(hits.count, 1, "海报重复：\n\(d)")
    }

    /// 链接要留成 `[url=]`：站方把 HTML `<a>` 压成纯文本，查询串里的 `&` 还会被转义成
    /// `&amp;`（正文里就显示 &amp;）或换成 `@`。BBCode 里发裸 `&`，站方原样存。
    func testSourceLinksStayClickableWithPlainAmpersand() throws {
        let d = try reseedDescr()
        XCTAssertFalse(d.contains("<a "), "不该再把 HTML 锚点发给站方")
        XCTAssertFalse(d.contains("&amp;"), "查询串里的 & 不能被转义两次：\n\(d)")
        XCTAssertTrue(d.contains("[url=https://u2.dmhy.org/details.php?id=38744&hit=1]"), d)
        XCTAssertTrue(d.contains("[url=https://www.imdb.com/title/tt1481339/]"), d)
        XCTAssertTrue(d.contains("[url=https://movie.douban.com/subject/3703209/]"), d)
    }

    /// `&nbsp;` 是 HTML 实体，BBCode 正文里站方不认，会照字面显示在简介上
    func testNoHTMLEntitiesLeftInText() throws {
        let d = try reseedDescr()
        XCTAssertFalse(d.contains("&nbsp;"), d)
        XCTAssertTrue(d.contains("◎IMDb评分 7.3/10"), d)
    }

    /// 源简介自带的制作引用（fieldset/legend）转成 `[quote]`，转种来源并到同一个引用块第一行
    func testSourceQuoteBecomesBBCodeQuoteAndAbsorbsReseedCredit() throws {
        let d = try reseedDescr()
        XCTAssertTrue(d.hasPrefix("[quote]\n转载自LuckPT，感谢发布者\n"), String(d.prefix(60)))
        XCTAssertTrue(d.contains("原盘来自U2"), d)
        XCTAssertFalse(d.contains("引用 "), "legend 里的「引用」二字不该留在正文")
        // MediaInfo 走独立字段提交，简介里不再内嵌一份
        XCTAssertFalse(d.contains("Unique ID"), "MediaInfo 应只在 mediainfo 字段里")
    }

    /// 源站没解析出简介时兜一句：馒头发种页简介必填，空着整单被拒
    func testEmptyDescrFallsBackToReseedCredit() {
        var info = ReleaseInfo(siteID: "luckpt",
                               detailURL: "https://pt.luckpt.de/details.php?id=52931",
                               name: "Zan Sayonara Zetsubou Sensei S03 2009 1080p BluRay Remux-LuckAni")
        info.sourceName = "LuckPT"
        info.extraQuote = "转载自LuckPT，感谢发布者"
        let d = Unit3DAdapter(site: mteam(), client: client).uploadDescr(info)
        XCTAssertTrue(d.hasPrefix("[quote]\n转载自LuckPT，感谢发布者\n[/quote]"), String(d.prefix(60)))
        XCTAssertTrue(d.contains("源站链接：https://pt.luckpt.de/details.php?id=52931"), d)
    }

    /// 站点 override 写明 descrFormat=html 时仍走 HTML 简介（Unit3D 分支站里有真吃 HTML 的）
    func testHTMLFormatStillSendsHTML() throws {
        let d = try reseedDescr(descrFormat: "html")
        XCTAssertTrue(d.contains("<blockquote>转载自LuckPT，感谢发布者</blockquote>"), String(d.prefix(80)))
        XCTAssertTrue(d.contains("<img"), "HTML 格式保留 img 标签")
        XCTAssertTrue(d.contains("src=\"https://img2.pixhost.to/images/9517/751429428_01-2.png\""), d)
    }

    /// 相对路径的图片在 BBCode 里也要绝对化（站方拿不到源站的相对路径）
    func testRelativeImageSourceIsAbsolute() {
        let html = "<div><img src=\"pic/a.png\"></div>"
        let bb = BBCode.fromHTML(html, base: URL(string: "https://pt.luckpt.de/details.php?id=1"))
        XCTAssertEqual(bb, "[img]https://pt.luckpt.de/pic/a.png[/img]")
    }

    /// href/src 里的实体要解开：`…id=38744&amp;hit=1` 原样进 `[url]` 会被站方再转义一次
    func testEntitiesInHrefAreDecoded() {
        let html = "<a href=\"https://u2.dmhy.org/details.php?id=38744&amp;hit=1\">字幕</a>"
        let bb = BBCode.fromHTML(html, base: URL(string: "https://pt.luckpt.de/"))
        XCTAssertEqual(bb, "[url=https://u2.dmhy.org/details.php?id=38744&hit=1]字幕[/url]")
    }

    func testDedupImgLinesKeepsFirstOccurrenceAndOtherText() {
        let src = """
        [img]https://a/1.png[/img]
        正文
        [img]https://a/1.png[/img]
        [img]https://a/2.png[/img]
        """
        let out = Unit3DAdapter.dedupImgLines(src)
        XCTAssertEqual(out.components(separatedBy: "[img]https://a/1.png[/img]").count - 1, 1)
        XCTAssertTrue(out.contains("正文"))
        XCTAssertTrue(out.contains("[img]https://a/2.png[/img]"))
    }
}
