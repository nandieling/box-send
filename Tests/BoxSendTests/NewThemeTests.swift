import XCTest
@testable import BoxSendKit

/// 新版 NexusPHP 主题（子下拉名字带模板号后缀，如 medium_sel[4]）与海胆的季/集字段
final class NewThemeTests: XCTestCase {
    private func site(_ id: String) -> SiteConfig { SiteRegistry.prioritySites.first { $0.id == id }! }

    private func fields(_ siteID: String, _ info: ReleaseInfo, _ page: String) -> [String: String] {
        let a = NexusPHPAdapter(site: site(siteID), client: HTTPClient(cookies: CookieStore(), userAgent: "box-send-test"))
        var seen = Set<String>()
        var out: [String: String] = [:]
        for f in a.buildUploadFields(info, page: page) where seen.insert(f.name).inserted {
            out[f.name] = f.value
        }
        return out
    }

    /// HDVideo 新版主题：后缀 [4] 与分类 ID(405) 不同
    private let hdvPage = """
    <form action="takeupload.php" enctype="multipart/form-data">
    <input name="name" /><textarea name="descr"></textarea>
    <select name="type"><option value="0">请选择</option><option value="401">电影</option><option value="405">动漫</option></select>
    <select name="medium_sel[4]"><option value="0">请选择一项</option><option value="14">WEB-DL</option><option value="12">Remux</option><option value="19">Other</option></select>
    <select name="standard_sel[4]"><option value="0">请选择一项</option><option value="8">1080p</option><option value="11">Other</option></select>
    <select name="codec_sel[4]"><option value="0">请选择一项</option><option value="7">AVC/H.264/x264</option><option value="11">Other</option></select>
    <select name="audiocodec_sel[4]"><option value="0">请选择一项</option><option value="8">LPCM/PCM</option><option value="12">WAV</option><option value="7">Other</option></select>
    <select name="team_sel[4]"><option value="0">请选择一项</option><option value="2">HDVMV</option><option value="4">Other</option></select>
    <select name="region_sel[4]"><option value="0">请选择</option><option value="1">中国大陆</option><option value="2">美国</option><option value="3">韩国</option><option value="7">日本</option><option value="28">其他地区</option></select>
    </form>
    """

