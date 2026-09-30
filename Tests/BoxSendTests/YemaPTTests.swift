import Foundation
import XCTest
@testable import BoxSendKit

/// YemaPT 适配器测试：真实 API 响应 fixture + 离线字段映射。
final class YemaPTTests: XCTestCase {

    private func fixtureData(_ name: String) -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try! Data(contentsOf: url)
    }

    private func makeAdapter() -> YemaPTAdapter {
        let site = SiteConfig(id: "yemapt", name: "YemaPT", url: "https://www.yemapt.org/",
                              framework: .yemapt, enabled: true)
        return YemaPTAdapter(site: site, client: HTTPClient(cookies: CookieStore(), userAgent: "BoxSendTest"))
    }

    /// 用真实 fetchUploadOptions 响应预置缓存（离线）
    private func primeOptions(_ a: YemaPTAdapter) {
        let j = try! JSONSerialization.jsonObject(with: fixtureData("yema_options.json")) as! [String: Any]
        let data = j["data"] as! [String: Any]
        func opts(_ k: String) -> [YemaPTAdapter.UpOpt] {
            (data[k] as! [[String: Any]]).map { .init(label: $0["label"] as! String, value: $0["value"] as! String) }
        }
        func cats(_ list: [[String: Any]]) -> [YemaPTAdapter.CatOpt] {
            list.map {
                .init(key: $0["key"] as? String, label: $0["label"] as! String, value: $0["value"] as! Int,
                      options: ($0["options"] as? [[String: Any]]).map(cats))
            }
        }
        let cfg = YemaPTAdapter.UploadConfig(dayUploadMax: data["dayUploadMax"] as? Int,
                                             uploadUserAnonymousEnable: (data["uploadConfig"] as? [String: Any])?["uploadUserAnonymousEnable"] as? Bool,
                                             defaultUploadUserAnonymous: (data["uploadConfig"] as? [String: Any])?["defaultUploadUserAnonymous"] as? String,
                                             hrSetPunishEnable: (data["uploadConfig"] as? [String: Any])?["hrSetPunishEnable"] as? Bool)
        a.optionsCache = YemaPTAdapter.OptResp.D(
            categoryOptions: cats(data["categoryOptions"] as! [[String: Any]]),
            mediumOptions: opts("mediumOptions"),
            standardOptions: opts("standardOptions"),
            codecOptions: opts("codecOptions"),
            audioCodecOptions: opts("audioCodecOptions"),
            regionOptions: opts("regionOptions"),
            teamOptions: opts("teamOptions"),
            tagOptions: opts("tagOptions"),
            uploadConfig: cfg
        )
    }

    private func field(_ fields: [HTTPClient.MultipartField], _ name: String) -> String? {
        fields.last(where: { $0.name == name })?.value
    }
    private func fieldsAll(_ fields: [HTTPClient.MultipartField], _ name: String) -> [String] {
        fields.filter { $0.name == name }.map { $0.value }
    }

    func testParseDetailFromFixture() throws {
        let a = makeAdapter()
        let info = try a.parseDetail(fixtureData("yema_detail.json"),
                                     detailURL: "https://www.yemapt.org/#/torrent/detail/6313", id: 6313)
        XCTAssertEqual(info.name, "Inception 2010 2160p MA WEB-DL DDP5.1 H.265-HHWEB")
        XCTAssertEqual(info.subtitle, "盗梦空间")
        XCTAssertEqual(info.imdb, "tt1375666")
        XCTAssertEqual(info.douban, "3541415")
        XCTAssertEqual(info.size, 27575942540)
        XCTAssertEqual(info.kind, .movie)
        XCTAssertEqual(info.torrentURL, "https://www.yemapt.org/api/torrent/download?id=6313")
        XCTAssertEqual(info.region, "美国")
        XCTAssertTrue(info.descr.contains("盗梦空间"))
        XCTAssertTrue(info.isForbidReseed == false)
    }

    func testUploadFieldsDocumentary() throws {
        let a = makeAdapter()
        primeOptions(a)
        var info = ReleaseInfo(
            siteID: "luckpt",
            detailURL: "https://pt.luckpt.de/details.php?id=42211&hit=1",
            name: "Food Inc 2009 1080p BluRay REMUX VC-1 DTS-HD MA 5.1-Ursuya",
            descr: "<br /><img src=\"https://i.111666.best/image/a.jpeg\" /><br />\n毒食难肥，内封简体中文字幕。<br /><a href=\"https://www.imdb.com/title/tt1286537/\">IMDb</a>",
            imdb: "tt1286537",
            douban: "3564499",
            size: 18070000000,
            kind: .documentary,
            torrentName: "Food Inc.torrent",
            torrentURL: "https://pt.luckpt.de/download.php?id=42211",
            isForbidReseed: false,
            subtitle: "毒食难肥",
            genre: "纪录片",
            mediainfo: "Format : Matroska",
            region: "美国")
        let fields = try a.buildUploadFields(info)
        XCTAssertEqual(field(fields, "showName"), "Food Inc 2009 1080p BluRay REMUX VC-1 DTS-HD MA 5.1-Ursuya")
        XCTAssertEqual(field(fields, "shortDesc"), "毒食难肥")
        XCTAssertEqual(field(fields, "categoryId"), "15")          // 纪录片
        XCTAssertEqual(field(fields, "medium"), "4")               // Remux
        XCTAssertEqual(field(fields, "standard"), "4")             // 1080p
        XCTAssertEqual(field(fields, "codec"), "3")                // VC-1(Blu-ray)
        XCTAssertEqual(field(fields, "audiocodec"), "4")           // DTS-HD MA
        XCTAssertEqual(fieldsAll(fields, "regionList"), ["4"])     // US(美国)
        XCTAssertEqual(field(fields, "team"), "999")               // Other
        XCTAssertEqual(fieldsAll(fields, "tagList"), ["6"])        // 中字
        XCTAssertEqual(field(fields, "imdb"), "1286537")
        XCTAssertEqual(field(fields, "douban"), "3564499")
        XCTAssertEqual(field(fields, "mediaInfo"), "Format : Matroska")
        XCTAssertEqual(field(fields, "uploadUserAnonymous"), "y")
        XCTAssertEqual(field(fields, "hrPunishEnable"), "false")
        let longDesc = field(fields, "longDesc") ?? ""
        XCTAssertTrue(longDesc.contains("![](https://i.111666.best/image/a.jpeg)"))
        XCTAssertTrue(longDesc.contains("毒食难肥，内封简体中文字幕。"))
        XCTAssertTrue(longDesc.contains("IMDb(https://www.imdb.com/title/tt1286537/)"))
        XCTAssertEqual(fieldsAll(fields, "screenshotList"), ["https://i.111666.best/image/a.jpeg"])
        XCTAssertEqual(field(fields, "picture"), "https://i.111666.best/image/a.jpeg")
        XCTAssertNil(field(fields, "season"))
        _ = info
    }

    func testUploadFieldsSeries() throws {
        let a = makeAdapter()
        primeOptions(a)
        let info = ReleaseInfo(
            siteID: "luckpt",
            detailURL: "https://pt.luckpt.de/details.php?id=1&hit=1",
            name: "Some Show 2020 全6集 1080p WEB-DL H.265 EAC3",
            descr: "简介",
            imdb: "tt9999999",
            douban: nil,
            size: 10,
            kind: .series,
            torrentName: "s.torrent",
            torrentURL: "https://x/y.torrent",
            isForbidReseed: true,
            subtitle: "某剧",
            genre: "",
            mediainfo: "",
            region: "")
        let fields = try a.buildUploadFields(info)
        XCTAssertEqual(field(fields, "categoryId"), "5")           // 剧集
        XCTAssertEqual(field(fields, "medium"), "1")               // Web-DL/WebRip
        XCTAssertEqual(field(fields, "standard"), "4")
        XCTAssertEqual(field(fields, "codec"), "2")                // H.265/HEVC
        XCTAssertEqual(field(fields, "audiocodec"), "5")           // E-AC3
        XCTAssertEqual(field(fields, "season"), nil)
        let tags = fieldsAll(fields, "tagList")
        XCTAssertTrue(tags.contains("1"), "禁转: \(tags)")
        XCTAssertTrue(tags.contains("12"), "完结: \(tags)")
    }

    func testSeasonParsing() {
        XCTAssertEqual(YemaPTAdapter.season(from: "Show S01E01 1080p"), 1)
        XCTAssertEqual(YemaPTAdapter.season(from: "Show S12E03 1080p"), 12)
        XCTAssertNil(YemaPTAdapter.season(from: "Movie 2020 1080p"))
    }

    func testMarkdownToHTML() {
        let md = "![](https://a.com/1.jpg)\n\n[IMDb](https://www.imdb.com/title/tt1/)\n**bold**"
        let html = YemaPTAdapter.markdownToHTML(md)
        XCTAssertTrue(html.contains("<img src=\"https://a.com/1.jpg\">"))
        XCTAssertTrue(html.contains("IMDb (https://www.imdb.com/title/tt1/)"))
        XCTAssertTrue(html.contains("bold"))
        XCTAssertFalse(html.contains("**"))
        XCTAssertTrue(html.contains("<br />"))
    }

    func testHTMLToMarkdown() {
        let html = "<img src=\"https://a.com/1.jpg\" /><br />第一行<br />第二行 <a href=\"https://u.com/\">链接</a>&amp;更多"
        let md = YemaPTAdapter.htmlToMarkdown(html)
        XCTAssertTrue(md.contains("![](https://a.com/1.jpg)"))
        XCTAssertTrue(md.contains("第一行"))
        XCTAssertTrue(md.contains("第二行 链接(https://u.com/)&更多"))
        XCTAssertFalse(md.contains("<img"))
        XCTAssertFalse(md.contains("&amp;"))
    }

    func testKindFromCategory() {
        XCTAssertEqual(YemaPTAdapter.kindFromCategory("纪录片"), .documentary)
        XCTAssertEqual(YemaPTAdapter.kindFromCategory("电影"), .movie)
        XCTAssertEqual(YemaPTAdapter.kindFromCategory(nil), .other)
    }

    func testPiecesHex() throws {
        let data = fixtureData("yema_sample.torrent")
        XCTAssertEqual(Bencode.piecesHashHex(data), "395f55f8a1be8e664559f4bde49e7845b7862b7e")
    }

    func testDetailLinkAndFallbackSubtitle() {
        XCTAssertEqual(YemaPTAdapter.detailLink(id: 6313, base: "https://www.yemapt.org/"),
                       "https://www.yemapt.org/#/torrent/detail/6313")
        let info = ReleaseInfo(
            siteID: "luckpt", detailURL: "https://x/details.php?id=1",
            name: "Name Only", descr: "<br />第一行简介",
            imdb: nil, douban: nil, size: nil, kind: nil,
            torrentName: "a.torrent", torrentURL: "https://x/a.torrent",
            isForbidReseed: false, subtitle: "", genre: "", mediainfo: "", region: "")
        XCTAssertEqual(YemaPTAdapter.fallbackSubtitle(info), "第一行简介")
    }
}
