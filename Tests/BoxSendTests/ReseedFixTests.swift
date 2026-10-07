import XCTest
@testable import BoxSendKit

/// 回归：LuckPT -> HDSky 转种（无冒号类别行/英文类别/简介空行/中字标签）+ oldtoons（Unit3D torrent 链接）
final class ReseedFixTests: XCTestCase {

    // MARK: - lineValue（"◎类　　别　　X" 无冒号模板 + "类/型" 回退）

    func testLineValueWithoutColon() {
        XCTAssertEqual(NexusPHPAdapter.lineValue("◎类　　别　　喜剧 / 动画\n", prefix: "类", suffix: "别"), "喜剧 / 动画")
        XCTAssertEqual(NexusPHPAdapter.lineValue("◎译　　名　　摇曳百合3", prefix: "译", suffix: "名"), "摇曳百合3")
    }

    func testLineValueWithColonStillWorks() {
        XCTAssertEqual(NexusPHPAdapter.lineValue("❁ 类　　别: 纪录片\n", prefix: "类", suffix: "别"), "纪录片")
    }

    func testGenreFallbackToType() {
        let text = "◎类　　型　　动画\n"
        let genre = NexusPHPAdapter.lineValue(text, prefix: "类", suffix: "别")
            ?? NexusPHPAdapter.lineValue(text, prefix: "类", suffix: "型") ?? ""
        XCTAssertEqual(genre, "动画")
        XCTAssertEqual(ReleaseKind.infer(from: "Any 2024", genre: genre), .anime)
    }

    // MARK: - ReleaseKind 英文类别

    func testKindFromEnglishGenre() {
        XCTAssertEqual(ReleaseKind.infer(from: "X 2024", genre: "Animations"), .anime)
        XCTAssertEqual(ReleaseKind.infer(from: "X 2024", genre: "Animation"), .anime)
        XCTAssertEqual(ReleaseKind.infer(from: "X 2024", genre: "Movies"), .movie)
        XCTAssertEqual(ReleaseKind.infer(from: "X 2024", genre: "Documentary"), .documentary)
    }

    // MARK: - BBCode 空行

    func testBBCodeNoBlankLineFromSourceNewline() {
        // <br/> 后的源排版换行不再叠加成空行
        let out = BBCode.fromHTML("◎A　　X<br />\n◎B　　Y<br />")
        XCTAssertEqual(out, "◎A　　X\n◎B　　Y")
    }

    func testBBCodeKeepsIntendedBlankLine() {
        // 两个 <br> = 有意空行，保留
        let out = BBCode.fromHTML("line1<br /><br />line2")
        XCTAssertEqual(out, "line1\n\nline2")
    }

    func testBBCodePreKeepsNewlines() {
        let out = BBCode.fromHTML("<pre>a\nb\n</pre>")
        XCTAssertTrue(out.contains("a\nb"), "pre 内换行应保留: \(out)")
    }

    // MARK: - 中字标签（副标题 "内封中字"）

    func testChineseSubTagFromSubtitle() {
        let info = ReleaseInfo(siteID: "luckpt", detailURL: "https://x/details.php?id=1",
                               name: "Yuru Yuri S03 2015.1080p BluRay Remux AVC LPCM 2.0-LuckAni",
                               subtitle: "摇曳百合 第三季 [内封中字]")
        XCTAssertTrue(QualityTokens.canonicalTags(info).contains("chinese_sub"))
    }

    // MARK: - oldtoons（Unit3D 型 .torrent 链接 + 注册表条目）

    func testOldtoonsTorrentLinkPattern() {
        let html = """
        <a href="https://oldtoons.world/torrents/download/59255">download</a>
        <a href="https://oldtoons.world/users/nan/torrents?downloaded=include">my downloads</a>
        """
        let re = try! NSRegularExpression(pattern: "torrents/download/\\d+", options: [.caseInsensitive])
        var hit: String?
        for v in HTMLUtil.allMatches(html, "href=[\"']([^'\"]+)[\"']", options: .caseInsensitive) {
            let url = String(v.dropFirst(6).dropLast(1))
            let r = NSRange(url.startIndex..., in: url)
            if re.firstMatch(in: url, options: [], range: r) != nil { hit = url; break }
        }
        XCTAssertEqual(hit, "https://oldtoons.world/torrents/download/59255")
    }

    func testOldtoonsInRegistry() {
        let s = SiteRegistry.prioritySites.first { $0.id == "oldtoons" }
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.framework, .unit3D)
        XCTAssertEqual(s?.url, "https://oldtoons.world/")
        XCTAssertEqual(SiteOverride.oldtoons.torrentLinkPattern, "torrents/download/\\d+")
    }

    func testFenghuangInRegistry() {
        let s = SiteRegistry.prioritySites.first { $0.id == "fenghuang" }
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.framework, .nexusPHP)
        XCTAssertEqual(s?.url, "https://pt.521.best/")
        XCTAssertEqual(s?.name, "凤凰")
    }
}
