import XCTest
@testable import BoxSendKit

/// 站点覆盖扩展（Blu / 经典 Gazelle / 动态分类 / 影 站）的解析与字段映射测试
final class SiteCoverageTests: XCTestCase {

    private func fixture(_ name: String) -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try! String(contentsOf: path, encoding: .utf8)
    }

    private func site(_ id: String, url: String, framework: SiteFramework = .nexusPHP) -> SiteConfig {
        let ov = SiteRegistry.prioritySites.first { $0.id == id }?.overrides
        return SiteConfig(id: id, name: id, url: url, framework: framework, enabled: true, overrides: ov)
    }

    private let client = HTTPClient(cookies: CookieStore(), userAgent: "box-send-test")

    // MARK: - Blu (blutopia)

    func testBluDetailParse() throws {
        let a = BluAdapter(site: site("blutopia", url: "https://blutopia.cc/", framework: .blu), client: client)
        let html = fixture("blu-detail.html")
        let info = try a.parseDetail(html: html, detailURL: "https://blutopia.cc/torrents/397246")
        XCTAssertEqual(info.name, "Jesus Christ Superstar 1973 2160p UHD BluRay REMUX DV HDR HEVC DTS-HD MA 4.1-BLURANiUM")
        XCTAssertEqual(info.imdb, "tt0070239")
        XCTAssertEqual(info.torrentURL, "https://blutopia.cc/torrents/download/397246")
        XCTAssertTrue(info.descr.contains("blu-ray.com") || info.descr.contains("Source"))
        XCTAssertTrue(info.mediainfo.contains("Unique ID"))
        XCTAssertEqual(info.kind, .movie)
    }

    func testMonikaDetailParse() throws {
        let a = BluAdapter(site: site("monika", url: "https://monikadesign.uk/", framework: .blu), client: client)
        let html = fixture("monika-detail.html")
        let info = try a.parseDetail(html: html, detailURL: "https://monikadesign.uk/torrents/29107")
        XCTAssertEqual(info.name, "Hataraku Maou-sama! S02 1080p BluRay x265 OPUS 2.0-7³ACG")
        XCTAssertTrue(info.torrentURL.hasPrefix("https://monikadesign.uk/torrents/download/29107"))
        XCTAssertEqual(info.kind, .anime)
    }

    func testBluUploadFieldMapping() throws {
        let page = """
        <html><body>
        <input type="hidden" name="_token" value="TOK123" autocomplete="off">
        <input type="hidden" name="tmdb_movie_id" value="0" />
        <input type="hidden" name="imdb" value="0" />
        <input type="hidden" name="anon" value="0" />
        <input type="hidden" name="personal_release" value="0" />
        <select name="category_id"><option value="1">Movie</option><option value="2">TV Show</option></select>
        <select name="type_id"><option value="1">Full Disc</option><option value="3">Remux</option></select>
        <select name="resolution_id"><option value="2">1080p</option><option value="1">2160p</option></select>
        </body></html>
        """
        let a = BluAdapter(site: site("blutopia", url: "https://blutopia.cc/", framework: .blu), client: client)
        let info = ReleaseInfo(
            siteID: "blutopia", detailURL: "https://blutopia.cc/torrents/1",
            name: "Test Movie 2020 2160p UHD BluRay REMUX DV HDR HEVC DTS-HD MA 5.1-GRP",
            descr: "<p>desc</p>", imdb: "tt0123456", kind: .movie)
        let fields = a.buildUploadFields(info, page: page)
        func v(_ n: String) -> String? { fields.first { $0.name == n }?.value }
        XCTAssertEqual(v("_token"), "TOK123")
        XCTAssertEqual(v("name"), "Test Movie 2020 2160p UHD BluRay REMUX DV HDR HEVC DTS-HD MA 5.1-GRP")
        XCTAssertEqual(v("category_id"), "1")      // movie -> blutopia 1
        XCTAssertEqual(v("type_id"), "3")          // remux -> blutopia 3
        XCTAssertEqual(v("resolution_id"), "1")    // 2160p -> blutopia 1
        XCTAssertEqual(v("imdb"), "tt0123456")
        XCTAssertEqual(v("title_exists_on_imdb"), "1")
        XCTAssertEqual(v("anon"), "0")
        XCTAssertEqual(v("personal_release"), "0")
    }

    func testMonikaUploadFieldMapping() throws {
        let page = """
        <html><body>
        <input type="hidden" name="_token" value="MTOK" autocomplete="off">
        <input type="hidden" name="anonymous" value="0" />
        </body></html>
        """
        let a = BluAdapter(site: site("monika", url: "https://monikadesign.uk/", framework: .blu), client: client)
        let info = ReleaseInfo(
            siteID: "monika", detailURL: "https://monikadesign.uk/torrents/1",
            name: "Test Show S01E02 1080p BluRay x265-GRP",
            descr: "<p>desc</p>", imdb: "tt9999999", kind: .anime)
        let fields = a.buildUploadFields(info, page: page)
        func v(_ n: String) -> String? { fields.first { $0.name == n }?.value }
        XCTAssertEqual(v("category_id"), "8")   // anime -> monika 8 (Anime TV)
        XCTAssertEqual(v("type_id"), "1")       // bluray(1080 disc) -> monika 1 (Full Disc)
        XCTAssertEqual(v("resolution_id"), "3") // 1080p -> monika 3
        XCTAssertEqual(v("season_number"), "1")
        XCTAssertEqual(v("episode_number"), "2")
        XCTAssertNil(v("imdb"))                 // monika 无 imdb 字段
    }

    func testSeasonEpisode() {
        let a = BluAdapter.seasonEpisode(from: "Show S02E10 1080p")
        XCTAssertEqual(a?.season, 2)
        XCTAssertEqual(a?.episode, 10)
        let b = BluAdapter.seasonEpisode(from: "Show S1E3")
        XCTAssertEqual(b?.season, 1)
        XCTAssertEqual(b?.episode, 3)
        XCTAssertNil(BluAdapter.seasonEpisode(from: "Movie 1080p"))
    }

    // MARK: - 经典 Gazelle (HDSpace)

    func testGazelleDetailParse() throws {
        let a = GazelleAdapter(site: site("hdspace", url: "https://hd-space.org/", framework: .gazelle), client: client)
        let html = fixture("hdsp-detail.html")
        let info = try a.parseDetail(html: html, detailURL: "https://hd-space.org/index.php?page=torrent-details&id=4094afbb314471a49f49b8fc767a83cfb1cbcb91")
        XCTAssertEqual(info.name, "Spaceballs 1987 2160 UHD Blu-ray HEVC DTS-HD MA 5.1-F13@HDSpace")
        XCTAssertTrue(info.torrentURL.contains("download.php?id=4094afbb314471a49f49b8fc767a83cfb1cbcb91"))
        XCTAssertTrue(info.torrentName.hasSuffix(".torrent"))
        XCTAssertTrue(info.descr.contains("DISC INFO"))
        // xbtit 渲染的 [quote]/[code] 还原
        XCTAssertTrue(info.descr.contains("[quote]") || info.descr.contains("[code]"))
        XCTAssertFalse(info.descr.contains("Show | Hide NFO"))
    }

    func testGazelleUnrenderBBCode() {
        let html = """
        <div align=right><a href="#nfo" onclick="javascript:ShowHide('slidenfo','','');">Show | Hide NFO</a></div>
        <div align='center' style='display:none' id='slidenfo'>
        <img src='nfo/nfogen.php?id=1' /></div>
        </div>
        <b>Quote:</b><br /><table width="100%" class="quote"><tr><td >
        <b>Code</b><br /><table width="100%" class="code"><tr><td><font color="red">4K Blu-ray: Region free</font></td></tr></table>
        DISC INFO: Disc Title: X
        </td></tr></table>
        """
        let out = GazelleAdapter.unrenderBBCode(html)
        XCTAssertFalse(out.contains("slidenfo"))
        XCTAssertFalse(out.contains("Show | Hide NFO"))
        XCTAssertTrue(out.contains("[code]4K Blu-ray: Region free[/code]"))
        XCTAssertTrue(out.contains("[quote]") && out.contains("[/quote]"))
        XCTAssertFalse(out.contains("<table"))
    }

    func testGazelleUploadFieldMapping() throws {
        let page = """
        <html><body>
        <input type="hidden" name="user_id" size="50" value="" />
        </body></html>
        """
        let a = GazelleAdapter(site: site("hdspace", url: "https://hd-space.org/", framework: .gazelle), client: client)
        let info = ReleaseInfo(
            siteID: "hdspace", detailURL: "https://hd-space.org/x",
            name: "Movie 2020 1080p BluRay x264 DTS-GRP",
            descr: "<p>desc</p>", imdb: "tt1111111", kind: .movie)
        let fields = a.buildUploadFields(info, page: page)
        func v(_ n: String) -> String? { fields.first { $0.name == n }?.value }
        XCTAssertEqual(v("filename"), "Movie 2020 1080p BluRay x264 DTS-GRP")
        XCTAssertEqual(v("category"), "19")   // movie 1080p -> 19
        XCTAssertEqual(v("imdb"), "tt1111111")
        XCTAssertEqual(v("anonymous"), "false")
        XCTAssertEqual(v("user_id"), "")
        XCTAssertTrue(v("info")?.contains("desc") ?? false)
    }

    // MARK: - 影 站（字符串分类 + 源介质组合 + 字符串分辨率）

    func testShadowUploadFieldMapping() throws {
        let page = """
        <html><body>
        <input type="hidden" name="tid" value="42" />
        </body></html>
        """
        let a = NexusPHPAdapter(site: site("shadow", url: "https://star-space.net/"), client: client)
        let info = ReleaseInfo(
            siteID: "shadow", detailURL: "https://star-space.net/details.php?id=1",
            name: "Movie 2020 2160p UHD BluRay REMUX DV HDR HEVC DTS-HD MA 5.1-GRP",
            descr: "<p>desc 中文字幕</p>", imdb: "tt2222222", kind: .movie,
            subtitle: "副标题", mediainfo: "Unique ID : 123")
        let fields = a.buildUploadFields(info, page: page)
        func v(_ n: String) -> String? { fields.first { $0.name == n }?.value }
        XCTAssertEqual(v("tid"), "42")
        XCTAssertEqual(v("tr_category"), "mo")          // movie -> mo
        XCTAssertEqual(v("tr_source"), "s52")           // remux + 2160p -> UHD Remux
        XCTAssertEqual(v("tr_video_codec"), "2")        // hevc
        XCTAssertEqual(v("tr_audio_codec"), "6")        // dtsma
        XCTAssertEqual(v("tr_resolution"), "r4")        // 2160p -> r4
        XCTAssertEqual(v("imdb_url"), "http://www.imdb.com/title/tt2222222/")
        XCTAssertEqual(v("small_desc"), "副标题")
        XCTAssertEqual(v("tag_chs_sub"), "yes")         // 中文字幕标签
    }

    func testShadowRemux1080pSource() throws {
        let page = "<html><body></body></html>"
        let a = NexusPHPAdapter(site: site("shadow", url: "https://star-space.net/"), client: client)
        let info = ReleaseInfo(
            siteID: "shadow", detailURL: "https://star-space.net/details.php?id=2",
            name: "Movie 2019 1080p BluRay REMUX AVC DTS-HD MA 5.1-GRP",
            descr: "", kind: .movie)
        let fields = a.buildUploadFields(info, page: page)
        func v(_ n: String) -> String? { fields.first { $0.name == n }?.value }
        XCTAssertEqual(v("tr_source"), "s42")           // remux + 1080p -> BD Remux
        XCTAssertEqual(v("tr_video_codec"), "1")        // avc
        XCTAssertEqual(v("tr_resolution"), "r3")        // 1080p
    }

    // MARK: - 动态分类解析（nexusCN 免逐站配置）

    func testDynamicCategoryResolution() throws {
        let page = """
        <html><body>
        <select name="type">
          <option value="0">未选</option>
          <option value="401">电影</option>
          <option value="402">剧集</option>
          <option value="404">纪录片</option>
          <option value="405">动漫</option>
          <option value="408">音乐</option>
          <option value="409">其他</option>
        </select>
        </body></html>
        """
        let a = NexusPHPAdapter(site: site("cspt", url: "https://cspt.top/"), client: client)
        let movie = ReleaseInfo(siteID: "cspt", detailURL: "u", name: "Movie 2020 1080p", descr: "", kind: .movie)
        let docu = ReleaseInfo(siteID: "cspt", detailURL: "u", name: "Doc 2020 1080p", descr: "", kind: .documentary)
        let music = ReleaseInfo(siteID: "cspt", detailURL: "u", name: "Artist FLAC 2020", descr: "", kind: .music)
        func cat(_ info: ReleaseInfo) -> String? {
            a.buildUploadFields(info, page: page).first { $0.name == "type" }?.value
        }
        XCTAssertEqual(cat(movie), "401")
        XCTAssertEqual(cat(docu), "404")
        XCTAssertEqual(cat(music), "408")
    }

    func testStaticCategoryMapWinsOverDynamic() throws {
        let page = """
        <html><body><select name="type"><option value="999">电影</option></select></body></html>
        """
        // byr 有静态 categoryMap，应优先于动态解析
        let a = NexusPHPAdapter(site: site("byr", url: "https://byr.pt/"), client: client)
        let info = ReleaseInfo(siteID: "byr", detailURL: "u", name: "Movie 2020 1080p", descr: "", kind: .movie)
        let v = a.buildUploadFields(info, page: page).first { $0.name == "type" }?.value
        XCTAssertEqual(v, "408")  // byr 电影 408，而非动态的 999
    }

    // MARK: - 内置站点表自动并入

    func testRosterAutoMerge() throws {
        var cfg = AppConfig.template()
        cfg.sourceSites = cfg.sourceSites.filter { $0.id != "blutopia" && $0.id != "hdspace" }
        let merged = cfg.mergedWithRoster()
        XCTAssertTrue(merged.sourceSites.contains { $0.id == "blutopia" })
        XCTAssertTrue(merged.sourceSites.contains { $0.id == "hdspace" })
        // 已存在的条目不被重复添加
        let count = merged.sourceSites.filter { $0.id == "luckpt" }.count
        XCTAssertEqual(count, 1)
        // 新增站默认停用
        let blu = merged.sourceSites.first { $0.id == "blutopia" }
        XCTAssertEqual(blu?.enabled, false)
        // 重复调用幂等
        let merged2 = merged.mergedWithRoster()
        XCTAssertEqual(merged2.sourceSites.count, merged.sourceSites.count)
    }

    func testPipelineAutoEnablesExplicitTargets() {
        var cfg = AppConfig.template()
        // 模拟新站默认停用，但用户勾选了目标
        cfg.sourceSites = cfg.sourceSites.map { s in
            var s = s
            if s.id == "city13" { s.enabled = false }
            return s
        }
        cfg.targetSites = ["city13"]
        let client = HTTPClient(cookies: CookieStore(), userAgent: "t")
        let dl = DownloaderFactory.make(cfg, client: client)
        let pipe = ReseedPipeline(config: cfg, cookies: CookieStore(),
                                  state: StateStore(dataDir: "/tmp/boxsend-test-\(UUID().uuidString)"),
                                  downloader: dl)
        // 勾选目标后流水线内应自动启用
        XCTAssertEqual(pipe.config.site("city13")?.enabled, true)
        // 未列入目标的停用站保持停用
        var cfg2 = cfg
        cfg2.sourceSites = cfg2.sourceSites.map { s in
            var s = s
            if s.id == "blutopia" { s.enabled = false }
            return s
        }
        let pipe2 = ReseedPipeline(config: cfg2, cookies: CookieStore(),
                                   state: StateStore(dataDir: "/tmp/boxsend-test-\(UUID().uuidString)"),
                                   downloader: dl)
        XCTAssertEqual(pipe2.config.site("blutopia")?.enabled, false)
    }

    func testRosterFrameworks() {
        let sites = SiteRegistry.prioritySites
        let ids = Set(sites.map { $0.id })
        // 关键新站存在
        for id in ["blutopia", "monika", "hdspace", "opencd", "iptorrents", "byr", "shadow"] {
            XCTAssertTrue(ids.contains(id), "missing \(id)")
        }
        // savept.icu 扩充的长尾站（部分抽查）
        for id in ["azusa", "kamept", "musopia", "xdy", "ourbits", "gpw", "mteam",
                   "milkie", "ptneko", "alpharatio", "animez", "sportscult",
                   "hdtorrents", "beyondhd", "torrentleech", "sjtu"] {
            XCTAssertTrue(ids.contains(id), "missing \(id)")
        }
        // 无重复 id
        XCTAssertEqual(ids.count, sites.count)
        // 框架正确
        XCTAssertEqual(sites.first { $0.id == "blutopia" }?.framework, .blu)
        XCTAssertEqual(sites.first { $0.id == "hdspace" }?.framework, .gazelle)
        XCTAssertEqual(sites.first { $0.id == "shadow" }?.framework, .nexusPHP)
        XCTAssertEqual(sites.first { $0.id == "azusa" }?.framework, .nexusPHP)
        XCTAssertEqual(sites.first { $0.id == "ourbits" }?.framework, .custom)
        XCTAssertEqual(sites.first { $0.id == "mteam" }?.framework, .unit3D)
        XCTAssertEqual(sites.first { $0.id == "hdtorrents" }?.framework, .xbtit)
        XCTAssertEqual(sites.first { $0.id == "alpharatio" }?.framework, .gazelle)
        // 域名迁移后的站点地址
        XCTAssertEqual(sites.first { $0.id == "ziran" }?.url, "https://naturept.top/")
        XCTAssertEqual(sites.first { $0.id == "gtk" }?.url, "https://pt.gtkpw.xyz/")
        // 适配器可实例化（不崩；unit3D/custom 回退 NexusPHP 通用适配器）
        let c = HTTPClient(cookies: CookieStore(), userAgent: "t")
        for s in sites {
            _ = SiteRegistry.adapter(for: s, client: c)
        }
    }

    /// 站点中文名（与用户需求清单一致）
    func testRosterChineseNames() {
        let sites = SiteRegistry.prioritySites
        let expected: [String: String] = [
            "luckpt": "幸运", "hdsky": "天空", "chdbits": "彩虹岛", "hdhome": "家园",
            "cmct": "春天", "audiences": "观众", "ttg": "套", "pter": "猫",
            "hhanclub": "憨憨", "monika": "莫妮卡", "opencd": "皇后", "iptorrents": "IPT",
            "byr": "北邮", "ptba": "1PT", "agsvpt": "末日", "railgun": "Railgun",
            "carpt": "车站", "crabpt": "蟹黄堡", "cyanbug": "大青虫", "discfan": "蝶粉",
            "dragonhd": "龙之家", "march": "三月", "hdarea": "高清视界", "hdbao": "海德堡",
            "hddolby": "杜比", "hdfans": "红豆饭", "hdtime": "时光", "hitpt": "百川",
            "hudbt": "蝴蝶", "kufei": "库非", "lajidui": "垃圾堆", "longpt": "龙",
            "iloli": "爱萝莉", "njtupt": "蒲园", "okpt": "OK", "oshen": "奥申",
            "baozi": "包子", "panda": "熊猫", "piggo": "猪猪", "freefarm": "农场",
            "aling": "爱玲", "btschool": "学校", "tlf": "吐鲁番", "hdclone": "独自",
            "itzmx": "Itz", "novahd": "nova", "soulvoice": "聆音", "hdu": "好多油",
            "ptcafe": "咖啡", "pthome": "铂金家", "ptlgs": "劳改所", "ptsbao": "烧包",
            "ptskit": "拾刻", "ptt": "时间", "ptzone": "葡萄汁", "qingwa": "青蛙",
            "tjupt": "北洋园", "ubits": "优堡", "wtsakura": "冬樱", "zmpt": "织梦",
            "u2": "幼儿圈", "zhuque": "朱雀", "haidan": "海胆", "yemapt": "野马",
            "hdcity": "城市"
        ]
        for (id, name) in expected {
            XCTAssertEqual(sites.first { $0.id == id }?.name, name, "id: \(id)")
        }
    }

    /// 旧配置兼容：无 managed 字段时按 enabled 推断（启用的站视为已添加）
    func testSiteConfigLegacyManagedDecoding() throws {
        let on = """
        {"id":"x","name":"X","url":"https://x.pt/","framework":"NexusPHP","enabled":true}
        """
        let s1 = try JSONDecoder().decode(SiteConfig.self, from: Data(on.utf8))
        XCTAssertEqual(s1.enabled, true)
        XCTAssertEqual(s1.managed, true)

        let off = """
        {"id":"y","name":"Y","url":"https://y.pt/","framework":"NexusPHP","enabled":false}
        """
        let s2 = try JSONDecoder().decode(SiteConfig.self, from: Data(off.utf8))
        XCTAssertEqual(s2.enabled, false)
        XCTAssertEqual(s2.managed, false)

        // 显式 managed 值优先
        let mixed = """
        {"id":"z","name":"Z","url":"https://z.pt/","framework":"NexusPHP","enabled":false,"managed":true}
        """
        let s3 = try JSONDecoder().decode(SiteConfig.self, from: Data(mixed.utf8))
        XCTAssertEqual(s3.enabled, false)
        XCTAssertEqual(s3.managed, true)
    }

    /// 已存在的用户配置按注册表站名同步（改名后旧配置自动更新）
    func testRosterNameSyncIntoUserConfig() {
        var cfg = AppConfig.template()
        cfg.sourceSites = cfg.sourceSites.map { s in
            var s = s
            if s.id == "hdsky" { s.name = "HDSky" }       // 旧名
            if s.id == "luckpt" { s.name = "LuckPT" }     // 旧名
            return s
        }
        let merged = cfg.mergedWithRoster()
        XCTAssertEqual(merged.sourceSites.first { $0.id == "hdsky" }?.name, "天空")
        XCTAssertEqual(merged.sourceSites.first { $0.id == "luckpt" }?.name, "幸运")
        // 自定义站（不在注册表）站名不被覆盖
        var custom = SiteConfig(id: "mycustom", name: "我的站", url: "https://my.pt/", framework: .custom, enabled: true, overrides: nil)
        var cfg2 = AppConfig.template()
        cfg2.sourceSites.append(custom)
        let merged2 = cfg2.mergedWithRoster()
        XCTAssertEqual(merged2.sourceSites.first { $0.id == "mycustom" }?.name, "我的站")
    }
}
