import XCTest
@testable import BoxSendKit

/// 新版 NexusPHP 动态能力测试：质量下拉动态匹配 / 多 type 下拉 mode 定位 / 动态标签 / technical_info
final class DynamicNexusTests: XCTestCase {
    private let client = HTTPClient(cookies: CookieStore(), userAgent: "box-send-test")

    private func adapter(_ id: String = "city13", url: String = "https://13city.org/",
                         overrides: SiteOverride = .nexusCN) -> NexusPHPAdapter {
        NexusPHPAdapter(site: SiteConfig(id: id, name: id, url: url, framework: .nexusPHP, enabled: true, overrides: overrides),
                        client: client)
    }

    private func makeInfo(_ name: String, kind: ReleaseKind = .movie,
                          subtitle: String = "副标题", forbid: Bool = false,
                          mediainfo: String = "General\nUnique ID : 123") -> ReleaseInfo {
        ReleaseInfo(siteID: "src", detailURL: "https://src.example/details.php?id=1",
                    name: name, descr: "<p>剧情简介</p>", imdb: "tt1234567", douban: "3564499",
                    kind: kind, isForbidReseed: forbid, subtitle: subtitle, mediainfo: mediainfo)
    }

    private func field(_ fields: [HTTPClient.MultipartField], _ name: String) -> String? {
        fields.last(where: { $0.name == name })?.value
    }

    // MARK: - QualityMatcher

    func testQualityMatcherTokenMatch() {
        // agsvpt 实测表
        let medium: [(String, String)] = [("0", "请选择一项"), ("11", "UHD Blu-ray"), ("1", "Blu-ray"), ("3", "Remux"), ("10", "WEB-DL"), ("5", "HDTV"), ("2", "DVD"), ("12", "Track")]
        XCTAssertEqual(QualityMatcher.match(token: "remux", attr: "medium", options: medium), "3")
        XCTAssertEqual(QualityMatcher.match(token: "uhdbd", attr: "medium", options: medium), "11")
        XCTAssertEqual(QualityMatcher.match(token: "bluray", attr: "medium", options: medium), "1")
        XCTAssertEqual(QualityMatcher.match(token: "webdl", attr: "medium", options: medium), "10")
        XCTAssertEqual(QualityMatcher.match(token: "track", attr: "medium", options: medium), "12")
        let standard: [(String, String)] = [("0", "请选择一项"), ("4", "480p/480i"), ("3", "720p/720i"), ("1", "1080p/1080i"), ("5", "4K/2160p/2160i"), ("6", "8K/4320p/4320i")]
        XCTAssertEqual(QualityMatcher.match(token: "2160p", attr: "standard", options: standard), "5")
        XCTAssertEqual(QualityMatcher.match(token: "1080p", attr: "standard", options: standard), "1")
        XCTAssertEqual(QualityMatcher.match(token: "1440p", attr: "standard", options: standard), "1") // 无 1440p 选项 -> 回退 1080p
        let codec: [(String, String)] = [("0", "请选择一项"), ("1", "H.264/AVC"), ("6", "H.265/HEVC"), ("2", "VC-1"), ("4", "MPEG-2"), ("12", "AV1")]
        XCTAssertEqual(QualityMatcher.match(token: "hevc", attr: "codec", options: codec), "6")
        XCTAssertEqual(QualityMatcher.match(token: "avc", attr: "codec", options: codec), "1")
        let audio: [(String, String)] = [("0", "请选择一项"), ("1", "FLAC"), ("3", "DTS"), ("8", "DTS-HD MA"), ("18", "DTS:X"), ("9", "TrueHD"), ("11", "DD/AC3"), ("19", "DDP/E-AC3")]
        XCTAssertEqual(QualityMatcher.match(token: "dtsma", attr: "audiocodec", options: audio), "8")
        XCTAssertEqual(QualityMatcher.match(token: "dtsx", attr: "audiocodec", options: audio), "18")
        XCTAssertEqual(QualityMatcher.match(token: "ac3", attr: "audiocodec", options: audio), "11")
        XCTAssertEqual(QualityMatcher.match(token: "eac3", attr: "audiocodec", options: audio), "19")
        XCTAssertEqual(QualityMatcher.match(token: "dts", attr: "audiocodec", options: audio), "3")
    }

