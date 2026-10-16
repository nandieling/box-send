import XCTest
@testable import BoxSendKit

/// 蓝光 DIY（外发加工盘）在各目标站的 类型 / 媒介 / 标签 选择。
/// 依据源站 LuckPT 46343《反叛的鲁路修剧场版3：皇道》1080p Blu-ray AVC TrueHD 5.1-LuckAni：
/// 源站标签「官方 中字」——官方不跟随，中字说明碟是后期加工盘，
/// 媒介要选本站的 Blu-ray/DIY、打 DIY 标签、不打原盘。
final class BluRayDIYTests: XCTestCase {
    private func site(_ id: String) -> SiteConfig { SiteRegistry.prioritySites.first { $0.id == id }! }

    private func adapter(_ id: String) -> NexusPHPAdapter {
        NexusPHPAdapter(site: site(id), client: HTTPClient(cookies: CookieStore(), userAgent: "box-send-test"))
    }

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 真实解析结果（ LuckPT 新版主题 + ajax=1 经典详情页）
    private var real: ReleaseInfo {
        get throws {
            try adapter("luckpt").parseDetail(html: try fixture("luckpt-46343-ajax.html"),
                                             detailURL: "https://pt.luckpt.de/details.php?id=46343")
        }
    }

    // MARK: - 源站信息完整性

    func testSlimDetailPageIsDetectedAsIncomplete() throws {
        let slim = try fixture("luckpt-46343-slim.html")
        let ajax = try fixture("luckpt-46343-ajax.html")
        XCTAssertFalse(NexusPHPAdapter.hasDescriptionBlock(slim), "壳页没有简介容器")
        XCTAssertTrue(NexusPHPAdapter.hasDescriptionBlock(ajax))
        XCTAssertTrue(NexusPHPAdapter.shouldRetryWithAjax(slim), "壳页必须再用 ajax=1 取一次")
        XCTAssertFalse(NexusPHPAdapter.shouldRetryWithAjax(ajax), "已经拿到简介就不必再请求")
        XCTAssertGreaterThan(NexusPHPAdapter.detailRichness(ajax), NexusPHPAdapter.detailRichness(slim))

        let url = "https://pt.luckpt.de/details.php?id=46343"
        let thin = try adapter("luckpt").parseDetail(html: slim, detailURL: url)
        XCTAssertNotNil(thin.sourceCompletenessWarning, "只有壳页时要报「源站信息不全」")
        let full = try real
        XCTAssertNil(full.sourceCompletenessWarning, "经典详情页信息齐全，不该报警")
        XCTAssertEqual(full.imdb, "tt9844256")
        XCTAssertEqual(full.douban, "27107625")
        XCTAssertEqual(full.region, "日本")
        XCTAssertTrue(full.genre.contains("动画"), "类别行要带出来，供题材标签用")
    }

    func testDIYInferredFromChineseSubtitleOnDisc() throws {
        XCTAssertTrue(QualityTokens.isDIYRelease(try real), "日版动画原盘 + 内封中字/字幕来自字幕库 = DIY")
        XCTAssertTrue(QualityTokens.canonicalTags(try real).contains("diy"))
        XCTAssertFalse(QualityTokens.canonicalTags(try real).contains("disc"), "DIY 不算原盘发布")

        // 国产发布自带中文字幕，不算 DIY
        var cn = try real
        cn.region = "中国大陆"
        XCTAssertFalse(QualityTokens.isDIYRelease(cn))

        // 认不出产地、又没有外语原声痕迹：不拿简介里的「中字」当 DIY 依据
        var unknown = try real
        unknown.region = ""
        unknown.descr = unknown.descr.replacingOccurrences(of: "日语", with: "")
        XCTAssertFalse(QualityTokens.isDIYRelease(unknown))

        // 流媒体源码：带中字也不改媒介判定
        var web = try real
        web.name = "Yuru Yuri 2015 1080p WEB-DL AAC-x"
        XCTAssertFalse(QualityTokens.isDIYRelease(web))
    }

