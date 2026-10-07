import XCTest
@testable import BoxSendKit

/// YZYY（Discuz 插件发种）字段推断 + 批量检测的分组顺序
final class DiscuzAndOrderTests: XCTestCase {
    private let form = """
    <form method="post" action="plugin.php?id=dz_seed:publish&formhash=abc" enctype="multipart/form-data">
    <input type="hidden" name="formhash" value="abc123" />
    <input type="hidden" name="mod" value="publish" />
    <table>
    <tr><td>种子名称</td><td><input type="text" name="seed_name" /></td></tr>
    <tr><td>所属分类</td><td><select name="cate"><option value="0">请选择</option><option value="7">动漫</option><option value="3">电影</option></select></td></tr>
    <tr><td>产地地区</td><td><select name="area"><option value="0">请选择</option><option value="1">中国大陆</option><option value="2">美国</option><option value="5">日本</option><option value="9">其它</option></select></td></tr>
    <tr><td>种子说明</td><td><textarea name="seed_desc"></textarea></td></tr>
    <tr><td>豆瓣</td><td><input type="text" name="db_link" /></td></tr>
    <tr><td>种子文件</td><td><input type="file" name="torrent_file" /></td></tr>
    <tr><td></td><td><input type="submit" name="publishsubmit" value="提交" /></td></tr>
    </table></form>
    """

    private func adapter() -> DiscuzAdapter {
        let cfg = SiteRegistry.prioritySites.first { $0.id == "yzyy" }!
        return DiscuzAdapter(site: cfg, client: HTTPClient(cookies: CookieStore(), userAgent: "box-send-test"))
    }

    func testPublishFormFieldsInferredByLabel() throws {
        let info = ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=56812",
                               name: "Yuru Yuri S03 2015 1080p BluRay Remux AVC LPCM 2.0-LuckAni",
                               descr: "<p>原盘来自U2</p>", douban: "26339249", kind: .anime,
                               region: "日本", sourceName: "LuckPT", sourceTags: ["官方"])
        let (fields, fileField) = adapter().buildFields(info, page: form)
        let dict = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value) })
        XCTAssertEqual(dict["formhash"], "abc123", "Discuz 缺 formhash 会直接拒收")
        XCTAssertEqual(dict["mod"], "publish")
        XCTAssertEqual(dict["seed_name"], "Yuru Yuri S03 2015 1080p BluRay Remux AVC LPCM 2.0-LuckAni")
        XCTAssertEqual(dict["cate"], "7", "按行标签找到分类下拉并选中动漫")
        XCTAssertEqual(dict["area"], "5", "产地日本")
        XCTAssertTrue(dict["seed_desc"]?.contains("原盘来自U2") == true)
        XCTAssertEqual(dict["db_link"], "https://movie.douban.com/subject/26339249/")
        XCTAssertEqual(dict["publishsubmit"], "提交")
        XCTAssertEqual(fileField, "torrent_file")
    }

    func testCookieCheckOrderFollowsGroupLayout() {
        let sites: [SiteConfig] = ["a", "b", "c", "d"].map {
            SiteConfig(id: $0, name: $0, url: "https://\($0).example/", framework: .nexusPHP, enabled: true)
        }
        let groups = [GroupConfig(name: "一组", sites: ["c", "a"]), GroupConfig(name: "二组", sites: ["b"])]
        XCTAssertEqual(sites.sortedBySiteGroup(groups: groups, id: { $0.id }).map(\.id), ["c", "a", "b", "d"],
                       "按分组排列先后检测，未分组排最后")
    }

    func testRousiIsAPIKeySiteAndYzyyRegistered() {
        let rousi = SiteRegistry.prioritySites.first { $0.id == "rousi" }!
        XCTAssertTrue(rousi.overrides?.usesAPIKey == true, "肉丝标记为 API Key 站，卡片不再显示「无 cookie」")
        XCTAssertEqual(rousi.overrides?.apiKeyStyle, "peergo")
        let yzyy = SiteRegistry.prioritySites.first { $0.id == "yzyy" }!
        XCTAssertEqual(yzyy.framework, .discuz)
        XCTAssertEqual(yzyy.overrides?.uploadPath, "plugin.php?id=dz_seed:publish")
    }
}
