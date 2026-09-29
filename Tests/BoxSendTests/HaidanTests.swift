import Foundation
import XCTest
@testable import BoxSendKit

/// HAIDAN 自定义详情布局解析（真实页面 fixture）。
final class HaidanTests: XCTestCase {

    private func adapter() -> HaidanAdapter {
        let site = SiteConfig(id: "haidan", name: "HAIDAN", url: "https://www.haidan.cc/",
                              framework: .haidan, enabled: true, overrides: .haidan)
        return HaidanAdapter(site: SiteRegistry.effectiveSite(site),
                             client: HTTPClient(cookies: CookieStore(), userAgent: "BoxSendTest"))
    }

    func testParseDetail() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("haidan_detail.html")
        let html = try String(contentsOf: url, encoding: .utf8)
        let info = try adapter().parseDetail(html: html, detailURL: "https://www.haidan.cc/details.php?group_id=54868&id=79788&hit=1")

        XCTAssertEqual(info.name, "Chu Bao Zhi Lu 2026 2160p WEB-DL HDR H.265 10bit DDP 5.1-LongWeb")
        XCTAssertTrue(info.subtitle.hasPrefix("除暴之路"), "副标题: \(info.subtitle)")
        XCTAssertFalse(info.subtitle.contains("类型"))
        XCTAssertEqual(info.imdb, "tt46550708")
        XCTAssertEqual(info.douban, "37452964")
        XCTAssertTrue(info.torrentURL.contains("download.php?id=79788&passkey="))
        XCTAssertTrue(info.torrentURL.hasPrefix("https://www.haidan.cc/"))
        XCTAssertTrue(info.mediainfo.contains("Unique ID"))
        XCTAssertTrue(info.mediainfo.contains("Format"))
        XCTAssertTrue(info.descr.contains("◎简 介") || info.descr.contains("◎简　　介"))
        XCTAssertTrue(info.descr.contains("https://imgs.longpt.org/file/"))
        XCTAssertEqual(info.kind, .other)  // 剧情/犯罪 -> 无对应 kind 时回退命名启发式（电影名无 SxxExx）
        XCTAssertFalse(info.isForbidReseed)
    }

    private func fixtureString(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testUploadFieldsFromRealPage() throws {
        let page = try fixtureString("haidan_upload.html")
        var info = ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=1",
                               name: "Chu Bao Zhi Lu 2026 2160p WEB-DL HDR H.265 10bit DDP 5.1-LongWeb",
                               imdb: "tt46550708", kind: .movie, subtitle: "除暴之路（内封中文字幕）",
                               mediainfo: "General\nFormat : Matroska")
        info.descr = "<p>◎简 介 测试</p>"
        let fields = adapter().buildUploadFields(info, page: page)
        func v(_ n: String) -> String? { fields.last(where: { $0.name == n })?.value }

        XCTAssertEqual(v("name"), info.name)
        XCTAssertEqual(v("small_descr"), "除暴之路（内封中文字幕）")
        XCTAssertEqual(v("type"), "401")        // Movies(电影)
        XCTAssertEqual(v("medium_sel"), "11")   // WEB-DL
        XCTAssertEqual(v("codec_sel"), "11")    // H.265/HEVC/X265
        XCTAssertEqual(v("standard_sel"), "1")  // 2160p/4K
        XCTAssertEqual(v("url"), "http://www.imdb.com/title/tt46550708/")
        // 中字 -> tag_list[]=3
        let tags = fields.filter { $0.name == "tag_list[]" }.map { $0.value }
        XCTAssertEqual(tags, ["3"])
        // mediainfo 无 technical_info 字段 -> 内嵌简介
        let descr = v("descr") ?? ""
        XCTAssertTrue(descr.contains("Format : Matroska"))
    }
}
