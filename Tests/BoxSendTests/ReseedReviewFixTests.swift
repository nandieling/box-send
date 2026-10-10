import XCTest
@testable import BoxSendKit

/// 用户实测反馈四处修正（LuckPT 43749 银魂剧场版 -> 彩虹岛 / 观众 / 多站 / 套）：
/// 来源勾成官方、动画类型落到「其他」且制作没勾动画、BDInfo 没随种转出去、
/// TTG 报「已存在」后找不回种子链接导致推不进下载器。
final class ReseedReviewFixTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func adapter(_ id: String) -> NexusPHPAdapter {
        guard let site = SiteRegistry.prioritySites.first(where: { $0.id == id }) else {
            return NexusPHPAdapter(site: SiteConfig(id: id, name: id, url: "https://example.com/",
                                                    framework: .nexusPHP, enabled: true),
                                   client: client)
        }
        return NexusPHPAdapter(site: SiteRegistry.effectiveSite(site), client: client)
    }

    private let client = HTTPClient(cookies: CookieStore(), userAgent: "BoxSendTest")

    /// 源站（LuckPT 新版主题）：BDInfo 在「媒体信息」行的 <details><pre> 里，
    /// 站点写的是 BDInfo 那套字段名（DISC INFO / PLAYLIST REPORT），不是 MediaInfo
    private func sourceRelease() throws -> ReleaseInfo {
        let html = try fixture("luckpt-43749-bdinfo.html")
        return try adapter("luckpt").parseDetail(html: html,
                                                detailURL: "https://pt.luckpt.de/details.php?id=43749")
    }

    private func values(_ fields: [HTTPClient.MultipartField], _ name: String) -> [String] {
        fields.filter { $0.name == name }.map { $0.value }
    }
    private func value(_ fields: [HTTPClient.MultipartField], _ name: String) -> String? {
        values(fields, name).last
    }

    // MARK: - 1. 彩虹岛「来源」：转种是转载，不是官方

    func testChdbitsSourceIsReseedNotOfficial() throws {
        let info = try sourceRelease()
        let fields = adapter("chdbits").buildUploadFields(info, page: try fixture("chdbits-upload.html"))
        XCTAssertEqual(value(fields, "source_sel"), "7",
                       "彩虹岛来源表是 1=官方 / 7=转载：转种必须落在转载")
        XCTAssertNotEqual(value(fields, "source_sel"), "1", "不能勾官方")
    }

    func testSourceOwnershipDetection() {
        XCTAssertTrue(NexusPHPAdapter.isSourceOwnershipLabel("官方"))
        XCTAssertTrue(NexusPHPAdapter.isSourceOwnershipLabel("原创"))
        XCTAssertFalse(NexusPHPAdapter.isSourceOwnershipLabel("转载"))
        XCTAssertFalse(NexusPHPAdapter.isSourceOwnershipLabel("Blu-ray"))
        // 蟹黄堡 / 青蛙的 source_sel 实为媒介表，不走「转载」那套
        XCTAssertTrue(QualityMatcher.hasMediumOption([("1", "BluRay"), ("4", "Remux")]))
        XCTAssertFalse(QualityMatcher.hasMediumOption([("1", "官方"), ("7", "转载"), ("9", "原创")]))
    }

    // MARK: - 2. 观众：动画入电影/剧集，且「制作」勾动画

    func testAudiencesAnimeMovieGoesToMoviesAndChecksAnimationTag() throws {
        let info = try sourceRelease()
        let fields = adapter("audiences").buildUploadFields(info, page: try fixture("audiences-upload.html"))
        XCTAssertEqual(value(fields, "type"), "401", "观众没有动漫版块，409 是「其他」：动画电影应入 401 电影")
        XCTAssertTrue(values(fields, "tags[]").contains("dh"), "制作一栏要勾「动画」（tags[]=dh）")
    }

    func testAudiencesAnimeSeriesGoesToTvSeries() throws {
        var info = try sourceRelease()
        info.name = "Yuru Yuri S03 2015.1080p BluRay Remux AVC LPCM 2.0-LuckAni"
        let fields = adapter("audiences").buildUploadFields(info, page: try fixture("audiences-upload.html"))
        XCTAssertEqual(value(fields, "type"), "402", "动画剧集应入 402 剧集")
        XCTAssertTrue(values(fields, "tags[]").contains("dh"), "动画剧集同样要勾「动画」")
    }

    func testReleaseShapeDetectsEpisodicNames() {
        XCTAssertEqual(QualityTokens.releaseShape(from: "Yuru Yuri S03 2015 1080p"), "series")
        XCTAssertEqual(QualityTokens.releaseShape(from: "Yuru Yuri S03E05 1080p"), "series")
        XCTAssertEqual(QualityTokens.releaseShape(from: "Somewhere 第12集 1080p"), "series")
        XCTAssertEqual(QualityTokens.releaseShape(from: "The Wire 4x03 1080p"), "series")
        XCTAssertEqual(QualityTokens.releaseShape(from: "Some Movie 2013 1080p BluRay"), "movie")
        // 分辨率与音轨里的数字不该被当集数
        XCTAssertEqual(QualityTokens.releaseShape(from: "Some Movie 2013 1920x1080 DTS-HD MA 5.1"), "movie")
    }

    /// 通用规则（不只观众）：上传页有分类下拉但站点没有动漫分区时，动画按形态落进电影/剧集，
    /// 不退到「其他」；站点有动漫分区时仍优先动漫。
    func testAnimeFallsBackToMovieOrSeriesByShapeOnSitesWithoutAnimeCategory() throws {
        let page = """
        <form><select name="type">
        <option value="0">请选择</option><option value="401">电影</option>
        <option value="402">剧集</option><option value="403">综艺</option>
        <option value="406">纪录片</option><option value="408">音乐</option>
        <option value="409">其他</option></select></form>
        """
        let withAnime = page.replacingOccurrences(
            of: #"<option value="409">其他</option>"#,
            with: #"<option value="405">动漫</option><option value="409">其他</option>"#)
        let site = SiteConfig(id: "generic", name: "通用站", url: "https://example.org/",
                              framework: .nexusPHP, enabled: true, overrides: .nexusCN)
        let a = NexusPHPAdapter(site: site, client: client)
        func category(_ name: String, _ html: String) -> String? {
            let info = ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=1",
                                   name: name, kind: .anime)
            return value(a.buildUploadFields(info, page: html), "type")
        }
        XCTAssertEqual(category("Some Anime Movie 2013 1080p BluRay", page), "401", "动画电影入电影")
        XCTAssertEqual(category("Some Anime S03 2015 1080p BluRay", page), "402", "动画剧集入剧集")
        XCTAssertEqual(category("Some Anime S03 2015 1080p BluRay", withAnime), "405",
                       "站点有动漫分区时仍走动漫，不该被形态规则抢走")
    }

    /// 站点用静态分类表、且 anime 只能填成「其他」那一个值时（春天早期就是这么配的），
    /// 同样按形态分流；所有分类共用一个 id 的单分区站（海棠、tccf）必须保持原值。
    func testStaticCategoryMapSendsAnimeByShapeWhenAnimeEqualsOther() throws {
        let page = """
        <form><select name="type">
        <option value="0">请选择</option><option value="401">Movies(电影)</option>
        <option value="402">TV Series(剧集)</option><option value="406">Docs(纪录)</option>
        <option value="408">Music(音乐)</option><option value="409">Other(其他类型)</option></select></form>
        """
        func category(_ name: String, _ ov: SiteOverride) -> String? {
            let site = SiteConfig(id: "generic-map", name: "静态表站", url: "https://example.org/",
                                  framework: .nexusPHP, enabled: true, overrides: ov)
            let info = ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=1",
                                   name: name, kind: .anime)
            return value(NexusPHPAdapter(site: site, client: client).buildUploadFields(info, page: page), "type")
        }
        let noAnime = SiteOverride(categoryField: "type", categoryMap: ["movie": 401, "series": 402,
                                                                       "documentary": 406, "music": 408,
                                                                       "anime": 409, "other": 409])
        XCTAssertEqual(category("Some Anime S03 2015 1080p BluRay", noAnime), "402", "静态表下动画剧集入剧集")
        XCTAssertEqual(category("Some Anime Movie 2013 1080p BluRay", noAnime), "401", "静态表下动画电影入电影")
        let single = SiteOverride(categoryField: "type", categoryMap: ["movie": 4099, "series": 4099,
                                                                      "anime": 4099, "other": 4099])
        XCTAssertEqual(category("Some Anime S03 2015 1080p BluRay", single), "4099",
                       "全站只有一个分类 id 时不该被形态规则改动")
    }

    /// 用户实测（LuckPT 43775 寒蝉鸣泣之时·煌 S04 动画剧集）：春天选成了 Other(其他类型)
    func testCmctAnimeSeriesGoesToTvSeriesNotOther() throws {
        var info = try sourceRelease()
        info.name = "Higurashi Kira S04 2011 1080p Blu-ray Remux AVC FLAC 2.0-LuckAni"
        let fields = adapter("cmct").buildUploadFields(info, page: try fixture("cmct-upload.html"))
        XCTAssertEqual(value(fields, "type"), "502", "春天没有动漫分区，509 是 Other(其他类型)：动画剧集应入 502 剧集")
        XCTAssertNotEqual(value(fields, "type"), "509")
        XCTAssertTrue(fields.contains { $0.name == "animation" }, "「动画」仍作为标签勾上")
    }

    func testCmctAnimeMovieGoesToMovies() throws {
        var info = try sourceRelease()
        info.name = "Gintama Movie 2 2013 1080p JPN Blu-ray AVC LPCM 5.1-U2"
        let fields = adapter("cmct").buildUploadFields(info, page: try fixture("cmct-upload.html"))
        XCTAssertEqual(value(fields, "type"), "501", "动画电影入 501 Movies(电影)")
    }

    // MARK: - 春天主标题：蓝光 Remux 要写 BluRay

    /// 用户实测（LuckPT 43775 寒蝉煌 S01 1080p Blu-ray Remux）：春天主标题写 Blu-ray 会被拒
    func testCmctRemuxTitleRewritesBlurayToBluRay() throws {
        var info = try sourceRelease()
        info.torrentName = "Higurashi.no.Naku.Koro.ni.Rei.S01.2009.1080p.Blu-ray.Remux.AVC.LPCM.2.0-LuckAni.torrent"
        let fields = adapter("cmct").buildUploadFields(info, page: try fixture("cmct-upload.html"))
        let name = value(fields, "name") ?? ""
        XCTAssertEqual(name, "Higurashi.no.Naku.Koro.ni.Rei.S01.2009.1080p.BluRay.Remux.AVC.LPCM.2.0-LuckAni",
                       "春天 Remux 主标题里的 Blu-ray 要改成 BluRay")
        XCTAssertFalse(name.lowercased().contains("blu-ray"))
    }

    /// 非 Remux 发布（原盘 / 压制）不动：规则只管蓝光 Remux 那一种写法
    func testCmctNonRemuxTitleKeepsBluraySpelling() throws {
        var info = try sourceRelease()
        info.torrentName = "Gintama.Movie.2.2013.1080p.Blu-ray.AVC.LPCM.5.1-U2.torrent"
        let fields = adapter("cmct").buildUploadFields(info, page: try fixture("cmct-upload.html"))
        XCTAssertTrue((value(fields, "name") ?? "").contains("Blu-ray"), "没有 Remux 段就不改写法")
    }

    func testRemuxTitleTokenRewritesAreWholeWord() {
        let table = ["Blu-ray": "BluRay"]
        XCTAssertEqual(NexusPHPAdapter.rewriteRemuxTitleTokens(
            "Some.Show.S02 2015 1080p Blu-ray Remux AVC FLAC", table),
            "Some.Show.S02 2015 1080p BluRay Remux AVC FLAC", "空格分隔的发布名同样改写")
        XCTAssertEqual(NexusPHPAdapter.rewriteRemuxTitleTokens(
            "Some.Show.2015.2160p.UHD.BLU-RAY.REMUX.HEVC", table),
            "Some.Show.2015.2160p.UHD.BluRay.REMUX.HEVC", "大小写不敏感，原有大写风格不改")
        XCTAssertEqual(NexusPHPAdapter.rewriteRemuxTitleTokens(
            "Some.Movie.2013.1080p.Blu-ray.AVC", table),
            "Some.Movie.2013.1080p.Blu-ray.AVC", "不含 Remux 段就不动")
        XCTAssertEqual(NexusPHPAdapter.rewriteRemuxTitleTokens(
            "Some.Movie.2013.1080p.x264.Blu-ray-Remux", table),
            "Some.Movie.2013.1080p.x264.BluRay-Remux", "连字符分隔也算整词")
    }

    // MARK: - 3. BDInfo 随种转出去：普通站 [quote] 引用，观众用 [mediainfo]

    func testBDInfoExtractedFromSourcePage() throws {
        let info = try sourceRelease()
        XCTAssertTrue(info.mediainfo.contains("DISC INFO"), "BDInfo 要提取出来，实际：\(info.mediainfo.prefix(80))")
        XCTAssertTrue(info.mediainfo.contains("PLAYLIST REPORT"))
    }

    func testBDInfoQuotedInTargetDescription() throws {
        let info = try sourceRelease()
        let fields = adapter("chdbits").buildUploadFields(info, page: try fixture("chdbits-upload.html"))
        let descr = value(fields, "descr") ?? ""
        XCTAssertTrue(descr.contains("[quote]\nDISC INFO"), "BDInfo 应以引用块带过去：\(descr.suffix(400))")
        XCTAssertTrue(descr.range(of: #"\[quote\][\s\S]*PLAYLIST REPORT[\s\S]*\[/quote\][\s\S]*\[img\]"#,
                                  options: .regularExpression) != nil,
                      "引用块应排在末尾截图之前")
    }

    func testAudiencesUsesMediainfoTag() throws {
        let info = try sourceRelease()
        let fields = adapter("audiences").buildUploadFields(info, page: try fixture("audiences-upload.html"))
        let descr = value(fields, "descr") ?? ""
        XCTAssertTrue(descr.contains("[mediainfo]\nDISC INFO"),
                      "观众用站点自己的 [mediainfo] 引用：\(descr.suffix(400))")
        XCTAssertFalse(descr.contains("[quote]\nDISC INFO"))
    }

    // MARK: - 4. 套：详情链接是 /t/<id>/，找回链接才推得进下载器

    func testTTGSearchFindsExistingTorrentLink() throws {
        let html = try fixture("ttg-search-gintama.html")
        let base = URL(string: "https://totheglory.im/browse.php?search_field=x")!
        let name = "Gekijouban Gintama Kanketsu-hen Yorozuyayo eien nare 2013 1080p Blu-ray AVC DTS-HD MA 5.1-LuckDIY"
        let ttg = adapter("ttg")
        let hit = NexusPHPAdapter.searchNameInResults(html: html, releaseName: name, base: base,
                                                     hrefPattern: ttg.detailHrefPattern, relaxed: true)
        XCTAssertEqual(hit?.href, "https://totheglory.im/t/805271/",
                       "结果行标题链接就是 /t/<id>/，必须认它才能推下载器")
        // 默认正则（只认 details.php?id=）在这页上找不到任何结果——就是「站内没检索到」的成因
        XCTAssertNil(NexusPHPAdapter.searchNameInResults(html: html, releaseName: name, base: base,
                                                        relaxed: true))
    }

    // MARK: - 5. DIY 标签：各目标站跟随源站「标签」行

    /// 源站这种的发布名以 -LuckDIY 结尾（那是发布组名，不能当 DIY 依据），
    /// 但「标签」行明确写了 DIY，转出去就该勾上本站的 DIY。
    func testSourcePageDeclaresDIYTag() throws {
        let info = try sourceRelease()
        XCTAssertTrue(info.sourceTags.contains("DIY"), "源站标签行应解析出 DIY，实际 \(info.sourceTags)")
        XCTAssertTrue(QualityTokens.canonicalTags(info).contains("diy"))
    }

    /// 家园 / 观众这类配了 tagMap 的站：配置里没有 diy 时，按页面复选框文案补上。
    func testDIYTagFillsGapsInConfiguredTagMap() throws {
        let info = try sourceRelease()
        for (site, field) in [("hdhome", "tags[]"), ("audiences", "tags[]")] {
            let fields = adapter(site).buildUploadFields(info, page: try fixture("\(site)-upload.html"))
            XCTAssertTrue(values(fields, field).contains("diy"),
                          "\(site) 应勾本站 DIY（\(field)=diy）")
        }
    }

    /// HDSky 的标签表值不是文案，只认整条文案完全一致的选项：13=DIY，26=DIY纯净版 不该被选中。
    func testHDskyPicksExactDIYOption() throws {
        let info = try sourceRelease()
        let fields = adapter("hdsky").buildUploadFields(info, page: try fixture("hdsky-upload.html"))
        XCTAssertTrue(values(fields, "option_sel[]").contains("13"), "应勾 option_sel[]=13 DIY")
        XCTAssertFalse(values(fields, "option_sel[]").contains("26"), "不能勾成 DIY纯净版")
    }

    /// 彩虹岛的标签是没有文案的图标复选框，按字段名配置勾上。
    func testChdbitsChecksDIYIconCheckbox() throws {
        let info = try sourceRelease()
        let fields = adapter("chdbits").buildUploadFields(info, page: try fixture("chdbits-upload.html"))
        XCTAssertEqual(value(fields, "diy"), "yes")
    }

    /// 源站没打 DIY 就不要乱勾（-LuckDIY 只是发布组名）。
    func testDIYNotInventedWithoutSourceTag() throws {
        var info = try sourceRelease()
        info.sourceTags = []
        XCTAssertFalse(QualityTokens.canonicalTags(info).contains("diy"))
        let fields = adapter("hdhome").buildUploadFields(info, page: try fixture("hdhome-upload.html"))
        XCTAssertFalse(values(fields, "tags[]").contains("diy"))
    }

    /// 显式配置优先：tagMap 写过的规范标签不再走动态匹配，避免同一个标签勾出两份值。
    func testExplicitTagMapWinsOverDynamicMatch() throws {
        let page = """
        <form><select name="type"><option value="401">电影</option></select>
        <label><input type="checkbox" name="tags[]" value="zz" /><span>中字</span></label>
        <label><input type="checkbox" name="tags[]" value="diy" /><span>DIY</span></label></form>
        """
        let overrides = SiteOverride(tagField: "tags[]", tagMap: ["chinese_sub": "99"])
        let site = SiteConfig(id: "generic", name: "通用站", url: "https://example.org/",
                              framework: .nexusPHP, enabled: true, overrides: overrides)
        let fields = NexusPHPAdapter(site: site, client: client)
            .buildUploadFields(ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=1",
                                           name: "Some Movie 2013 1080p BluRay", kind: .movie,
                                           sourceTags: ["中字", "DIY"]),
                               page: page)
        XCTAssertEqual(values(fields, "tags[]"), ["99", "diy"], "中字走配置里的 99，DIY 由动态匹配补")
    }
    // MARK: - 6. 完结只对连载体裁；春天的「完结」是「合集」

    func testCompletedOnlyForEpisodicReleases() throws {
        let movie = try sourceRelease()   // 银魂剧场版：完结篇（标题带「完结」但是单片）
        XCTAssertFalse(QualityTokens.isEpisodicRelease(movie))
        XCTAssertFalse(QualityTokens.isCompletedRelease(movie))
        XCTAssertFalse(QualityTokens.canonicalTags(movie).contains("completed"),
                       "动画电影不该打完结")
        // 源站把单片标成完结也不跟随
        var tagged = movie
        tagged.sourceTags = ["官方", "中字", "完结"]
        XCTAssertFalse(QualityTokens.canonicalTags(tagged).contains("completed"))

        func episodic(_ name: String, kind: ReleaseKind = .anime, subtitle: String = "") -> Bool {
            QualityTokens.isEpisodicRelease(ReleaseInfo(siteID: "luckpt",
                                                        detailURL: "https://x/details.php?id=1",
                                                        name: name, kind: kind, subtitle: subtitle))
        }
        XCTAssertTrue(episodic("Yuru Yuri S03 2015 1080p BluRay Remux-LuckAni"), "整季包")
        XCTAssertTrue(episodic("Yuru Yuri S03E05 1080p WEB-DL"), "有集数即连载")
        XCTAssertTrue(episodic("Any 2015 1080p WEB-DL-x", subtitle: "全12集"), "副标题写全X集")
        XCTAssertTrue(episodic("[azit]Some Anime [01-24][1080P]-x"), "01-24 区间")
        XCTAssertTrue(episodic("Some Show 2019 1080p WEB-DL-x", kind: .series), "剧集分类天然是连载")
        XCTAssertFalse(episodic("Some Movie 2013 1080p Blu-ray"), "电影没有集数")
    }

    /// 动画电影：家园/观众的「完结」不该勾；整季包才勾
    func testCompletedTagOnlyOnSeasonPacks() throws {
        let movie = try sourceRelease()
        let movieFields = adapter("hdhome").buildUploadFields(movie, page: try fixture("hdhome-upload.html"))
        XCTAssertFalse(values(movieFields, "tags[]").contains("wj"), "动画电影不勾完结")

        var season = movie
        season.name = "Yuru Yuri S03 2015.1080p BluRay Remux AVC LPCM 2.0-LuckAni"
        season.subtitle = "摇曳百合 第三季"
        let seasonFields = adapter("hdhome").buildUploadFields(season, page: try fixture("hdhome-upload.html"))
        XCTAssertTrue(values(seasonFields, "tags[]").contains("wj"), "整季包勾完结")
    }

    /// 春天没有完结标签，整季包对应「合集」（pack=1）；其余标签仍按文案动态匹配
    func testCMCTMapsCompletedToPack() throws {
        var season = try sourceRelease()
        season.name = "Yuru Yuri S03 2015.1080p BluRay Remux AVC LPCM 2.0-LuckAni"
        season.subtitle = "摇曳百合 第三季"
        let f = adapter("cmct").buildUploadFields(season, page: try fixture("cmct-upload.html"))
        XCTAssertEqual(value(f, "pack"), "1", "整季包勾「合集」")
        XCTAssertTrue(values(f, "animation").contains("1"), "动画标签照勾")
        XCTAssertTrue(values(f, "subtitlezh").contains("1"), "中字标签照勾")
        let movieFields = adapter("cmct").buildUploadFields(try sourceRelease(),
                                                            page: try fixture("cmct-upload.html"))
        XCTAssertNil(movieFields.first { $0.name == "pack" }?.value, "动画电影不勾合集")
    }
}
