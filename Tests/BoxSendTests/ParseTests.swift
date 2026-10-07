import XCTest
@testable import BoxSendKit

/// 真实页面/种子解析回归测试（fixture 抓自 LuckPT #42211 + HDSky upload.php）
final class ParseTests: XCTestCase {

    /// divContent 必须按 UTF-16 偏移换算索引：站点页面常用 CRLF 换行、标题里带 emoji，
    /// 用 String.index(offsetBy:) 会把 NSRange 当 Character 数，轻则截错、重则越界崩溃
    func testDivContentHandlesUTF16Offsets() {
        let html = ["<html>",
                    "<div id=\"kdescr\">",
                    "  前菜 🍿",
                    "  <div class=\"quote\">引用 🎬 内容</div>",
                    "  正文 Food Inc 2009（豆瓣 8.9★）",
                    "</div>",
                    "<footer>",
                    "</footer>",
                    "</html>"].joined(separator: "\r\n")
        let body = HTMLUtil.divContent(html, id: "kdescr")
        XCTAssertNotNil(body, "CRLF + emoji 页面应能提取 div 内容")
        XCTAssertTrue(body?.contains("正文 Food Inc 2009") == true, "实际: \(body ?? "nil")")
        XCTAssertTrue(body?.contains("引用") == true)
        XCTAssertFalse(body?.contains("<footer>") == true, "配对应停在最近的闭合 div")
    }