    /// 蓝光原盘与蓝光 DIY 是两个概念：蓝光盘没中文字幕 = 原盘，加装中文字幕 = DIY；
    /// REMUX 不推 DIY（天空那条 1080p Blu-ray Remux 内封中字曾被误打）
    func testBluRaySubtitlesDecideDIYRemuxNeverInferred() throws {
        let strip: (ReleaseInfo) -> ReleaseInfo = { info in
            var c = info
            c.subtitle = ""
            c.sourceTags = c.sourceTags.filter { !$0.contains("中字") }
            for word in ["中文字幕", "内封中字", "中字", "字幕来自"] {
                c.descr = c.descr.replacingOccurrences(of: word, with: "")
            }
            return c
        }
        let diy = try real
        XCTAssertTrue(QualityTokens.isDIYRelease(diy), "蓝光盘带中字 = 蓝光 DIY")

        var clean = strip(diy)
        XCTAssertFalse(QualityTokens.isDIYRelease(clean), "没有中文字幕的蓝光盘就是蓝光原盘")
        XCTAssertTrue(QualityTokens.canonicalTags(clean).contains("disc"), "原盘标签照旧")

        var remux = diy
        remux.name = "Black Lagoon S01 2006 1080p Blu-ray Remux AVC LPCM 2.0-LuckAni"
        XCTAssertFalse(QualityTokens.isDIYRelease(remux), "带中字的 Remux 不推 DIY")
        XCTAssertTrue(QualityTokens.canonicalTags(remux).contains("remux"))

        // 源站明写 DIY 的 Remux 仍然跟随；而 -LuckDIY 只是发布组名，不算明写
        var declared = remux
        declared.sourceTags = ["官方", "中字", "DIY"]
        XCTAssertTrue(QualityTokens.isDIYRelease(declared), "源站标签写明 DIY 就跟随")
        XCTAssertTrue(QualityTokens.hasDIYToken("Movie 2013 1080p Blu-ray DIY-x"))
        XCTAssertFalse(QualityTokens.hasDIYToken("Movie 2013 1080p Blu-ray-LuckDIY"),
                       "发布组名 LuckDIY 不是 DIY 词")
    }

    // MARK: - 媒介 / 标签

    /// 站点上传页（选项文案取自实测表单）
    private func page(type: [(String, String)], mediumField: String, medium: [(String, String)],
                      tagField: String? = "tags[4][]",
                      tags: [(String, String)] = [("1", "首发"), ("2", "DIY"), ("4", "国语"),
                                                  ("5", "中字"), ("6", "HDR"), ("7", "原盘"),
                                                  ("9", "匿名发布")]) -> String {
        var h = "<form action=\"takeupload.php\" enctype=\"multipart/form-data\">"
            + "<input name=\"name\" /><textarea name=\"descr\"></textarea>"
            + "<select name=\"type\"><option value=\"0\">请选择</option>"
        for (v, l) in type { h += "<option value=\"\(v)\">\(l)</option>" }
        h += "</select><select name=\"\(mediumField)\"><option value=\"0\">请选择一项</option>"
        for (v, l) in medium { h += "<option value=\"\(v)\">\(l)</option>" }
        h += "</select><select name=\"team_sel[4]\"><option value=\"0\">请选择一项</option><option value=\"5\">其他</option></select>"
        if let tagField {
            for (v, l) in tags { h += "<input type=\"checkbox\" name=\"\(tagField)\" value=\"\(v)\" /> \(l)" }
        }
        return h + "</form>"
    }

    private let animeType: [(String, String)] = [("401", "电影"), ("402", "电视剧"), ("405", "动漫"),
                                                 ("404", "纪录片"), ("409", "其他")]

    private func posted(_ siteID: String, _ page: String) throws -> [(String, String)] {
        adapter(siteID).buildUploadFields(try real, page: page).map { ($0.name, $0.value) }
    }

