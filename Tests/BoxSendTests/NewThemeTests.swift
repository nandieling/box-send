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

    func testOfficialSourceAddsQuotedAttribution() {
        let f = fields("hdvideo", info, hdvPage)
        XCTAssertTrue((f["descr"] ?? "").hasPrefix("[quote]\n转载自LuckPT，感谢发布者。\n[/quote]\n"),
                      String((f["descr"] ?? "").prefix(80)))
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
        XCTAssertNil(values("Some Movie 2015 1080p BluRay-x")["season"], "电影不填季数")
    }
}
