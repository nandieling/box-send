import XCTest
@testable import BoxSendKit

/// 真实页面/种子解析回归测试（fixture 抓自 LuckPT #42211 + HDSky upload.php）
final class ParseTests: XCTestCase {

    private func fixturePath(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
    }
    func fixtureStr(_ name: String) -> String {
        guard let data = try? Data(contentsOf: fixturePath(name)),
              let s = String(data: data, encoding: .utf8) else {
            XCTFail("fixture 缺失: \(name)")
            return ""
        }
        return s
    }
    func fixtureData(_ name: String) -> Data? {
        try? Data(contentsOf: fixturePath(name))
    }

    // MARK: - Bencode

    func testBencodeInfoNameAndHash() {
        guard let data = fixtureData("food.torrent") else { return XCTFail("no fixture") }
        XCTAssertEqual(Bencode.infoName(data), "Food Inc 2009 1080p BluRay REMUX VC-1 DTS-HD MA 5.1-Ursuya@LuckDocu")
        XCTAssertEqual(Bencode.infoHash(data), "6c3a063dd2f9a8173f9347e3d3eecd8d21e20fe8")
    }

    func testSha1Vectors() {
        XCTAssertEqual(sha1Hex(Data()), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(sha1Hex("abc".data(using: .utf8)!), "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    // MARK: - 行值提取

    func testLineValue() {
        let text = "❁ 片　　名:　Food, Inc.\n❁ 译　　名:　毒食难肥\n❁ 类　　别:　纪录片\n"
        XCTAssertEqual(NexusPHPAdapter.lineValue(text, prefix: "译", suffix: "名"), "毒食难肥")
        XCTAssertEqual(NexusPHPAdapter.lineValue(text, prefix: "类", suffix: "别"), "纪录片")
        XCTAssertNil(NexusPHPAdapter.lineValue(text, prefix: "不存在", suffix: "项"))
    }

    // MARK: - 分类推断

    func testKindInferWithGenre() {
        let name = "Food Inc 2009 1080p BluRay REMUX VC-1 DTS-HD MA 5.1-Ursuya@LuckDocu"
        XCTAssertEqual(ReleaseKind.infer(from: name, genre: "纪录片"), .documentary)
        XCTAssertEqual(ReleaseKind.infer(from: name), .other)
        XCTAssertEqual(ReleaseKind.infer(from: "Show S01E02 1080p", genre: "剧情"), .series)
        XCTAssertEqual(ReleaseKind.infer(from: "某综艺 2026", genre: "综艺"), .tvshow)
    }

    // MARK: - 详情页解析（真实 LuckPT 页面）

    private func site(_ id: String) -> SiteConfig {
        SiteRegistry.prioritySites.first { $0.id == id }!
    }
    private func makeLuckPTAdapter() -> NexusPHPAdapter {
        NexusPHPAdapter(site: site("luckpt"), client: HTTPClient(cookies: CookieStore(), userAgent: "box-send-test"))
    }

    func testParseDetailRealPage() throws {
        let html = fixtureStr("luckpt-42211.html")
        XCTAssertFalse(html.isEmpty)
        let info = try makeLuckPTAdapter().parseDetail(html: html, detailURL: "https://pt.luckpt.de/details.php?id=42211&hit=1")
        // 标题 = 纯发布名（不带 "LuckPT :: 种子详情 ... Powered by NexusPHP"）
        XCTAssertEqual(info.name, "Food Inc 2009 1080p BluRay REMUX VC-1 DTS-HD MA 5.1-Ursuya@LuckDocu")
        // 副标题（译名）
        XCTAssertEqual(info.subtitle, "毒食难肥")
        // 类别
        XCTAssertEqual(info.genre, "纪录片")
        XCTAssertEqual(info.kind, .documentary)
        // mediainfo
        XCTAssertTrue(info.mediainfo.contains("Unique ID"))
        XCTAssertTrue(info.mediainfo.contains("VC-1"))
        // 外链
        XCTAssertEqual(info.imdb, "tt1286537")
        XCTAssertEqual(info.douban, "3564499")
        // torrent 直链
        XCTAssertTrue(info.torrentURL.contains("download.php"))
        // 简介非空
        XCTAssertFalse(info.descr.isEmpty)
        XCTAssertTrue(info.descr.contains("引用"))
    }

    // MARK: - BBCode 转换

    func testBBCodeFromRealDescription() throws {
        let html = fixtureStr("luckpt-42211.html")
        let info = try makeLuckPTAdapter().parseDetail(html: html, detailURL: "https://pt.luckpt.de/details.php?id=42211")
        let base = URL(string: "https://pt.luckpt.de")
        var out = BBCode.fromHTML(info.descr, base: base)
        out = BBCode.insertMediainfo(out, mediainfo: info.mediainfo)

        // 引用框 -> [quote][color=darkred][size=4]
        XCTAssertTrue(out.contains("[quote][color=darkred][size=4]"), "缺少引用框颜色/字号标签:\n\(String(out.prefix(400)))")
        XCTAssertTrue(out.contains("[/size][/color][/quote]"))
        // 图片 -> [img]
        XCTAssertTrue(out.contains("[img]https://i.111666.best/image/AjlAafttpJgAbZwe405PGC.jpeg[/img]"))
        XCTAssertTrue(out.contains("[img]https://i.111666.best/image/PaZtu1xOuMhchAK1Hl9p4K.jpg[/img]"))
        // 链接 -> [url=...]
        XCTAssertTrue(out.contains("[url=https://www.imdb.com/title/tt1286537/]https://www.imdb.com/title/tt1286537/[/url]"))
        XCTAssertTrue(out.contains("[url=https://movie.douban.com/subject/3564499/]https://movie.douban.com/subject/3564499/[/url]"))
        // 元信息保留
        XCTAssertTrue(out.contains("❁ 片　　名:　Food, Inc."))
        XCTAssertTrue(out.contains("毒食难肥"))
        // mediainfo 以 [quote] 包裹，且位于末尾截图之前
        XCTAssertTrue(out.contains("[quote]\nGeneral"))
        let miPos = out.range(of: "[quote]\nGeneral")!.lowerBound
        let lastImgPos = out.range(of: "[img]https://i.111666.best/image/PaZtu1xOuMhchAK1Hl9p4K.jpg[/img]")!.lowerBound
        XCTAssertLessThan(out.distance(from: out.startIndex, to: miPos),
                          out.distance(from: out.startIndex, to: lastImgPos))
        // 不应残留 HTML 标签
        XCTAssertFalse(out.contains("<fieldset"), "残留 fieldset:\n\(String(out.prefix(300)))")
        XCTAssertFalse(out.contains("<img"), "残留 img 标签")
        XCTAssertFalse(out.contains("DarkRed"), "残留 style 颜色")
    }

    func testBBCodeSmallCases() {
        let base = URL(string: "https://example.com")!
        let s1 = BBCode.fromHTML("<a href=\"https://x.y/a\">x</a>", base: base)
        XCTAssertEqual(s1, "[url=https://x.y/a]x[/url]")
        let s2 = BBCode.fromHTML("<img src=\"/pic/a.jpg\" class=\"x\">", base: base)
        XCTAssertEqual(s2, "[img]https://example.com/pic/a.jpg[/img]")
        let s3 = BBCode.fromHTML("a<br />b<br />c", base: base)
        XCTAssertEqual(s3, "a\nb\nc")
    }

    // MARK: - HDSky 上传字段构建（真实 upload 页面）

    func testHDSkyUploadFields() throws {
        let html = fixtureStr("luckpt-42211.html")
        var info = try makeLuckPTAdapter().parseDetail(html: html, detailURL: "https://pt.luckpt.de/details.php?id=42211")
        // 模拟流水线的 bencode 校正
        if let d = fixtureData("food.torrent"), let tn = Bencode.infoName(d), !tn.isEmpty {
            info.name = tn
        }
        let adapter = NexusPHPAdapter(site: site("hdsky"), client: HTTPClient(cookies: CookieStore(), userAgent: "box-send-test"))
        let page = fixtureStr("hdsky-upload.html")
        let fields = try adapter.buildUploadFields(info, page: page).map { ($0.name, $0.value) }
        let dict = Dictionary(uniqueKeysWithValues: fields.uniqed().map { ($0.0, $0.1) })
        let all = fields

        // 名称（torrentName 型站点除外，HDSky 用发布名）
        XCTAssertEqual(dict["name"], "Food Inc 2009 1080p BluRay REMUX VC-1 DTS-HD MA 5.1-Ursuya@LuckDocu")
        // 副标题
        XCTAssertEqual(dict["small_descr"], "毒食难肥")
        // 分类 = 纪录片 404
        XCTAssertEqual(dict["type"], "404")
        // IMDb / 豆瓣
        XCTAssertEqual(dict["url"], "http://www.imdb.com/title/tt1286537/")
        XCTAssertEqual(dict["url_douban"], "https://movie.douban.com/subject/3564499/")
        // 质量下拉
        XCTAssertEqual(dict["medium_sel"], "3")    // Remux
        XCTAssertEqual(dict["codec_sel"], "2")     // VC-1
        XCTAssertEqual(dict["audiocodec_sel"], "10") // DTS-HDMA
        XCTAssertEqual(dict["standard_sel"], "1")  // 2K/1080p
        // 制作组 = Other
        XCTAssertEqual(dict["team_sel"], "27")
        // 标签包含 中字(6)；无 HDR/Atmos
        let tags = all.filter { $0.0 == "option_sel[]" }.map { $0.1 }
        XCTAssertTrue(tags.contains("6"), "应勾选 中字(6), got \(tags)")
        XCTAssertFalse(tags.contains("9"))
        XCTAssertFalse(tags.contains("21"))
        // 简介为 BBCode 且含 mediainfo
        let descr = dict["descr"] ?? ""
        XCTAssertTrue(descr.contains("[quote][color=darkred][size=4]"))
        XCTAssertTrue(descr.contains("[quote]\nGeneral"))
        // mediainfo 位于「获奖情况」之后、全部尾部截图之前
        let miPos = descr.range(of: "[quote]\nGeneral")!.lowerBound
        let firstTailImg = "[img]https://i.111666.best/image/bqisJ7ip1IbnqYLmzKZg62.jpg[/img]"
        let tailPos = descr.range(of: firstTailImg)!.lowerBound
        XCTAssertTrue(descr.distance(from: descr.startIndex, to: miPos) < descr.distance(from: descr.startIndex, to: tailPos),
                      "mediainfo 应位于尾部截图之前")
        XCTAssertTrue(descr.hasSuffix("[/img]"), "应以最后一张截图收尾")
        XCTAssertTrue(descr.contains("[img]https://i.111666.best/image/"))
        XCTAssertFalse(descr.contains("<img"))
        // hidden 字段保留（如 n_id/passkey 类 token 不丢失）
        XCTAssertFalse(all.isEmpty)
    }

    // MARK: - SiteOverride 新字段

    func testSiteOverrideNewFieldsDecode() throws {
        let json = Data("""
        {"titleField":"name","subtitleField":"small_descr","tagField":"option_sel[]","tagMap":{"chinese_sub":6},"teamField":"team_sel","teamOtherValue":27,"teamPatterns":{"HDS":1}}
        """.utf8)
        let ov = try JSONDecoder().decode(SiteOverride.self, from: json)
        XCTAssertEqual(ov.subtitleField, "small_descr")
        XCTAssertEqual(ov.tagMap?["chinese_sub"], 6)
        XCTAssertEqual(ov.teamOtherValue, 27)
        // 旧配置（无新字段）仍可解码
        let old = try JSONDecoder().decode(SiteOverride.self, from: Data("{}".utf8))
        XCTAssertNil(old.subtitleField)
        XCTAssertNil(old.teamField)
    }
}

private extension Array where Element == (String, String) {
    func uniqed() -> [(String, String)] {
        var seen = Set<String>()
        return filter { seen.insert($0.0).inserted }
    }
}
