import XCTest
@testable import BoxSendKit

/// 本轮实测（源站 LuckPT 46561《娜娜2》1080p AMZN WEB-DL DDP 2.0 H.264）：
/// 冬樱的编码下拉选成了压制器 x264（要选格式项 H264/AVC），分辨率选成 1080i（要选 2K/1080p）。
final class WintersakuraOptionTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func adapter(_ id: String) -> NexusPHPAdapter {
        NexusPHPAdapter(site: SiteRegistry.prioritySites.first { $0.id == id }!,
                        client: HTTPClient(cookies: CookieStore(), userAgent: "box-send-test"))
    }

    private func source() throws -> ReleaseInfo {
        try adapter("luckpt").parseDetail(html: try fixture("luckpt-46561-webddp.html"),
                                         detailURL: "https://pt.luckpt.de/details.php?id=46561")
    }

    private func first(_ fields: [(String, String)], _ name: String) -> String? {
        fields.first(where: { $0.0 == name })?.1
    }

    /// 冬樱实测上传页：编码走格式项、分辨率走 2K/1080p
    func testRealUploadFormPicksFormatAndProgressive() throws {
        let f = try adapter("wtsakura").buildUploadFields(try source(), page: try fixture("wtsakura-upload.html"))
            .map { ($0.name, $0.value) }
        XCTAssertEqual(first(f, "type"), "401", "电影")
        XCTAssertEqual(first(f, "codec_sel[4]"), "6", "H264/AVC，不是压制器 x264")
        XCTAssertEqual(first(f, "standard_sel[4]"), "1", "2K/1080p，不是 1080i")
        XCTAssertEqual(first(f, "medium_sel[4]"), "21", "WEB-DL")
        XCTAssertEqual(first(f, "audiocodec_sel[4]"), "25", "Dolby Digital Plus")
    }

    /// 编码下拉：格式项存在时压制器名让位；只有压制器名时照选；合并写法不受影响
    func testFormatOptionBeatsEncoderOption() {
        let wtsakura: [(value: String, label: String)] = [
            ("0", "请选择一项"), ("13", "Other"), ("15", "ProRes"), ("16", "AV1"), ("11", "MPEG-2"),
            ("10", "VC-1"), ("8", "x264"), ("7", "x265"), ("6", "H264/AVC"), ("9", "H265/HEVC"),
        ]
        XCTAssertEqual(QualityMatcher.match(token: "avc", attr: "codec", options: wtsakura), "6")
        XCTAssertEqual(QualityMatcher.match(token: "hevc", attr: "codec", options: wtsakura), "9")
        let encoderOnly = wtsakura.filter { $0.label != "H264/AVC" && $0.label != "H265/HEVC" }
        XCTAssertEqual(QualityMatcher.match(token: "avc", attr: "codec", options: encoderOnly), "8",
                       "本站只有压制器写法时仍然要选上")
        let combo: [(value: String, label: String)] = [("0", "请选择"), ("1", "AVC/H.264/x264"), ("2", "HEVC/x265")]
        XCTAssertEqual(QualityMatcher.match(token: "avc", attr: "codec", options: combo), "1",
                       "「AVC/H.264/x264」本身就是格式项")
    }

    /// 分辨率：逐行压过隔行；裸数字与合并写法仍能兜住
    func testProgressiveResolutionBeatsInterlaced() {
        let wtsakura: [(value: String, label: String)] = [
            ("0", "请选择一项"), ("4", "SD"), ("3", "720p"), ("2", "1080i"),
            ("1", "2K/1080p"), ("5", "4K/2160p"), ("6", "8K/4320p"),
        ]
        XCTAssertEqual(QualityMatcher.match(token: "1080p", attr: "standard", options: wtsakura), "1")
        XCTAssertEqual(QualityMatcher.match(token: "1080i", attr: "standard", options: wtsakura), "2",
                       "隔行发布还是要认 1080i")
        XCTAssertEqual(QualityMatcher.match(token: "2160p", attr: "standard", options: wtsakura), "5")
        let bare: [(value: String, label: String)] = [("0", "请选择"), ("3", "720"), ("2", "1080"), ("5", "2160")]
        XCTAssertEqual(QualityMatcher.match(token: "1080p", attr: "standard", options: bare), "2",
                       "站点只写裸数字时按回退链兜住")
        let combo: [(value: String, label: String)] = [("0", "请选择"), ("1", "1080p/1080i/FHD")]
        XCTAssertEqual(QualityMatcher.match(token: "1080p", attr: "standard", options: combo), "1")
    }
}