    private var info: ReleaseInfo {
        ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=56812",
                    name: "Yuru Yuri S03 2015 1080p BluRay Remux AVC LPCM 2.0-LuckAni",
                    kind: .anime, region: "日本", sourceName: "LuckPT", sourceTags: ["官方", "中字", "完结"])
    }

    func testSuffixedSelectsMatchedByPageNames() {
        let f = fields("hdvideo", info, hdvPage)
        XCTAssertEqual(f["type"], "405", "动画类站点里 动漫 优先于 动画")
        XCTAssertEqual(f["medium_sel[4]"], "12", "子下拉后缀不等于分类 ID 时也要按页面实际名字填")
        XCTAssertEqual(f["standard_sel[4]"], "8")
        XCTAssertEqual(f["audiocodec_sel[4]"], "8", "LPCM/PCM 而不是 WAV")
        XCTAssertEqual(f["region_sel[4]"], "7", "产地日本")
        XCTAssertEqual(f["team_sel[4]"], "4", "转种没有本站制作组，选 Other")
    }

    /// 来源引用以「批量转种」页的源站引用可选项为准，官种不再自动加致谢
    func testSourceQuoteFollowsManualOptionOnly() {
        var manual = self.info
        manual.descr = "<p>剧情简介</p>"
        manual.extraQuote = "转载自LuckPT，感谢发布者。"
        XCTAssertTrue((fields("hdvideo", manual, hdvPage)["descr"] ?? "")
                      .hasPrefix("[quote]\n转载自LuckPT，感谢发布者。\n[/quote]\n"),
                      String((fields("hdvideo", manual, hdvPage)["descr"] ?? "").prefix(80)))
        var plain = self.info
        plain.descr = "<p>剧情简介</p>"
        let d = fields("hdvideo", plain, hdvPage)["descr"] ?? ""
        XCTAssertFalse(d.hasPrefix("[quote]"), "未勾选源站引用：简介原样，不自动加引用块 \(d.prefix(60))")
    }

    func testSeasonAndEpisodeFields() {
        let page = "<input name=\"season\" /><input name=\"episode\" /><input name=\"collages\" type=\"checkbox\" />"
        func values(_ name: String, _ tags: [String] = []) -> [String: String] {
            var info = self.info
            info.name = name
            info.sourceTags = tags
            return Dictionary(uniqueKeysWithValues: NexusPHPAdapter.seasonEpisodeValues(info, page: page))
        }
        XCTAssertEqual(values("Yuru Yuri S03 2015 1080p BluRay Remux-x")["season"], "3", "整季：填季数")
        XCTAssertEqual(values("Yuru Yuri S03 2015 1080p BluRay Remux-x")["episode"], "0", "集数 0 = 全季")
        XCTAssertEqual(values("Yuru Yuri S03E05 2015 1080p WEB-DL-x")["episode"], "5", "单集填集数")
        XCTAssertEqual(values("Yuru Yuri S01-S03 2015 1080p BluRay-x")["collages"], "1", "多季要勾合集")
        var movie = self.info
        movie.name = "Some Movie 2015 1080p BluRay-x"
        movie.kind = .movie
        XCTAssertNil(Dictionary(uniqueKeysWithValues: NexusPHPAdapter.seasonEpisodeValues(movie, page: page))["season"],
                     "电影不填季数")
        // 海胆：电视剧/综艺/动画/纪录片分集资源不填季/集直接拒收，站点约定 0 = 不区分季 / 全季
        var doc = self.info
        doc.name = "Food Inc 2009 1080p BluRay REMUX VC-1-Ursuya"
        doc.kind = .documentary
        let dv = Dictionary(uniqueKeysWithValues: NexusPHPAdapter.seasonEpisodeValues(doc, page: page))
        XCTAssertEqual(dv["season"], "0", "连载类分类推不出季数时补 0")
        XCTAssertEqual(dv["episode"], "0", "推不出集数时补 0")
    }

    private func fixture(_ name: String) -> String {
        let p = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name).path
        return (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
    }

    /// HDVideo 新版主题把「风格」做成必填复选框组（style_sel[4][]），
    /// 纪录片没有对应题材时退到组内中性的「剧情」，否则整单被「请至少选择一个风格」打回
    func testStyleCheckboxGroupIsRequired() {
        let page = fixture("hdvideo-upload.html")
        XCTAssertTrue(page.contains("style_sel[4][]"), "fixture 应含风格组")
        var doc = self.info
        doc.name = "Food Inc 2009 1080p BluRay REMUX VC-1 DTS-HD MA 5.1-Ursuya@LuckDocu"
        doc.kind = .documentary
        doc.genre = "纪录片"
        doc.region = "美国"
        XCTAssertEqual(fields("hdvideo", doc, page)["style_sel[4][]"], "6", "无对应题材时选剧情")
        var comedy = doc
        comedy.kind = .movie
        comedy.genre = "喜剧 / 剧情"
        XCTAssertEqual(Set(allFields("hdvideo", comedy, page).filter { $0.0 == "style_sel[4][]" }.map(\.1)),
                       Set(["2", "6"]), "题材命中几个勾几个")
    }

    /// IT之家 / 凤凰既没有纪录片版块也没有「其他」：按就近体裁退到电影，别让 type 停在 0
    func testCategorySubstitutesWhenSiteLacksTheCategory() {
        let page = """
        <form><select name="type"><option value="0">请选择</option><option value="405">动画</option>
        <option value="404">漫画</option><option value="401">电影</option><option value="402">电视剧</option></select></form>
        """
        for id in ["itzmx", "fenghuang"] {
            var doc = self.info
            doc.kind = .documentary
            XCTAssertEqual(fields(id, doc, page)["type"], "401", "\(id)：纪录片退到电影")
        }
    }

    /// 同名多次的字段（复选框组）要看全部值
    private func allFields(_ siteID: String, _ info: ReleaseInfo, _ page: String) -> [(String, String)] {
        let a = NexusPHPAdapter(site: site(siteID),
                                client: HTTPClient(cookies: CookieStore(), userAgent: "box-send-test"))
        return a.buildUploadFields(info, page: page).map { ($0.name, $0.value) }
    }
}

/// Discuz 两步发帖（YZYY）的结果判定：审核队列也算发出，验证码页不能误判成成功
final class DiscuzPostResultTests: XCTestCase {
    private func fixture(_ name: String) -> String {
        let p = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name).path
        return (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
    }

    func testReviewQueuePageYieldsThreadID() {
        let html = fixture("yzyy-post-review.html")
        XCTAssertTrue(html.contains("需要审核"), "fixture 应是审核提示页")
        XCTAssertEqual(DiscuzThreadPost.threadID(html), "7460", "tid 取自提示块里的 JS 跳转")
    }

    /// 验证码失败的提示页侧栏也有 thread 链接，整页找会误判成功
    func testCaptchaErrorPageHasNoThreadID() {
        let html = fixture("yzyy-post-captcha-error.html")
        XCTAssertTrue(html.contains("验证码填写错误"))
        XCTAssertNil(DiscuzThreadPost.threadID(html))
    }

    /// 验证码字体用西里尔字形：Vision 读出「К6КK」必须转写成 k6kk
    func testSeccodeLookAlikeTransliteration() {
        XCTAssertEqual(SeccodeOCR.normalize("К6КK"), "k6kk")
        XCTAssertEqual(SeccodeOCR.normalize("3H4E"), "3h4e")
        XCTAssertNil(SeccodeOCR.normalize("k6k"), "位数不对算没认出来，交给调用方重试")
        XCTAssertEqual(SeccodeOCR.normalize("k6k-k"), "k6kk", "连字符按噪声剔除，认错会自动换图重试")
    }
}