    func testQualityMatcherFallback() {
        // 无 "DTS-HD MA" 选项但有 "DTS-HD"（btschool/劳改所风格）-> 选 DTS-HD，不能退到 TrueHD
        let audio: [(String, String)] = [("0", "请选择"), ("11", "TrueHD"), ("3", "DTS-HD/DTS"), ("10", "AC3"), ("1", "FLAC")]
        XCTAssertEqual(QualityMatcher.match(token: "dtsma", attr: "audiocodec", options: audio), "3")
        // 只有 TrueHD 时才回退 TrueHD
        let audio2: [(String, String)] = [("0", "请选择"), ("11", "TrueHD"), ("10", "AC3"), ("1", "FLAC")]
        XCTAssertEqual(QualityMatcher.match(token: "dtsma", attr: "audiocodec", options: audio2), "11")
        // 3D 分辨率选项不算 1080p（52PT 的 "1080P-3D" 会盖过 "2K/1080p"）
        let std3d: [(String, String)] = [("0", "请选择"), ("1", "2K/1080p"), ("4", "1080P-3D")]
        XCTAssertEqual(QualityMatcher.match(token: "1080p", attr: "standard", options: std3d), "1")
        // 无 HEVC -> 回退 AVC
        let codec: [(String, String)] = [("0", "请选择"), ("1", "H.264"), ("2", "VC-1")]
        XCTAssertEqual(QualityMatcher.match(token: "hevc", attr: "codec", options: codec), "1")
        // 无匹配 -> first 有效选项
        let weird: [(String, String)] = [("0", "请选择一项"), ("1", "视频"), ("2", "音频")]
        XCTAssertEqual(QualityMatcher.match(token: "remux", attr: "medium", options: weird), "1")
    }

    func testMatchYear() {
        let years: [(String, String)] = [("0", "请选择一项"), ("17", "2025"), ("1", "2023"), ("15", "2010年前")]
        XCTAssertEqual(QualityMatcher.matchYear(2023, options: years), "1")
        XCTAssertEqual(QualityMatcher.matchYear(2009, options: years), "15")
        let onlyOlder: [(String, String)] = [("0", "请选择"), ("1", "2010"), ("2", "2011")]
        XCTAssertEqual(QualityMatcher.matchYear(2009, options: onlyOlder), "1")
    }

    // MARK: - 新版表单：多 type 下拉 + xxx_sel[mode] + 动态标签 + technical_info

    private let newStylePage = """
    <html><body>
    <form action="takeupload.php" enctype="multipart/form-data">
    <input type="hidden" name="user_id" value="42" />
    <input type="text" name="name" value="" />
    <input type="text" name="small_descr" value="" />
    <input type="text" name="url" value="" />
    <input type="file" name="file" />
    <input type="text" name="type" style="display:none" />
    <select name="type" id="browsecat" data-mode='4'>
      <option value="0">请选择</option>
      <option value="401">电影/Movies</option>
      <option value="402">剧集/TV Series</option>
      <option value="403">综艺/TV Shows</option>
      <option value="405">动漫/Animations</option>
      <option value="413">纪录片/Docmentaries</option>
    </select>
    <select name="type" id="specialcat" data-mode='9'>
      <option value="0">请选择</option>
      <option value="610">AV(有碼)/HD Censored</option>
    </select>
    <textarea name="descr"></textarea>
    <textarea name="technical_info"></textarea>
    <tr relation="mode_4">
    <select name="medium_sel[4]"><option value="0">请选择一项</option><option value="1">Blu-ray</option><option value="11">UHD Blu-ray</option><option value="3">Remux</option><option value="10">WEB-DL</option></select>
    <select name="codec_sel[4]"><option value="0">请选择一项</option><option value="1">AVC/H.264/x264</option><option value="2">HEVC/H.265/x265</option></select>
    <select name="standard_sel[4]"><option value="0">请选择一项</option><option value="1">8K</option><option value="2">4K</option><option value="3">1080p</option></select>
    <select name="audiocodec_sel[4]"><option value="0">请选择一项</option><option value="3">DTS</option><option value="8">DTS-HD MA</option></select>
    <select name="team_sel[4]"><option value="0">请选择一项</option><option value="1">13City</option><option value="11">Other</option></select>
    </tr>
    <tr relation="mode_9">
    <select name="medium_sel[9]"><option value="0">请选择一项</option><option value="1">Blu-ray</option><option value="3">Remux</option></select>
    </tr>
    <label><input type="checkbox" name="tags[4][]" value="1" />禁转</label>
    <label><input type="checkbox" name="tags[4][]" value="6" />中字</label>
    <label><input type="checkbox" name="tags[4][]" value="7" />HDR</label>
    <input type="checkbox" name="uplver" value="yes" />
    </form>
    </body></html>
    """

