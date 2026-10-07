import XCTest
@testable import BoxSendKit

/// 本轮实测修正：官方标签不外打、财神题材标签、城市两步上传、朱雀详情 id
final class TargetSiteFixTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRelease() throws -> ReleaseInfo {
        let luck = SiteRegistry.prioritySites.first { $0.id == "luckpt" }!
        return try NexusPHPAdapter(site: luck, client: HTTPClient(cookies: CookieStore(), userAgent: "t"))
            .parseDetail(html: try fixture("luckpt-56812-ajax.html"),
                         detailURL: "https://pt.luckpt.de/details.php?id=56812&hit=1")
    }

    private func fields(_ siteID: String, fixtureName: String? = nil) throws -> [(String, String)] {
        let s = SiteRegistry.prioritySites.first { $0.id == siteID }!
        let a = NexusPHPAdapter(site: s, client: HTTPClient(cookies: CookieStore(), userAgent: "t"))
        return try a.buildUploadFields(sourceRelease(),
                                      page: try fixture(fixtureName ?? "\(siteID)-upload.html"))
            .map { ($0.name, $0.value) }
    }

    private func values(_ fields: [(String, String)], _ name: String) -> [String] {
        fields.filter { $0.0 == name }.map { $0.1 }
    }
    private func first(_ fields: [(String, String)], _ name: String) -> String? {
        fields.first(where: { $0.0 == name })?.1
    }

    // MARK: 1 官方是源站概念，目标站不打官方标签

    func testOfficialIsSourceOnlyTag() throws {
        let info = try sourceRelease()
        XCTAssertEqual(info.sourceTags, ["官方", "中字", "完结"])
        XCTAssertFalse(QualityTokens.canonicalTags(info).contains("official"),
                       "源站标了官方，但转出去的不是官种")
        let tags = values(try fields("ptcafe"), "tags[4][]")
        XCTAssertFalse(tags.contains("1"), "咖啡的官方复选框不该勾")
        XCTAssertTrue(tags.contains("9") && tags.contains("3"), "中字/完结照旧")
    }

    // MARK: 3 财神：按源站类别勾题材标签（缺题材标签审核不通过）

    func testGenreTagsFromSourceCategory() throws {
        XCTAssertEqual(QualityTokens.genreTags("喜剧 / 动画"), ["comedy", "anime"])
        XCTAssertEqual(QualityTokens.genreTags(""), [])
        XCTAssertEqual(QualityTokens.genreTags("剧情、爱情"), ["drama", "romance"])
        let f = try fields("cspt")
        let tags = Set(values(f, "tags[4][]"))
        XCTAssertTrue(tags.contains("8"), "喜剧标签（题材标签缺失会被打回）")
        XCTAssertTrue(tags.contains("6"), "中字")
        XCTAssertTrue(tags.contains("9"), "完结")
        XCTAssertTrue(tags.contains("10"), "Remux")
        XCTAssertEqual(first(f, "type"), "405", "动漫分类")
        XCTAssertEqual(first(f, "source_sel[4]"), "9", "媒介 Remux")
        XCTAssertEqual(first(f, "audiocodec_sel[4]"), "14", "LPCM")
        XCTAssertEqual(first(f, "standard_sel[4]"), "6", "1080p/1080i")
    }

    // MARK: 2 城市（HDCity）：种子 POST 到站外域名 + 第二步元信息表单

    func testCityUploadPostsToFormAction() throws {
        XCTAssertEqual(NexusPHPAdapter.formActionURL(try fixture("hdcity-upload.html")),
                       "https://hctres.leniter.org/upload_receiver.php?spm=TOKEN",
                       "第一步必须按页面 action 提交（takeupload.php 在这站是 404）")
        XCTAssertTrue(SiteRegistry.prioritySites.first { $0.id == "hdcity" }!.overrides!.uploadTwoStep == true)
    }

    func testCitySecondStepFields() throws {
        let f = try fields("hdcity", fixtureName: "hdcity-form.html")
        XCTAssertEqual(first(f, "name"), "Yuru Yuri S03 2015.1080p BluRay Remux AVC LPCM 2.0-LuckAni")
        XCTAssertEqual(first(f, "type"), "405", "Anim/动漫")
        XCTAssertEqual(first(f, "medium_sel"), "3", "Remux/重混流")
        XCTAssertEqual(first(f, "codec_sel"), "1", "H.264/AVC")
        XCTAssertEqual(first(f, "standard_sel"), "1", "1080p")
        XCTAssertEqual(first(f, "processing_sel"), "0", "这站 processing_sel 是 3D 下拉，保持占位（别被「其他3D/红蓝」兜底选中）")
        XCTAssertEqual(first(f, "tag1ing"), "动画/Animation", "标签下拉按文案整段匹配取值")
        XCTAssertEqual(first(f, "tag2ing"), "喜剧/Comedy", "第二个标签下拉不重复选同一个")
        XCTAssertEqual(first(f, "small_descr"), "摇曳百合 第三季 [内封中字]")
        XCTAssertEqual(first(f, "url"), "http://www.imdb.com/title/tt5420420/")
        XCTAssertEqual(first(f, "infohash"), "2fce9c05f1c6928fd95709fcff0a3670d04346d6", "第二步要带上第一步回传的 infohash")
    }

    func testOtherFallbackRejectsQualifiedOption() {
        let opts: [(value: String, label: String)] = [
            ("0", "是否 3D"), ("1", "3D H-OU/上下半宽"), ("5", "3D Alt/其他3D"),
        ]
        XCTAssertNil(QualityMatcher.match(token: "remux", attr: "processing", options: opts),
                     "带限定的「其他3D」不能当 Other 兜底")
        XCTAssertEqual(QualityMatcher.match(token: "pcm", attr: "audiocodec",
                                            options: [("0", "请选择"), ("7", "Other"), ("10", "WAV")]),
                       "7", "无 PCM 选项落 Other")
    }

    // MARK: 4 朱雀：详情链接取 id（推送时 404 的根因）

    func testTNodeDetailID() {
        XCTAssertEqual(TNodeAdapter.torrentID(fromDetail: "https://zhuque.in/torrent/info/55084"), "55084")
        XCTAssertNil(TNodeAdapter.torrentID(fromDetail: "https://zhuque.in/"))
    }

    func testTNodeAlreadyUploadedCountsAsExisting() {
        XCTAssertTrue(TNodeAdapter.isAlreadyUploaded(
            status: 400, body: #"{"status":400,"code":"TORRENT_ALREADY_UPLOAD"}"#))
        XCTAssertFalse(TNodeAdapter.isAlreadyUploaded(
            status: 400, body: #"{"status":400,"code":"INVALID_PARAMETER"}"#), "别把其它 400 当成已存在")
    }

    func testTNodeSearchKeywordsUseChineseName() throws {
        let kws = TNodeAdapter.searchKeywords(try sourceRelease())
        XCTAssertEqual(kws.first, "Yuru Yuri S03 2015.1080p BluRay Remux AVC LPCM 2.0-LuckAni")
        XCTAssertTrue(kws.contains("摇曳百合"), "朱雀检索只认中文名，得拿副标题里的中文片名去查")
    }

    func testHdcityTitleDropsBrandSuffix() throws {
        let s = SiteRegistry.prioritySites.first { $0.id == "hdcity" }!
        let a = NexusPHPAdapter(site: s, client: HTTPClient(cookies: CookieStore(), userAgent: "t"))
        let html = "<html><head><title>Yuru Yuri S03 2015.1080p BluRay Remux AVC LPCM 2.0-LuckAni"
            + " - An Advanced City For Entertainment - HDCiTY</title></head>"
            + "<body><a href=\"download?id=68284&cuhash=abc\">down</a></body></html>"
        let info = try a.parseDetail(html: html, detailURL: "https://hdcity.city/details.php?id=68284")
        XCTAssertEqual(info.name, "Yuru Yuri S03 2015.1080p BluRay Remux AVC LPCM 2.0-LuckAni")
    }

    func testDownloadNoticeFromHTMLPage() {
        let html = "<html><body><div class='message'>抱歉，该资源正在审核中，暂时无法下载</div></body></html>"
        XCTAssertTrue(NexusPHPAdapter.downloadNotice(html).contains("审核"), "推送失败要说明站点原因")
        XCTAssertEqual(NexusPHPAdapter.downloadNotice("<html><body>hello</body></html>"), "")
    }
}