    /// 各站「媒介」下拉里的 DIY 选项（值取自实测表单）必须被选中，而不是纯原盘/压制
    func testDIYMediumOptionChosenPerSite() throws {
        let cases: [(String, String, [(String, String)], String)] = [
            // 铂金家
            ("pthome", "medium_sel", [("12", "UHD Blu-ray"), ("13", "UHD Blu-ray/DIY"), ("1", "Blu-ray(原盘)"),
                                      ("14", "Blu-ray/DIY"), ("3", "REMUX"), ("15", "encode"), ("10", "WEB-DL")], "14"),
            // 1PT
            ("ptba", "medium_sel[4]", [("9", "Track"), ("7", "Encode"), ("3", "Remux"), ("1", "Blu-ray(原盘)"),
                                       ("16", "UHD Blu-ray"), ("17", "UHD Blu-ray/DIY"), ("19", "Blu-ray/DIY")], "19"),
            // 咖啡
            ("ptcafe", "medium_sel[4]", [("1", "UHD Blu-ray 原盘"), ("4", "Blu-ray 原盘"), ("5", "Blu-ray DIY"),
                                         ("6", "Remux"), ("7", "Encode"), ("8", "WEB-DL")], "5"),
            // 库非
            ("kufei", "medium_sel[4]", [("4", "BD 原盘"), ("5", "BD DIY"), ("6", "BD Remux"), ("8", "1080P/i 压制"),
                                        ("1", "UHD原盘"), ("11", "WEB-DL")], "5"),
            // 红豆饭
            ("hdfans", "medium_sel[4]", [("21", "BD原盘"), ("22", "BD DIY"), ("23", "BD Remux"), ("24", "1080P/i压制"),
                                         ("17", "UHD原盘"), ("5", "WEB-DL")], "22"),
            // 海德堡
            ("hdbao", "medium_sel[4]", [("3", "Blu-ray 原盘"), ("4", "Blu-ray DIY"), ("5", "REMUX"), ("6", "Encode"),
                                        ("1", "UHD Blu-ray 原盘")], "4"),
            // 52PT
            ("pt52", "medium_sel", [("2", "Blu-ray DIY"), ("11", "Blu-ray原盘无中文"), ("4", "Blu-ray Remux"),
                                    ("14", "2K原盘中字（国粤语）"), ("7", "Encode(MKV/MP4)")], "2"),
            // 冬樱
            ("wtsakura", "medium_sel[4]", [("12", "Blu-ray"), ("13", "Blu-ray/DIY"), ("14", "Remux"),
                                           ("15", "Encode"), ("10", "UHD Blu-ray")], "13"),
            // 爱玲
            ("aling", "medium_sel[4]", [("1", "Blu-ray"), ("2", "Blu-ray DIY"), ("3", "Remux"), ("7", "Encode")], "2"),
            // 天空：内置值表写死 1=Blu-ray，本站另有 DIY 选项时要改选 12
            ("hdsky", "medium_sel", [("13", "UHD Blu-ray"), ("1", "Blu-ray"), ("12", "Blu-ray/DIY"),
                                     ("3", "Remux"), ("7", "Encode")], "12"),
        ]
        for (id, field, medium, want) in cases {
            let page = page(type: animeType, mediumField: field, medium: medium)
            let fields = try posted(id, page)
            XCTAssertEqual(fields.first { $0.0 == field }?.1, want, "\(id) 媒介应选本站的 Blu-ray/DIY")
        }
    }

    /// 没有 DIY 媒介项的站点：媒介留原盘，但要打上 DIY 标签、不打原盘标签
    func testDIYTagCheckedAndDiscTagSkipped() throws {
        let page = page(type: animeType, mediumField: "medium_sel[4]",
                        medium: [("1", "Blu-ray"), ("3", "Remux"), ("7", "Encode"), ("10", "WEB-DL")])
        let values = Set(try posted("cyanbug", page).map { "\($0.0)=\($0.1)" })
        XCTAssertTrue(values.contains("medium_sel[4]=1"), "没有 DIY 选项时媒介仍是 Blu-ray")
        XCTAssertTrue(values.contains("tags[4][]=2"), "要打 DIY 标签")
        XCTAssertTrue(values.contains("tags[4][]=5"), "中字标签跟随源站")
        XCTAssertFalse(values.contains("tags[4][]=7"), "DIY 不勾原盘标签")
    }