    func testNewStyleUploadFields() {
        let a = adapter()
        let info = makeInfo("Test Movie 2020 2160p UHD BluRay REMUX DV HDR HEVC DTS-HD MA 5.1-GRP",
                            subtitle: "测试电影（简体中文字幕）", forbid: true)
        let fields = a.buildUploadFields(info, page: newStylePage)
        XCTAssertEqual(field(fields, "type"), "401")
        // 仅填充所选分类（mode 4）的质量下拉
        XCTAssertEqual(field(fields, "medium_sel[4]"), "3")   // Remux
        XCTAssertEqual(field(fields, "codec_sel[4]"), "2")    // HEVC
        XCTAssertEqual(field(fields, "standard_sel[4]"), "2") // 4K/2160p
        XCTAssertEqual(field(fields, "audiocodec_sel[4]"), "8") // DTS-HD MA
        // 非所属 mode 的下拉不动
        XCTAssertNil(field(fields, "medium_sel[9]"))
        // 动态标签：禁转 + 中字
        let tags = fields.filter { $0.name == "tags[4][]" }.map { $0.value }
        XCTAssertTrue(tags.contains("1"), "禁转")
        XCTAssertTrue(tags.contains("6"), "中字")
        XCTAssertFalse(tags.contains("7"), "无 HDR 标记不勾")
        // technical_info 存在 -> mediainfo 独立提交，简介不内嵌
        XCTAssertEqual(field(fields, "technical_info"), "General\nUnique ID : 123")
        XCTAssertFalse(field(fields, "descr")?.contains("Unique ID") ?? true)
        // 基础字段
        XCTAssertEqual(field(fields, "url"), "http://www.imdb.com/title/tt1234567/")
        XCTAssertEqual(field(fields, "small_descr"), "测试电影（简体中文字幕）")
        XCTAssertEqual(field(fields, "uplver"), "yes")
    }

    func testNewStyleSeriesKindPicksSeriesOption() {
        let a = adapter()
        let info = makeInfo("Some Show S01E01 1080p BluRay x264 DTS 5.1-GRP", kind: .series)
        let fields = a.buildUploadFields(info, page: newStylePage)
        XCTAssertEqual(field(fields, "type"), "402")
        XCTAssertEqual(field(fields, "medium_sel[4]"), "1") // Blu-ray（非 Remux）
        XCTAssertEqual(field(fields, "codec_sel[4]"), "1")  // AVC
    }

    func testStaticCategoryMapLocatesCorrectSelect() {
        // discfan 风格：静态表值 410 只在第一个下拉里 -> 仍命中 mode 4
        let ov = SiteOverride(uploadPath: "upload.php", uploadActionPath: "takeupload.php",
                              titleField: "name", imdbField: "url",
                              imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
                              categoryField: "type",
                              categoryMap: ["movie": 410, "series": 411, "tvshow": 416, "documentary": 413, "anime": 419, "music": 414, "other": 410],
                              extraUploadFields: ["uplver": "yes"], subtitleField: "small_descr")
        let page = """
        <html><body><form action="takeupload.php">
        <select name="type" data-mode='4'>
          <option value="401">电影 - 中国大陆</option><option value="410">电影 - 世界</option>
          <option value="411">剧集</option><option value="413">纪录</option><option value="414">音乐</option>
          <option value="416">综艺</option><option value="419">动漫</option>
        </select>
        <textarea name="descr"></textarea>
        <select name="medium_sel[4]"><option value="0">请选择</option><option value="7">Blu-ray Disc</option><option value="131">Remux</option></select>
        <select name="standard_sel[4]"><option value="0">请选择</option><option value="6">2160p</option><option value="4">1080p</option></select>
        </form></body></html>
        """
        let a = adapter("discfan", url: "https://discfan.net/", overrides: ov)
        let info = makeInfo("Doc Movie 2019 2160p UHD BluRay REMUX HEVC DTS-HD MA 5.1-GRP", kind: .documentary)
        let fields = a.buildUploadFields(info, page: page)
        XCTAssertEqual(field(fields, "type"), "413")
        XCTAssertEqual(field(fields, "medium_sel[4]"), "131")
        XCTAssertEqual(field(fields, "standard_sel[4]"), "6")
    }

    // MARK: - 旧版裸 xxx_sel 表单（pt52 风格）

