import XCTest
@testable import BoxSendKit

/// 回归：LuckPT 56812（摇曳百合 第三季 / 1080p BluRay Remux / 动漫 / 日本 / 源站标签 官方+中字+完结）
/// 转种到各目标站时的字段选择。上传页均为实站抓取的表单。
final class ReseedFieldTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 源站解析结果（真实详情页）
    private func sourceRelease() throws -> ReleaseInfo {
        let luck = SiteRegistry.prioritySites.first { $0.id == "luckpt" }!
        return try NexusPHPAdapter(site: luck, client: HTTPClient(cookies: CookieStore(), userAgent: "t"))
            .parseDetail(html: try fixture("luckpt-56812-ajax.html"),
                         detailURL: "https://pt.luckpt.de/details.php?id=56812&hit=1")
    }

    private func fields(_ siteID: String, info: ReleaseInfo? = nil) throws -> [(String, String)] {
        let s = SiteRegistry.prioritySites.first { $0.id == siteID }!
        let a = NexusPHPAdapter(site: s, client: HTTPClient(cookies: CookieStore(), userAgent: "t"))
        return try a.buildUploadFields(info ?? sourceRelease(), page: fixture("\(siteID)-upload.html"))
            .map { ($0.name, $0.value) }
    }

    private func values(_ fields: [(String, String)], _ name: String) -> [String] {
        fields.filter { $0.0 == name }.map { $0.1 }
    }
    private func first(_ fields: [(String, String)], _ name: String) -> String? {
        fields.first(where: { $0.0 == name })?.1
    }

    // MARK: 源站解析

    func testSourceReleaseFields() throws {
        let info = try sourceRelease()
        XCTAssertEqual(info.kind, .anime)
        XCTAssertEqual(info.region, "日本")
        XCTAssertEqual(info.sourceTags, ["官方", "中字", "完结"])
        XCTAssertEqual(info.sourceName, "LuckPT", "转种来源用品牌名而非显示名「幸运」")
        XCTAssertTrue(QualityTokens.canonicalTags(info).contains("completed"))
        XCTAssertTrue(QualityTokens.canonicalTags(info).contains("anime"))
        XCTAssertTrue(QualityTokens.canonicalTags(info).contains("remux"))
    }

    // MARK: 1 熊猫：地区 + 完结标签 + 豆瓣

    func testPandaRegionAndTags() throws {
        let f = try fields("panda")
        XCTAssertEqual(first(f, "source_sel[4]"), "3", "CHN/EU-US/JPN(日本)… 中选日本")
        XCTAssertTrue(values(f, "tags[4][]").contains("10"), "完结")
        XCTAssertTrue(values(f, "tags[4][]").contains("6"), "中字")
        XCTAssertEqual(first(f, "pt_gen"), "https://movie.douban.com/subject/26339249/")
    }

    // MARK: 2 PTtime：ACG 分类、不勾"原盘或ISO"

    func testPTTimeCategoryIsACG() throws {
        let f = try fields("ptt")
        XCTAssertEqual(first(f, "type"), "406", "ACG，不是 401 Movies（其选项文案含「不含动漫」）")
        XCTAssertEqual(values(f, "tags[]"), ["zz"], "只勾中字，不勾原盘或ISO(dwj)")
        XCTAssertEqual(first(f, "dburl"), "https://movie.douban.com/subject/26339249/")
    }

    func testBestCategoryOptionRejectsNegatedLabel() {
        let opts = [(value: "401", label: "Movies(电影、电影短片(不含动漫))"),
                    (value: "406", label: "ACG(动漫、卡通、二次元、漫画及相关)")]
        XCTAssertEqual(NexusPHPAdapter.bestCategoryOption(opts, keyword: "动漫"), "406")
    }

    // MARK: 3 烧包：1080 分辨率 + Remux 处理 + 动漫来源

    func testPtsbaoStandardProcessingSource() throws {
        let f = try fields("ptsbao")
        XCTAssertEqual(first(f, "standard_sel[1]"), "1", "选项写裸数字「1080」也要选中，不能落 Other")
        XCTAssertEqual(first(f, "processing_sel[1]"), "1", "处理方式 Remux")
        XCTAssertTrue(["47", "96"].contains(first(f, "source_sel[1]") ?? ""),
                      "来源要落在动漫子类，不能选电影-Remux：\(first(f, "source_sel[1]") ?? "-")")
    }

    // MARK: 4 优堡 / 5 麒麟 / 6 咖啡：地区=日本、豆瓣、媒介

    func testUbitsRegionAndDouban() throws {
        let f = try fields("ubits")
        XCTAssertEqual(first(f, "source_sel[4]"), "5", "日本(Japanese)")
        XCTAssertEqual(first(f, "pt_gen"), "https://movie.douban.com/subject/26339249/")
    }

    func testQilinRegionAndTagsThroughWrappedLabels() throws {
        let f = try fields("qilin")
        XCTAssertEqual(first(f, "source_sel[4]"), "19", "JPN/日本")
        XCTAssertTrue(values(f, "tags[4][]").contains("6"), "中字（文案前有 <img> 图标）")
        XCTAssertTrue(values(f, "tags[4][]").contains("16"), "完结")
        XCTAssertEqual(first(f, "pt_gen"), "https://movie.douban.com/subject/26339249/")
    }

    func testPtcafeRegionAndMediumNotUHD() throws {
        let f = try fields("ptcafe")
        XCTAssertEqual(first(f, "source_sel[4]"), "4", "来源=日本")
        XCTAssertEqual(first(f, "medium_sel[4]"), "6", "1080p 发布要选 Remux，不是 UHD Remux")
        let tags = values(f, "tags[4][]")
        XCTAssertEqual(Set(tags), Set(["9", "3"]), "中字+完结；官方是源站概念，目标站不打")
    }

    func testWrappedLabelWithIconParses() throws {
        let html = "<label><input type=\"checkbox\" name=\"tags[4][]\" value=\"6\" />"
            + "<img src=\"https://x/y.png\" style=\"height:12px;\">中字</label>"
        let boxes = HTMLUtil.checkboxes(html)
        XCTAssertEqual(boxes.first?.label, "中字")
    }

    // MARK: 7 野马：已存在的响应不再报"转种成功+推送失败"

    func testYemaDuplicateDetection() {
        XCTAssertTrue(YemaPTAdapter.isDuplicateMessage("该种子已存在"))
        XCTAssertTrue(YemaPTAdapter.isDuplicateMessage("Torrent already exists"))
        XCTAssertFalse(YemaPTAdapter.isDuplicateMessage(""))
        XCTAssertEqual(YemaPTAdapter.torrentID(from: 12345), 12345)
        XCTAssertEqual(YemaPTAdapter.torrentID(from: "12345"), 12345)
        XCTAssertEqual(YemaPTAdapter.torrentID(from: ["data": ["torrentId": "99"]]), 99)
        XCTAssertNil(YemaPTAdapter.torrentID(from: ["message": "ok"]))
    }

    // MARK: 8 青蛙：Remux 标签 + 完结

    func testQingwaTagsRemuxAndCompleted() throws {
        let f = try fields("qingwa")
        let tags = values(f, "tags[4][]")
        XCTAssertEqual(Set(tags), Set(["6", "14", "15"]), "中字+完结+Remux")
        XCTAssertEqual(first(f, "source_sel[4]"), "9", "青蛙的 source_sel 实为媒介：Remux")
    }

    // MARK: 9 织梦：转种来源 + 音频落 Other

    func testZmptSourcePrefixAndAudioOther() throws {
        let f = try fields("zmpt")
        XCTAssertEqual(first(f, "audiocodec_sel[4]"), "7", "无 PCM/LPCM 选项时应选 Other，不是 WAV")
        XCTAssertTrue(values(f, "tags[4][]").contains("12"), "完结")
        guard let descr = first(f, "descr") else { return XCTFail("无 descr") }
        // 织梦 overrides 明确写了 descrSourcePrefix：仍加一行纯文本来源（与官种自动引用无关）
        XCTAssertTrue(descr.hasPrefix("转载自LuckPT，感谢发布者。\n"), String(descr.prefix(60)))
    }

    // MARK: 10 整季剧集 -> 完结

    func testCompletedDetection() {
        func release(_ name: String, tags: [String] = [], subtitle: String = "") -> ReleaseInfo {
            ReleaseInfo(siteID: "luckpt", detailURL: "https://x/details.php?id=1", name: name,
                        kind: .anime, subtitle: subtitle, sourceTags: tags)
        }
        XCTAssertTrue(QualityTokens.isCompletedRelease(release("Yuru Yuri S03 2015 1080p BluRay Remux-x")))
        XCTAssertTrue(QualityTokens.isCompletedRelease(release("Any 2015 1080p WEB-DL-x", tags: ["完结"])))
        XCTAssertTrue(QualityTokens.isCompletedRelease(release("Any 2015 1080p WEB-DL-x", subtitle: "全12集")))
        XCTAssertFalse(QualityTokens.isCompletedRelease(release("Yuru Yuri S03E05 2015 1080p WEB-DL-x")))
        XCTAssertFalse(QualityTokens.isCompletedRelease(release("Movie 2015 1080p BluRay Remux-x")))
        XCTAssertFalse(QualityTokens.isCompletedRelease(release("Any S03 WEB-DL-x", tags: ["未完结"])),
                       "「未完结」不算完结")
    }

    // MARK: 11 葡萄汁：音频落 Other + 豆瓣

    func testPtzoneAudioOtherAndDouban() throws {
        let f = try fields("ptzone")
        XCTAssertEqual(first(f, "audiocodec_sel[4]"), "7", "无 PCM 选项 -> Other")
        XCTAssertEqual(first(f, "pt_gen"), "https://movie.douban.com/subject/26339249/")
        XCTAssertTrue(values(f, "tags[4][]").contains("9"), "完结")
    }

    // MARK: 12 蟹黄堡：地区在处理下拉 + 完结/动画标签

    func testCrabptRegionInProcessingAndTags() throws {
        let f = try fields("crabpt")
        XCTAssertEqual(first(f, "processing_sel[4]"), "5", "蟹黄堡的地区下拉叫 processing_sel：日本（JP）")
        XCTAssertEqual(first(f, "source_sel[4]"), "4", "媒介 Remux")
        let tags = Set(values(f, "tags[4][]"))
        XCTAssertTrue(tags.contains("7"), "中字")
        XCTAssertTrue(tags.contains("8"), "完结")
        XCTAssertTrue(tags.contains("37"), "动画")
        XCTAssertFalse(tags.contains("59"), "不能勾未完结")
    }

    // MARK: 通用：产地 -> 地区下拉

    func testRegionMatch() {
        let o: [(value: String, label: String)] = [(value: "3", label: "JPN(日本)"),
                                                     (value: "1", label: "EU/US(欧美)"),
                                                     (value: "6", label: "Other(其他)")]
        XCTAssertEqual(RegionMatch.option(forRegion: "日本", in: o), "3")
        // 只有"欧美"这一档时，欧洲产地落到欧美；完全无关的产地返回 nil（保持表单默认值）
        XCTAssertEqual(RegionMatch.option(forRegion: "法国", in: o), "1")
        XCTAssertNil(RegionMatch.option(forRegion: "巴西", in: o))
        let cn: [(value: String, label: String)] = [(value: "2", label: "中国大陆（CN）"),
                                                     (value: "3", label: "港台（HK/TW）"),
                                                     (value: "1", label: "其他（Other）")]
        XCTAssertEqual(RegionMatch.option(forRegion: "日本", in: cn), nil)
        XCTAssertEqual(RegionMatch.option(forRegion: "中国大陆", in: cn), "2")
        let mixed: [(value: String, label: String)] = [(value: "5", label: "日本(Japanese)"),
                                                        (value: "11", label: "其它(Other)")]
        XCTAssertEqual(RegionMatch.option(forRegion: "日本", in: mixed), "5")
    }

    // MARK: 通用：质量匹配

    func testMatcherContext() {
        let mediums = [(value: "3", label: "UHD Remux"), (value: "6", label: "Remux")]
        XCTAssertEqual(QualityMatcher.match(token: "remux", attr: "medium", options: mediums), "6")
        XCTAssertEqual(QualityMatcher.match(token: "remux", attr: "medium", options: mediums,
                                            ctx: .init(isUHD: true)), "3")
        let audio = [(value: "7", label: "Other"), (value: "10", label: "WAV")]
        XCTAssertEqual(QualityMatcher.match(token: "pcm", attr: "audiocodec", options: audio), "7")
        let std = [(value: "6", label: "Other"), (value: "1", label: "1080"), (value: "5", label: "4K")]
        XCTAssertEqual(QualityMatcher.match(token: "1080p", attr: "standard", options: std), "1")
    }

    // MARK: 通用：豆瓣字段识别

    func testAutoDoubanField() {
        XCTAssertNil(NexusPHPAdapter.autoDoubanField("<form><input name=\"title\"></form>"))
        XCTAssertEqual(NexusPHPAdapter.autoDoubanField("<input type=\"text\" name=\"pt_gen\" value=\"\">"), "pt_gen")
        let row = "<tr><td class=\"rowhead\">豆瓣链接</td><td><input type=\"text\" name=\"douban_url\"></td></tr>"
        XCTAssertEqual(NexusPHPAdapter.autoDoubanField(row), "douban_url")
    }

    // MARK: 13 hdvideo：豆瓣走 douban_url，PT-Gen 框另填

    func testHDVideoFillsPTGen() throws {
        let f = try fields("hdvideo")
        XCTAssertEqual(first(f, "douban_url"), "https://movie.douban.com/subject/26339249/")
        XCTAssertEqual(first(f, "pt_gen"), "https://movie.douban.com/subject/26339249/",
                       "hdvideo 新版主题的 pt_gen 输入框必须填豆瓣链接")
    }

    // MARK: 14 海胆：季/集 + 制作组后缀

    func testHaidanSeasonEpisodeAndTeamSuffix() throws {
        let f = try fields("haidan")
        XCTAssertEqual(first(f, "season"), "3", "S03 整季 → 季数 3")
        XCTAssertEqual(first(f, "episode"), "0", "集数 0 = 全季")
        XCTAssertEqual(first(f, "team_suffix"), "LuckAni", "制作组后缀取种子名末尾发布组")
    }

    // MARK: 15 吐鲁番：必填下拉不能停在「请选择」

    func testTLFRequiredSelectsFilled() throws {
        let f = try fields("tlf")
        for name in ["type", "source_sel", "medium_sel", "codec_sel", "audiocodec_sel",
                     "standard_sel", "processing_sel", "team_sel"] {
            let v = first(f, name)
            XCTAssertNotNil(v, "\(name) 必须提交")
            XCTAssertNotNil(v, "\(name) 不能缺省")
            XCTAssertNotNil(v.flatMap { Int($0) }.flatMap { $0 > 0 ? name : nil }, "\(name) 不能停在「请选择」(0)")
        }
        XCTAssertEqual(first(f, "processing_sel"), "4", "产地日本 → JP(日)")
    }
}