    /// 国产发布自带中文字幕：不打 DIY，媒介仍是原盘
    func testMainlandDiscIsNotDIY() throws {
        var info = try real
        info.region = "中国大陆"
        let page = page(type: animeType, mediumField: "medium_sel[4]",
                        medium: [("1", "Blu-ray"), ("2", "Blu-ray DIY"), ("3", "Remux")])
        let fields = adapter("aling").buildUploadFields(info, page: page).map { ($0.name, $0.value) }
        XCTAssertEqual(fields.first { $0.0 == "medium_sel[4]" }?.1, "1", "国产碟不选 DIY")
        XCTAssertFalse(fields.contains { $0.0 == "tags[4][]" && $0.1 == "2" }, "不打 DIY 标签")
    }

    // MARK: - x264/x265 = 压制

    func testSoftwareEncoderMeansEncode() {
        XCTAssertEqual(QualityTokens.medium(from: "Total Drama 2019 1080p BluRay x264-GRP", kind: .movie), "encode")
        XCTAssertEqual(QualityTokens.medium(from: "Watch 2020 2160p BluRay x265-GRP", kind: .movie), "uhdbd",
                       "4K 碟保留 UHD 媒介")
        XCTAssertEqual(QualityTokens.medium(from: "Watch 2020 1080p Blu-ray AVC TrueHD-x", kind: .movie,
                                            mediainfo: "Video\nFormat : AVC\nEncoding library : x264 core 164"),
                       "encode", "MediaInfo 里出现 x264 = 压制盘")
        XCTAssertEqual(QualityTokens.medium(from: "Watch 2020 1080p Blu-ray Remux AVC-x", kind: .movie,
                                            mediainfo: "Encoding library : x264 core 164"), "remux",
                       "REMUX 不受编码器影响")
        XCTAssertEqual(QualityTokens.medium(from: "Watch 2020 1080p Blu-ray AVC x264-GRP", kind: .movie), "encode")
        XCTAssertFalse(QualityTokens.hasSoftwareEncoder("Format: AVC / Format profile: Main@L4.1"))
    }

    // MARK: - 类型（站点按形态细分动漫分区）

    func testFilmGoesToAnimeMovieCategory() throws {
        // 冬樱：动漫电影 / 动漫剧集(分集) / 动漫剧集(合集)
        let ws = page(type: [("401", "Movies/电影"), ("413", "Animation series/动漫剧集(分集)"),
                             ("423", "Animation series/动漫剧集(合集)"), ("422", "Animation flims/动漫电影"),
                             ("409", "Misc/其他")],
                      mediumField: "medium_sel[4]", medium: [("12", "Blu-ray"), ("13", "Blu-ray/DIY")])
        XCTAssertEqual(try posted("wtsakura", ws).first { $0.0 == "type" }?.1, "422", "剧场版落进动漫电影")

        // 蝴蝶：完结动漫 / 连载动漫 / 剧场OVA
        let hd = page(type: [("405", "完结动漫"), ("427", "连载动漫"), ("428", "剧场OVA"), ("401", "大陆电影")],
                      mediumField: "medium_sel[4]", medium: [("14", "Blu-ray"), ("5", "BDRip")])
        XCTAssertEqual(try posted("hudbt", hd).first { $0.0 == "type" }?.1, "428", "剧场版落进剧场OVA")
    }

    func testSeriesGoesToAnimeSeriesCategory() throws {
        var info = try real
        info.name = "Yuru Yuri S03 2015 1080p Blu-ray AVC LPCM 2.0-LuckAni"
        let ws = page(type: [("401", "Movies/电影"), ("413", "Animation series/动漫剧集(分集)"),
                             ("423", "Animation series/动漫剧集(合集)"), ("422", "Animation flims/动漫电影")],
                      mediumField: "medium_sel[4]", medium: [("12", "Blu-ray"), ("13", "Blu-ray/DIY")])
        let type = adapter("wtsakura").buildUploadFields(info, page: ws).map { ($0.name, $0.value) }
            .first { $0.0 == "type" }?.1
        XCTAssertTrue(type == "413" || type == "423", "连载动漫不能选成动漫电影（实际 \(type ?? "nil")）")
    }
}