    func testOldStyleBareSelects() {
        let page = """
        <html><body><form action="takeupload.php">
        <input type="text" name="name" /><input type="text" name="url" /><textarea name="descr"></textarea>
        <select name="type"><option value="0">请选择</option><option value="401">电影</option><option value="402">剧集</option><option value="413">纪录片</option></select>
        <select name="medium_sel"><option value="0">请选择</option><option value="1">Blu-ray</option><option value="3">Remux</option></select>
        <select name="standard_sel"><option value="0">请选择</option><option value="1">1080p</option><option value="5">2160p</option></select>
        <select name="codec_sel"><option value="0">请选择</option><option value="1">H.264</option><option value="2">H.265</option></select>
        <select name="audiocodec_sel"><option value="0">请选择</option><option value="1">FLAC</option><option value="3">AC3</option></select>
        </form></body></html>
        """
        let a = adapter("pt52", url: "https://52pt.site/")
        let info = makeInfo("Old Movie 2015 1080p BluRay AVC AC3-GRP")
        let fields = a.buildUploadFields(info, page: page)
        XCTAssertEqual(field(fields, "type"), "401")
        XCTAssertEqual(field(fields, "medium_sel"), "1")
        XCTAssertEqual(field(fields, "standard_sel"), "1")
        XCTAssertEqual(field(fields, "codec_sel"), "1")
        XCTAssertEqual(field(fields, "audiocodec_sel"), "3")
        // 无 technical_info -> mediainfo 内嵌简介（bbcode [quote]）
        XCTAssertTrue(field(fields, "descr")?.contains("Unique ID") ?? false)
    }

    // MARK: - 年份型 codec 下拉（ggpt 风格）

    func testYearBasedCodecSelect() {
        let page = """
        <html><body><form action="takeupload.php">
        <input type="text" name="name" /><textarea name="descr"></textarea>
        <select name="type"><option value="0">请选择</option><option value="412">9KG-PC</option><option value="418">9KG-其他</option></select>
        <select name="codec_sel"><option value="0">请选择一项</option><option value="17">2025</option><option value="16">2024</option><option value="15">2010年前</option></select>
        </form></body></html>
        """
        let ov = SiteOverride(uploadPath: "upload.php", uploadActionPath: "takeupload.php",
                              titleField: "name", imdbField: "url",
                              imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
                              categoryField: "type",
                              categoryMap: ["movie": 412, "series": 412, "tvshow": 412, "anime": 412, "documentary": 412, "music": 418, "other": 418],
                              extraUploadFields: ["uplver": "yes"], subtitleField: "small_descr")
        let a = adapter("ggpt", url: "https://www.gamegamept.com/", overrides: ov)
        let info = makeInfo("Some Game 2009 9KG PC-GRP")
        let fields = a.buildUploadFields(info, page: page)
        XCTAssertEqual(field(fields, "type"), "412")
        XCTAssertEqual(field(fields, "codec_sel"), "15") // 2009 -> 2010年前
    }

    // MARK: - 显式表优先于动态匹配

    func testExplicitQualitySelectsWin() {
        // 影 站：显式 qualitySelects 表（字符串值），动态填充不得覆盖
        let ov = SiteOverride.shadow
        let page = """
        <html><body><form action="video_upload_act.php">
        <input type="text" name="name" /><input type="text" name="imdb_url" /><textarea name="descr"></textarea>
        <select name="tr_category"><option value="mo">电影</option><option value="tv">剧集</option></select>
        <select name="tr_source"><option value="s42">BD 原盘 1080p</option><option value="s52">UHD 原盘 2160p</option></select>
        <select name="tr_video_codec"><option value="1">AVC</option><option value="2">HEVC</option></select>
        <select name="tr_resolution"><option value="r3">1080p</option><option value="r4">2160p</option></select>
        </form></body></html>
        """
        let a = adapter("shadow", url: "https://star-space.net/", overrides: ov)
        let info = makeInfo("Test Movie 2020 2160p UHD BluRay REMUX DV HDR HEVC DTS-HD MA 5.1-GRP")
        let fields = a.buildUploadFields(info, page: page)
        XCTAssertEqual(field(fields, "tr_category"), "mo")
        XCTAssertEqual(field(fields, "tr_source"), "s52")
        XCTAssertEqual(field(fields, "tr_video_codec"), "2")
        XCTAssertEqual(field(fields, "tr_resolution"), "r4")
    }
}