    /// LuckPT #42211 详情页"副标题"行的完整内容（回归基准）
    let FULL_SUBTITLE = "毒食难肥/美味代价(台) | 导演：罗伯特·肯纳 | 第8届华盛顿影评人协会奖获奖纪录片 | 内封LuckPT原创简繁中字及Now官方翻译中字 *美国食品安全纪录片*"

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
        // 副标题 = 详情页"副标题"行完整内容（不只是"译名"行的前段）
        XCTAssertEqual(info.subtitle, FULL_SUBTITLE)
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
        // 空行上限：源页 CRLF 不得产生 3 个及以上连续换行（最多 1 个空行）
        if let r3 = out.range(of: "\n\n\n") {
            let i = out.distance(from: out.startIndex, to: r3.lowerBound)
            let lo = out.index(out.startIndex, offsetBy: max(0, i - 100))
            let hi = out.index(out.startIndex, offsetBy: min(out.count, i + 100))
            XCTFail("多连续空行 @\(i): \(out[lo..<hi].replacingOccurrences(of: "\n", with: "⏎"))")
        }
        XCTAssertNil(out.range(of: "\r"), "残留 CR 字符")
    }

    func testBBCodeCRLFSource() {
        // 源页常见 <br><br> + CRLF 混排：转换后最多 1 个空行
        let html = "<fieldset><legend>x</legend>text</fieldset><br /><br />\r<br />\r\n<img src=\"http://a/b.jpg\" /><br /><br />\r\nhello"
        let out = BBCode.fromHTML(html)
        XCTAssertNil(out.range(of: "\n\n\n"), "CRLF 未被规范化:\n\(out)")
        XCTAssertNil(out.range(of: "\r"))
        XCTAssertTrue(out.hasSuffix("hello"))
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
        // 副标题（完整内容）
        XCTAssertEqual(dict["small_descr"], FULL_SUBTITLE)
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
        {"titleField":"name","subtitleField":"small_descr","tagField":"option_sel[]","tagMap":{"chinese_sub":"6"},"teamField":"team_sel","teamOtherValue":27,"teamPatterns":{"HDS":1},"regionField":"team_sel","regionPatterns":{"美国":4},"regionOtherValue":8}
        """.utf8)
        let ov = try JSONDecoder().decode(SiteOverride.self, from: json)
        XCTAssertEqual(ov.subtitleField, "small_descr")
        XCTAssertEqual(ov.tagMap?["chinese_sub"], "6")
        XCTAssertEqual(ov.teamOtherValue, 27)
        XCTAssertEqual(ov.regionPatterns?["美国"], 4)
        XCTAssertEqual(ov.regionOtherValue, 8)
        // 旧配置（无新字段）仍可解码
        let old = try JSONDecoder().decode(SiteOverride.self, from: Data("{}".utf8))
        XCTAssertNil(old.subtitleField)
        XCTAssertNil(old.teamField)
    }

    // MARK: - 多站上传字段（副标题/标签/制作组/地区）

    func testMultiSiteUploadFields() throws {
        let html = fixtureStr("luckpt-42211.html")
        var info = try makeLuckPTAdapter().parseDetail(html: html, detailURL: "https://pt.luckpt.de/details.php?id=42211")
        if let d = fixtureData("food.torrent"), let tn = Bencode.infoName(d), !tn.isEmpty {
            info.name = tn
        }
        func fieldsFor(_ id: String) throws -> [(String, String)] {
            let adapter = NexusPHPAdapter(site: site(id), client: HTTPClient(cookies: CookieStore(), userAgent: "box-send-test"))
            return adapter.buildUploadFields(info, page: "").map { ($0.name, $0.value) }
        }
        func dictOf(_ fields: [(String, String)]) -> [String: String] {
            var seen = Set<String>()
            return Dictionary(uniqueKeysWithValues: fields.filter { seen.insert($0.0).inserted }.map { ($0.0, $0.1) })
        }

        // hdhome：副标题 + tags[]（中字=zz，简介有简繁字幕）+ 制作组 Other(11)
        let hdhome = try fieldsFor("hdhome")
        let d1 = dictOf(hdhome)
        XCTAssertEqual(d1["small_descr"], FULL_SUBTITLE)
        let tags1 = hdhome.filter { $0.0 == "tags[]" }.map { $0.1 }
        XCTAssertTrue(tags1.contains("zz"), "hdhome 应勾 中字(zz), got \(tags1)")
        XCTAssertFalse(tags1.contains("db"))
        XCTAssertEqual(d1["team_sel"], "11")

        // audiences：副标题 + tags[] 中字=zz；无制作组字段
        let audiences = try fieldsFor("audiences")
        let d2 = dictOf(audiences)
        XCTAssertEqual(d2["small_descr"], FULL_SUBTITLE)
        let tags2 = audiences.filter { $0.0 == "tags[]" }.map { $0.1 }
        XCTAssertTrue(tags2.contains("zz"))
        XCTAssertFalse(audiences.contains { $0.0 == "team_sel" })

        // chdbits：副标题；无标签；制作组兜底 0（无 Other 选项）
        let chdbits = try fieldsFor("chdbits")
        let d3 = dictOf(chdbits)
        XCTAssertEqual(d3["small_descr"], FULL_SUBTITLE)
        XCTAssertFalse(chdbits.contains { $0.0.hasPrefix("tags") })
        // 独立复选框标签：中字 -> cnsub=yes
        XCTAssertTrue(chdbits.contains { $0.0 == "cnsub" && $0.1 == "yes" })
        XCTAssertFalse(chdbits.contains { $0.0 == "perent" && $0.1 == "yes" })
        XCTAssertEqual(d3["team_sel"], "0")

        // ttg：副标题字段名为 subtitle
        let ttg = try fieldsFor("ttg")
        let d4 = dictOf(ttg)
        XCTAssertEqual(d4["subtitle"], FULL_SUBTITLE)
        XCTAssertFalse(ttg.contains { $0.0 == "team" })  // 该站 team 是 hidden 字段

        // pter：副标题 + 地区（产地 美国 -> 欧美 4）
        let pter = try fieldsFor("pter")
        let d5 = dictOf(pter)
        XCTAssertEqual(d5["small_descr"], FULL_SUBTITLE)
        XCTAssertEqual(d5["team_sel"], "4")

        // luckpt：tags[4][] 中字=23 + 制作组 LuckDocu(13)
        let luckpt = try fieldsFor("luckpt")
        let d6 = dictOf(luckpt)
        XCTAssertEqual(d6["small_descr"], FULL_SUBTITLE)
        let tags6 = luckpt.filter { $0.0 == "tags[4][]" }.map { $0.1 }
        XCTAssertTrue(tags6.contains("23"), "luckpt 应勾 中字(23), got \(tags6)")
        XCTAssertEqual(d6["team_sel[4]"], "13")
    }

    // MARK: - HDSky 详情页解析（表单下载 + 副标题行）

    func testHDSkyDetailPage() throws {
        let html = fixtureStr("hdsky-detail.html")
        XCTAssertFalse(html.isEmpty)
        let adapter = NexusPHPAdapter(site: site("hdsky"), client: HTTPClient(cookies: CookieStore(), userAgent: "box-send-test"))
        let info = try adapter.parseDetail(html: html, detailURL: "https://hdsky.me/details.php?id=550491&hit=1")
        // 标题 = h1#top 纯发布名
        XCTAssertEqual(info.name, "The Immortal Ascension S01 2025 2160p WEB-DL AAC H265-Pure@HDSWEB")
        // 副标题 = 副标题行完整内容
        XCTAssertTrue(info.subtitle.hasPrefix("凡人修仙传 全30集"), "got: \(info.subtitle)")
        XCTAssertTrue(info.subtitle.contains("主演: 杨洋 金晨 汪铎"))
        // 下载直链 = 下载表单 action（含 t= 与 sign=），不是跨属性拼出的坏 URL
        XCTAssertTrue(info.torrentURL.contains("download.php?id=550491"), "got: \(info.torrentURL)")
        XCTAssertTrue(info.torrentURL.contains("t=") && info.torrentURL.contains("sign="))
        XCTAssertFalse(info.torrentURL.contains("hit=1href"))
        // 文件名 = submit 按钮 value
        XCTAssertTrue(info.torrentName.hasPrefix("[HDSky]."), "got: \(info.torrentName)")
        XCTAssertTrue(info.torrentName.hasSuffix(".torrent"))
        // 该直链下载下来的 torrent 是有效 bencode（回归：之前误抓 HTML 导致 415）
        if let d = fixtureData("hdsky-550491.torrent") {
            XCTAssertNotNil(Bencode.infoHash(d), "fixture 应可解析出 info hash")
            XCTAssertEqual(d.prefix(9).map { Character(UnicodeScalar($0)) }, Array("d8:announce".prefix(9)).map { $0 })
        } else {
            XCTFail("fixture hdsky-550491.torrent 缺失")
        }
        // 无效 bencode 校验：HTML 页面应判为无效
        XCTAssertNil(Bencode.infoHash(Data("<html>not a torrent</html>".utf8)))
    }

    // MARK: - LuckPT 新主题（列表页 vs ajax=1 详情页）

    func testLuckPTNewThemeDetailDetection() throws {
        let listview = fixtureStr("luckpt-56812-listview.html")
        let ajaxPage = fixtureStr("luckpt-56812-ajax.html")
        XCTAssertFalse(NexusPHPAdapter.looksLikeDetailPage(listview), "列表页不应被识别为详情页")
        XCTAssertTrue(NexusPHPAdapter.looksLikeDetailPage(ajaxPage), "ajax=1 页面应被识别为详情页")
        let url = "https://pt.luckpt.de/details.php?id=56812&hit=1"
        XCTAssertEqual(NexusPHPAdapter.detailURLWithAjax(url), "https://pt.luckpt.de/details.php?id=56812&hit=1&ajax=1")
        XCTAssertEqual(NexusPHPAdapter.detailURLWithAjax("https://pt.luckpt.de/torrents.php?id=56812"), "https://pt.luckpt.de/torrents.php?id=56812&ajax=1")
        XCTAssertEqual(NexusPHPAdapter.detailURLWithAjax("https://pt.luckpt.de/torrents.php"), "https://pt.luckpt.de/torrents.php?ajax=1")
        XCTAssertNil(NexusPHPAdapter.detailURLWithAjax("https://pt.luckpt.de/details.php?id=56812&ajax=1"))
    }

    func testParseDetailLuckPTAjaxPage() throws {
        let html = fixtureStr("luckpt-56812-ajax.html")
        let info = try makeLuckPTAdapter().parseDetail(html: html, detailURL: "https://pt.luckpt.de/details.php?id=56812&hit=1")
        XCTAssertEqual(info.name, "Yuru Yuri S03 2015.1080p BluRay Remux AVC LPCM 2.0-LuckAni")
        XCTAssertEqual(info.imdb, "tt5420420")
        XCTAssertEqual(info.douban, "26339249")
        XCTAssertEqual(info.subtitle, "摇曳百合 第三季 [内封中字]")
        XCTAssertTrue(info.genre.contains("动画"), "genre 应含 动画, 实际: \(info.genre)")
        XCTAssertTrue(info.mediainfo.contains("Unique ID"), "mediainfo 缺失")
        XCTAssertTrue((info.torrentURL ?? "").hasSuffix("download.php?id=56812"), "torrentURL: \(info.torrentURL ?? "-")")
        // 类别映射：动画 -> anime
        XCTAssertEqual(info.kind, .anime)
    }

    func testDetailRowValue() {
        let html = "<tr><td class=\"rowhead\">副标题</td><td class=\"rowfollow\">A | B&nbsp;C</td></tr>"
        XCTAssertEqual(NexusPHPAdapter.detailRowValue(html, label: "副标题"), "A | B C")
        XCTAssertNil(NexusPHPAdapter.detailRowValue(html, label: "不存在"))
    }

    func testRegionLineValue() {
        let text = "❁ 产　　地:　美国\n❁ 类　　别:　纪录片\n"
        XCTAssertEqual(NexusPHPAdapter.lineValue(text, prefix: "产", suffix: "地"), "美国")
    }

    // MARK: - 标题规范化（2026-10-05：cmct dot 名 / 其余站空格名）

    func testAsciiReleaseName() {
        XCTAssertEqual(NexusPHPAdapter.asciiReleaseName(
            "[LuckPT].摇曳百合.第三季.Yuru.Yuri.S03.2015.1080p.BluRay.Remux.AVC.LPCM.2.0-LuckAni"),
            "Yuru.Yuri.S03.2015.1080p.BluRay.Remux.AVC.LPCM.2.0-LuckAni")
        XCTAssertEqual(NexusPHPAdapter.asciiReleaseName("[A][B].Movie.2020.1080p-WEB"), "Movie.2020.1080p-WEB")
        XCTAssertEqual(NexusPHPAdapter.asciiReleaseName("Movie.2020.1080p-WEB"), "Movie.2020.1080p-WEB")
        // 无 ASCII：原样
        XCTAssertEqual(NexusPHPAdapter.asciiReleaseName("某电影.蓝光"), "某电影.蓝光")
    }

    func testPrettyReleaseName() {
        XCTAssertEqual(NexusPHPAdapter.prettyReleaseName(
            "Yuru.Yuri.S03.2015.1080p.BluRay.Remux.AVC.LPCM.2.0-LuckAni"),
            "Yuru Yuri S03 2015.1080p BluRay Remux AVC LPCM 2.0-LuckAni")
        // 已是空格名：保持不变（5.1 版本号点保留）
        XCTAssertEqual(NexusPHPAdapter.prettyReleaseName(
            "Food Inc 2009 1080p BluRay REMUX VC-1 DTS-HD MA 5.1-Ursuya@LuckDocu"),
            "Food Inc 2009 1080p BluRay REMUX VC-1 DTS-HD MA 5.1-Ursuya@LuckDocu")
        XCTAssertEqual(NexusPHPAdapter.prettyReleaseName("The.Movie.2020.2160p.UHD.BluRay.x265-GRP"),
                       "The Movie 2020.2160p UHD BluRay x265-GRP")
    }

    // MARK: - cmct 上传字段（海报/截图分离 + 附加信息=转种来源）

    func testCMCTUploadFields() throws {
        let html = fixtureStr("luckpt-56812-ajax.html")
        var info = try makeLuckPTAdapter().parseDetail(html: html, detailURL: "https://pt.luckpt.de/details.php?id=56812")
        info.torrentName = "[LuckPT].摇曳百合.第三季.Yuru.Yuri.S03.2015.1080p.BluRay.Remux.AVC.LPCM.2.0-LuckAni.torrent"
        let adapter = NexusPHPAdapter(site: site("cmct"), client: HTTPClient(cookies: CookieStore(), userAgent: "box-send-test"))
        let page = fixtureStr("cmct-upload.html")
        let fields = adapter.buildUploadFields(info, page: page).map { ($0.name, $0.value) }
        var seenNames = Set<String>()
        let dict = Dictionary(uniqueKeysWithValues: fields.filter { seenNames.insert($0.0).inserted }.map { ($0.0, $0.1) })

        // 主标题：dot 风格且去 [LuckPT] 前缀/中文段
        XCTAssertEqual(dict["name"], "Yuru.Yuri.S03.2015.1080p.BluRay.Remux.AVC.LPCM.2.0-LuckAni")
        // 海报 = 首图
        XCTAssertEqual(dict["url_poster"], "https://img3.pixhost.to/images/6151/778181861_douban-poster.jpg")
        // 截图 = 3 张（不含海报）
        XCTAssertEqual(dict["url_vimages"], """
        https://img3.pixhost.to/images/6083/776555808_01.png
        https://img3.pixhost.to/images/6083/776555875_02.png
        https://img3.pixhost.to/images/6083/776555987_03.png
        """)
        // 附加信息 = 转种来源（源站名 + 引用框原文）
        XCTAssertEqual(dict["descr"],
            "转载自LuckPT，感谢发布者。原盘来自U2:[摇曳百合 第三季][Yuru Yuri San Hai!][ゆるゆり さん☆ハイ!][BDMV][Vol.1-Vol.6 Fin](#28882)<br />\n字幕来自华盟字幕社")
        // MediaInfo 独立提交
        XCTAssertTrue((dict["Media_BDInfo"] ?? "").contains("Unique ID"))
    }

    // MARK: - hddolby 上传字段（bbcode 简介 + 截图不含海报）

    func testHDDolbyUploadFields() throws {
        let html = fixtureStr("luckpt-56812-ajax.html")
        var info = try makeLuckPTAdapter().parseDetail(html: html, detailURL: "https://pt.luckpt.de/details.php?id=56812")
        info.torrentName = "[LuckPT].摇曳百合.第三季.Yuru.Yuri.S03.2015.1080p.BluRay.Remux.AVC.LPCM.2.0-LuckAni.torrent"
        let adapter = NexusPHPAdapter(site: site("hddolby"), client: HTTPClient(cookies: CookieStore(), userAgent: "box-send-test"))
        let page = fixtureStr("hddolby-upload.html")
        let fields = adapter.buildUploadFields(info, page: page).map { ($0.name, $0.value) }
        var seenNames = Set<String>()
        let dict = Dictionary(uniqueKeysWithValues: fields.filter { seenNames.insert($0.0).inserted }.map { ($0.0, $0.1) })

        // 主标题：空格风格
        XCTAssertEqual(dict["name"], "Yuru Yuri S03 2015.1080p BluRay Remux AVC LPCM 2.0-LuckAni")
        // TMDB 必填
        XCTAssertEqual(dict["tmdb_url"], "https://www.themoviedb.org/tv/52891")
        // 截图 = 3 张（不含海报）
        XCTAssertEqual(dict["screenshots"], """
        https://img3.pixhost.to/images/6083/776555808_01.png
        https://img3.pixhost.to/images/6083/776555875_02.png
        https://img3.pixhost.to/images/6083/776555987_03.png
        """)
        // MediaInfo 独立提交
        XCTAssertTrue((dict["media_info"] ?? "").contains("Unique ID"))

        let descr = dict["descr"] ?? ""
        // bbcode 引用框：[quote] 独占一行，内容紧随
        XCTAssertTrue(descr.hasPrefix("[quote]\n转载自LuckPT，感谢发布者。\n[/quote]\n[quote]\n原盘来自U2:"), "开头:\n\(String(descr.prefix(120)))")
        XCTAssertTrue(descr.contains("字幕来自华盟字幕社\n[/quote]"))
        // 引用后紧跟海报 [img]（无空行），其后一个空行再进正文
        XCTAssertTrue(descr.contains("[/quote]\n[img]https://img3.pixhost.to/images/6151/778181861_douban-poster.jpg[/img]\n\n◎译"))
        // 链接 bbcode 化
        XCTAssertTrue(descr.contains("[url=https://www.imdb.com/title/tt5420420]https://www.imdb.com/title/tt5420420[/url]"))
        XCTAssertTrue(descr.contains("[url=https://movie.douban.com/subject/26339249/]https://movie.douban.com/subject/26339249/[/url]"))
        // 截图不进简介；简介以剧情收尾
        XCTAssertFalse(descr.contains("_01.png"))
        XCTAssertFalse(descr.contains("<img"))
        XCTAssertTrue(descr.hasSuffix("增添了一份欢乐。"), "结尾:\n\(String(descr.suffix(80)))")
        // 剧情缩进保留
        XCTAssertTrue(descr.contains("◎简　　介\n　　故事发生在"))
        if let r3 = descr.range(of: "\n\n\n") {
            let i = descr.distance(from: descr.startIndex, to: r3.lowerBound)
            let lo = descr.index(descr.startIndex, offsetBy: max(0, i - 60))
            let hi = descr.index(descr.startIndex, offsetBy: min(descr.count, i + 60))
            XCTFail("多余空行 @\(i): \(descr[lo..<hi].replacingOccurrences(of: "\\n", with: "⏎"))")
        }
    }

    // MARK: - BBCode 引用框/海报排版

    func testBBCodeQuoteLayout() {
        // 新版主题引用框：<br> 排版残留不应产生空行
        let out1 = BBCode.fromHTML("<fieldset><legend> 引用 </legend><br /><br />\nA(#1)<br />\nB<br />\n</fieldset>")
        XCTAssertEqual(out1, "[quote]\nA(#1)\nB\n[/quote]")
        // 旧主题：引用框 + 颜色字号内联
        let out2 = BBCode.fromHTML("<fieldset><legend> 引用 </legend><br /><span style=\"color: DarkRed\"><font size=\"4\"><br />1. 首发<br />2. 感谢</font></span></fieldset>")
        XCTAssertTrue(out2.hasPrefix("[quote][color=darkred][size=4]\n1. 首发"), out2)
        XCTAssertTrue(out2.hasSuffix("感谢[/size][/color][/quote]"), out2)
        // 引用结束后紧跟海报图：不留空行
        let out3 = BBCode.fromHTML("<fieldset><legend>x</legend>q</fieldset><br /><br />\n<img src=\"http://a/p.jpg\" /><br /><br />\nbody")
        XCTAssertEqual(out3, "[quote]\nq\n[/quote]\n[img]http://a/p.jpg[/img]\n\nbody")
        // 换行后的全角缩进保留
        let out4 = BBCode.fromHTML("◎简　　介<br />\n　　故事发生在")
        XCTAssertEqual(out4, "◎简　　介\n　　故事发生在")
    }
}

private extension Array where Element == (String, String) {
    func uniqed() -> [(String, String)] {
        var seen = Set<String>()
        return filter { seen.insert($0.0).inserted }
    }
}