/// Remux 主标题的 BluRay 写法不再逐站配置：青蛙报「标题片源拼写错误：Remux 资源，片源必须拼写为
/// BluRay」，春天同规则，所以所有目标站默认改写。
final class GlobalRemuxTitleTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testDefaultRuleRewritesOnlyRemuxReleases() {
        XCTAssertEqual(ReleaseTitle.rewrite("Some Movie 2013 1080p Blu-ray Remux AVC DTS-HD MA-GRP"),
                       "Some Movie 2013 1080p BluRay Remux AVC DTS-HD MA-GRP")
        XCTAssertEqual(ReleaseTitle.rewrite("Some Movie 2013 2160p UHD BLU-RAY REMUX HEVC"),
                       "Some Movie 2013 2160p UHD BluRay REMUX HEVC", "大小写不敏感，其余保持原样")
        XCTAssertEqual(ReleaseTitle.rewrite("Some Movie 2013 1080p Blu-ray AVC"),
                       "Some Movie 2013 1080p Blu-ray AVC", "不是 Remux 发布就不动")
        XCTAssertEqual(ReleaseTitle.rewrite("Some Movie 2013 1080p BluRay Remux AVC"),
                       "Some Movie 2013 1080p BluRay Remux AVC", "已经写对的不动")
    }

    func testSiteTokensStackOnTopOfDefaults() {
        XCTAssertEqual(ReleaseTitle.rewrite("Show S01 2015 1080p Blu-ray Remux",
                                           extraTokens: ["Blu-ray": "Blu-ray"]),
                       "Show S01 2015 1080p Blu-ray Remux", "本站可把自己要的写法盖回默认值")
    }

    /// 冬樱的 overrides 里没有 remuxTitleTokens，主标题照样要改写
    func testNexusPHPSiteWithoutOverrideRewritesTitle() throws {
        let site = SiteRegistry.prioritySites.first { $0.id == "wtsakura" }!
        XCTAssertNil(site.overrides?.remuxTitleTokens, "本站没配改写规则，靠的是全站点默认规则")
        let info = ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=1",
                               name: "Some Movie 2013 1080p Blu-ray Remux AVC LPCM 2.0-LuckWEB",
                               kind: .movie, region: "日本", sourceName: "LuckPT")
        let fields = NexusPHPAdapter(site: site, client: HTTPClient(cookies: CookieStore(), userAgent: "t"))
            .buildUploadFields(info, page: try fixture("wtsakura-upload.html")).map { ($0.name, $0.value) }
        let title = fields.first { $0.0 == "name" }?.1 ?? ""
        XCTAssertTrue(title.contains("BluRay"), "主标题要写 BluRay，实际：\(title)")
        XCTAssertFalse(title.lowercased().contains("blu-ray"), "别让源站的 Blu-ray 写法出去")
    }

    func testOtherFrameworksRewriteTitle() {
        let info = ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=1",
                               name: "Some_Movie_2013_1080p_Blu-ray_Remux_AVC-LuckWEB", kind: .movie)
        XCTAssertEqual(Unit3DAdapter.uploadTitle(info),
                       "Some Movie 2013 1080p BluRay Remux AVC-LuckWEB", "馒头的点分/下划线同样处理")
    }
}
