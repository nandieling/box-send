import XCTest
@testable import BoxSendKit

/// 两件新事：
/// 1. 目标站（杜比）必填 TMDB 链接，源站没带时用豆瓣/IMDb 号去 TMDB 反查（可走 API 代理网关）；
/// 2. 猫站发种成功后自动点「帖子免费1天」（扣猫粮，站点卡片上勾选才做）。
final class TMDBAutoFreeTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private let client = HTTPClient(cookies: CookieStore(), userAgent: "BoxSendTest")

    private func adapter(_ id: String) -> NexusPHPAdapter {
        guard let site = SiteRegistry.prioritySites.first(where: { $0.id == id }) else {
            return NexusPHPAdapter(site: SiteConfig(id: id, name: id, url: "https://example.com/",
                                                    framework: .nexusPHP, enabled: true), client: client)
        }
        return NexusPHPAdapter(site: SiteRegistry.effectiveSite(site), client: client)
    }

    private func values(_ fields: [HTTPClient.MultipartField], _ name: String) -> [String] {
        fields.filter { $0.name == name }.map { $0.value }
    }
    private func value(_ fields: [HTTPClient.MultipartField], _ name: String) -> String? {
        values(fields, name).last
    }

    // MARK: - 1. 搜索词提取

    func testSearchQueryFromReleaseName() {
        XCTAssertEqual(TMDBResolver.searchQuery(
            fromName: "Gekijouban Gintama Kanketsu-hen Yorozuyayo eien nare 2013 1080p Blu-ray AVC DTS-HD MA 5.1-LuckDIY")
            .query, "Gekijouban Gintama Kanketsu-hen Yorozuyayo eien nare")
        XCTAssertEqual(TMDBResolver.searchQuery(
            fromName: "Gekijouban Gintama Kanketsu-hen Yorozuyayo eien nare 2013 1080p Blu-ray").year, 2013)
        // 组名方括号段整段丢掉，只留片名
        XCTAssertEqual(TMDBResolver.searchQuery(
            fromName: "[VCB-Studio] Yuru Yuri [S03][1080p][x264_FLAC].mkv").query, "Yuru Yuri")
        XCTAssertEqual(TMDBResolver.searchQuery(
            fromName: "Chu Li 2026 S01 E01-E06 2160p WEB-DL H265 AAC-PTerWEB").query, "Chu Li")
    }

    // MARK: - 2. 请求 URL 与响应解析

    func testRequestURLs() {
        let find = TMDBResolver.findURL(base: "https://gw.example.com/tmdb/3", key: "K1", imdb: "tt2374144")
        XCTAssertTrue(find.hasPrefix("https://gw.example.com/tmdb/3/find/tt2374144?external_source=imdb_id"))
        XCTAssertTrue(find.contains("api_key=K1"))
        // 网关代填 key 时不带 api_key
        XCTAssertFalse(TMDBResolver.findURL(base: "https://gw.example.com/tmdb/3", key: "", imdb: "tt1")
            .contains("api_key"))
        let search = TMDBResolver.searchURL(base: "https://a/3", key: "K", type: "movie",
                                           query: "Some Movie", year: 2013)
        XCTAssertTrue(search.contains("/search/movie?query=Some%20Movie"))
        XCTAssertTrue(search.contains("year=2013"))
        XCTAssertTrue(TMDBResolver.externalIDsURL(base: "https://a/3", key: "K", type: "tv", id: 42)
            .hasPrefix("https://a/3/tv/42/external_ids"))
    }

    func testResponseParsing() throws {
        let find = Data(#"{"movie_results":[{"id":225176}],"tv_results":[]}"#.utf8)
        XCTAssertEqual(TMDBResolver.findResult(find)?.type, "movie")
        XCTAssertEqual(TMDBResolver.findResult(find)?.id, 225176)
        let tv = Data(#"{"movie_results":[],"tv_results":[{"id":99}]}"#.utf8)
        XCTAssertEqual(TMDBResolver.findResult(tv)?.type, "tv")
        XCTAssertEqual(TMDBResolver.findResult(tv)?.id, 99)
        XCTAssertNil(TMDBResolver.findResult(Data("{}".utf8)))

        let search = Data(#"{"results":[{"id":7},{"id":8},{"id":9}]}"#.utf8)
        XCTAssertEqual(TMDBResolver.searchResults(search), [7, 8, 9])

        // 豆瓣号字段：电影 douban_id，剧集 douban_tv_id（按包含 douban 的键取）
        let ext = TMDBResolver.parseExternalIDs(
            Data(#"{"imdb_id":"tt2374144","douban_id":"11615927","tvdb_id":null}"#.utf8))
        XCTAssertEqual(ext.imdb, "tt2374144")
        XCTAssertEqual(ext.douban, "11615927")
        XCTAssertEqual(TMDBResolver.parseExternalIDs(
            Data(#"{"douban_tv_id":"2589"}"#.utf8)).douban, "2589")
    }

    func testResolverReportsFailureInsteadOfGuessing() {
        // 指向一个必然连不通的地址：查不到要给出原因，不能瞎猜一个链接塞进目标站
        var cfg = TMDBConfig(enabled: true, apiBase: "http://127.0.0.1:1/3", apiKey: "k")
        let r = TMDBResolver(client: client, config: cfg)
        XCTAssertNil(r.resolve(imdb: "tt2374144", douban: "11615927",
                               name: "Some Movie 2013 1080p BluRay"))
        XCTAssertNotNil(r.lastError)
        cfg.enabled = false
        XCTAssertNil(cfg.resolvedAPIBase, "关掉开关就不该发请求")
    }

    // MARK: - 2.5 检索词、年份过滤、唯一候选兜底（用户实测 LuckPT 43775 寒蝉·煌 S04）

    func testSeasonMarkersAreDroppedFromQuery() {
        // 发布名里的季标记会让 TMDB 检索直接 0 条
        XCTAssertEqual(TMDBResolver.searchQuery(
            fromName: "Higurashi Kira S04 2011 1080p Blu-ray Remux AVC FLAC 2.0-LuckAni").query,
            "Higurashi Kira")
        XCTAssertEqual(TMDBResolver.searchQuery(
            fromName: "Some Show S03E05 2019 1080p WEB-DL").query, "Some Show")
        XCTAssertEqual(TMDBResolver.searchQuery(fromName: "寒蝉鸣泣之时·煌 [内封中字]").query, "寒蝉鸣泣之时·煌")
        // 片名本身的数字不能当季集标记剔掉
        XCTAssertEqual(TMDBResolver.searchQuery(
            fromName: "Gintama Movie 2 2013 1080p Blu-ray").query, "Gintama Movie 2")
    }

    /// 桩响应：find 查不到（番剧 IMDb 号挂在篇上）、tv 检索只有一个候选、外部号对不上
    private func stubbedResolver(_ handler: @escaping (String) -> (Int, String)) -> TMDBResolver {
        let r = TMDBResolver(client: client, config: TMDBConfig(enabled: true,
                                                              apiBase: "https://gw.example.com/tmdb/3",
                                                              apiKey: "K"))
        r.transport = { url, _ in let (code, body) = handler(url); return (code, Data(body.utf8)) }
        return r
    }

    func testSingleCandidateUsedWhenIDsDontMatchAndYearFilterIsSkippedFirst() {
        var urls: [String] = []
        let r = stubbedResolver { url in
            urls.append(url)
            if url.contains("/find/") { return (200, #"{"movie_results":[],"tv_results":[]}"#) }
            if url.contains("/external_ids") { return (200, #"{"imdb_id":"tt0845738"}"#) }
            if url.contains("/search/tv") {
                return (200, #"{"page":1,"results":[{"id":25760}],"total_results":1}"#)
            }
            return (200, #"{"page":1,"results":[],"total_results":0}"#)
        }
        XCTAssertEqual(r.resolve(imdb: "tt2536414", douban: "6738803",
                                 name: "Higurashi Kira S04 2011 1080p Blu-ray Remux AVC FLAC 2.0-LuckAni",
                                 altName: "寒蝉鸣泣之时·煌 [内封中字]"),
                       "https://www.themoviedb.org/tv/25760",
                       "整季包只有唯一候选时按它填，别让站点因为空 TMDB 整单打回")
        XCTAssertNotNil(r.lastWarning, "没核对过 IMDb/豆瓣号要在日志里说明")
        let first = urls.first { $0.contains("/search/") } ?? ""
        XCTAssertTrue(first.contains("/search/tv"), "整季/多集先发剧集检索：\(first)")
        XCTAssertTrue(first.contains("Higurashi%20Kira"), "检索词要剔掉季标记：\(first)")
        XCTAssertFalse(first.contains("year="), "第一轮不能带年份过滤：\(first)")
    }

    func testMultipleUnverifiedCandidatesAreNotGuessed() {
        let r = stubbedResolver { url in
            if url.contains("/find/") { return (200, #"{"movie_results":[],"tv_results":[]}"#) }
            if url.contains("/external_ids") { return (200, #"{"imdb_id":"tt0000000"}"#) }
            return (200, #"{"page":1,"results":[{"id":1},{"id":2}],"total_results":2}"#)
        }
        XCTAssertNil(r.resolve(imdb: "tt2536414", douban: nil,
                               name: "Some Movie 2013 1080p Blu-ray", altName: nil))
        XCTAssertTrue(r.lastError?.contains("多个候选") == true, "实际原因：\(r.lastError ?? "nil")")
    }

    func testGatewayAPIErrorBodyCountsAsFailure() {
        let r = stubbedResolver { _ in
            (200, #"{"success":false,"status_code":34,"status_message":"The resource you requested could not be found."}"#)
        }
        XCTAssertNil(r.resolve(imdb: "tt2374144", douban: nil, name: "Some Movie 2013", altName: nil))
        XCTAssertTrue(r.lastError?.contains("34") == true,
                      "网关用 200 返回的接口错误也要报出来，实际：\(r.lastError ?? "nil")")
    }

    func testEmptySearchResultExplainsItself() {
        let r = stubbedResolver { url in
            url.contains("/find/")
                ? (200, #"{"movie_results":[],"tv_results":[]}"#)
                : (200, #"{"page":1,"results":[],"total_results":0}"#)
        }
        XCTAssertNil(r.resolve(imdb: "tt2536414", douban: nil, name: "Obscure Title 2011", altName: nil))
        XCTAssertTrue(r.lastError?.contains("没搜到") == true, "实际原因：\(r.lastError ?? "nil")")
    }

    // MARK: - 3. 填进目标站表单

    func testDolbyGetsTMDBFromLookup() throws {
        let page = try fixture("hddolby-upload.html")
        let info = ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=43749",
                               name: "Some Movie 2013 1080p Blu-ray AVC DTS-HD MA 5.1-LuckDIY", kind: .movie)
        let a = adapter("hddolby")
        XCTAssertNil(value(a.buildUploadFields(info, page: page), "tmdb_url"), "没反查就没有这项")
        a.setTMDBLookup { _ in "https://www.themoviedb.org/movie/225176" }
        XCTAssertEqual(value(a.buildUploadFields(info, page: page), "tmdb_url"),
                       "https://www.themoviedb.org/movie/225176", "杜比必填的 TMDB 链接要补上")
    }

    func testBareIDFieldGetsOnlyTheNumber() {
        let page = "<form><input type=\"text\" name=\"tmdb_id\"></form>"
        let site = SiteConfig(id: "generic", name: "通用站", url: "https://example.org/",
                              framework: .nexusPHP, enabled: true)
        let a = NexusPHPAdapter(site: site, client: client)
        a.setTMDBLookup { _ in "https://www.themoviedb.org/tv/42" }
        XCTAssertEqual(value(a.buildUploadFields(
            ReleaseInfo(siteID: "luckpt", detailURL: "https://x/details.php?id=1",
                        name: "Some Show 2019", kind: .series), page: page), "tmdb_id"), "42")
    }

    func testLookupSkippedWhenFormHasNoTMDBBox() throws {
        var called = false
        let a = adapter("pter")
        a.setTMDBLookup { _ in called = true; return "https://www.themoviedb.org/movie/1" }
        _ = a.buildUploadFields(ReleaseInfo(siteID: "luckpt",
                                            detailURL: "https://pt.luckpt.de/details.php?id=1",
                                            name: "Some Movie 2013", kind: .movie),
                                page: try fixture("pter-upload.html"))
        XCTAssertFalse(called, "猫站表单没有 TMDB 输入框，不该白跑一次外网查询")
    }

    /// 杜比异地登录会把发布页跳成两步验证页（表单没渲染）：要给明确原因，别报「请填写必填项目」
    func testTwoFactorGateIsDetected() throws {
        let gate = #"<td class="outer">公告</td><script>window.location.href = "take2fa.php?returnto=%2Fupload.php";</script>"#
        XCTAssertTrue(NexusPHPAdapter.twoFactorGate(gate))
        XCTAssertTrue(NexusPHPAdapter.twoFactorGate("<div>请完成两步验证是否本人操作</div>"))
        XCTAssertFalse(NexusPHPAdapter.twoFactorGate(try fixture("hddolby-upload.html")))
    }

    // MARK: - 4. 猫站「帖子免费1天」

    func testFreeOnceLinkNeedsTheTorrentID() throws {
        let page = try fixture("pter-detail.html")
        let href = NexusPHPAdapter.freeOnceLink(page: page, marker: "art=freeoneday", torrentID: "895830")
        XCTAssertNotNil(href, "详情页里那条带签名的链接必须找得到")
        XCTAssertTrue(href?.contains("art=freeoneday") == true)
        XCTAssertTrue(href?.contains("sign=") == true, "签名参数得带上，否则站点不认")
        XCTAssertNil(NexusPHPAdapter.freeOnceLink(page: page, marker: "art=freeoneday", torrentID: "999999"),
                     "链接只对那条帖子有效，别点到别的种子上")
    }

    func testPromoRemainingHours() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let now = formatter.date(from: "2026-10-08 19:41:08")!
        // 详情页促销到 2026-10-09 07:31:50
        let left = try XCTUnwrap(NexusPHPAdapter.promoRemainingHours(try fixture("pter-detail.html"), now: now))
        XCTAssertEqual(left, 11.845, accuracy: 0.02)
        // 点过一次之后到 2026-10-09 19:41:08：满一天，不该再扣一次猫粮
        let refilled = try XCTUnwrap(NexusPHPAdapter.promoRemainingHours(
            try fixture("pter-freed-response.html"), now: now))
        XCTAssertEqual(refilled, 24.0, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(refilled, NexusPHPAdapter.freeOnceFullDayHours)
    }

    func testFreeOnceResultReadsSiteReply() throws {
        XCTAssertEqual(NexusPHPAdapter.freeOnceResult(body: try fixture("pter-freed-response.html"), status: 200),
                       "已自动免费一天")
        XCTAssertEqual(NexusPHPAdapter.freeOnceResult(
            body: "<html><b><font color=\"red\">猫粮不足，无法免费！</font></b></html>", status: 200),
            "自动免费失败：猫粮不足，无法免费！")
        XCTAssertEqual(NexusPHPAdapter.freeOnceResult(body: "<html></html>", status: 500),
                       "自动免费失败：HTTP 500")
    }
    // MARK: - 4. 网关地址写法

    func testGatewayURLWithoutVersionGetsASecondTry() {
        // 网关常写成 …/tmdb0512（不含版本号）：先按原样试，404 再补 /3 重试
        XCTAssertEqual(TMDBResolver.baseCandidates(from: "https://gw.example.com/tmdb0512"),
                       ["https://gw.example.com/tmdb0512", "https://gw.example.com/tmdb0512/3"])
        XCTAssertEqual(TMDBResolver.baseCandidates(from: "https://gw.example.com/tmdb0512/3/"),
                       ["https://gw.example.com/tmdb0512/3"])
    }

    func testLookupWorksWhenGatewayFieldLeftEmpty() {
        // 网关留空 = 走官方接口，转种时照样要建反查器
        // （曾因空地址返回 nil，「测试成功」但转种仍报「必须填写TMDB链接」）
        let cfg = TMDBConfig(enabled: true, apiBase: "", apiKey: "k")
        XCTAssertEqual(cfg.resolvedAPIBase, TMDBConfig.officialAPIBase)
        XCTAssertNotNil(TMDBResolver.make(client: client, config: cfg))
        XCTAssertNil(TMDBResolver.make(client: client, config: nil))
        XCTAssertNil(TMDBResolver.make(client: client,
                                       config: TMDBConfig(enabled: false, apiBase: "https://gw/x/3", apiKey: "k")),
                       "关掉开关就不该反查")
    }
    /// 实站（BOXSEND_LIVE=1）：用本机配置里的代理网关真查一次，验证整条链路
    func testLiveResolverFindsAnimeSeriesThroughGateway() throws {
        guard ProcessInfo.processInfo.environment["BOXSEND_LIVE"] != nil else {
            throw XCTSkip("实站验证需 BOXSEND_LIVE=1")
        }
        guard let cfg = AppConfig.load(path: NSHomeDirectory() + "/Library/Application Support/BoxSend/boxsend.json"),
              let tmdbCfg = cfg.tmdb, tmdbCfg.resolvedAPIBase != nil else {
            throw XCTSkip("本机没有 TMDB 反查配置")
        }
        let r = TMDBResolver(client: client, config: tmdbCfg)
        let link = r.resolve(imdb: "tt2536414", douban: "6738803",
                             name: "Higurashi Kira S04 2011 1080p Blu-ray Remux AVC FLAC 2.0-LuckAni",
                             altName: "寒蝉鸣泣之时·煌 [内封中字]")
        XCTAssertEqual(link, "https://www.themoviedb.org/tv/25760",
                       "反查失败原因：\(r.lastError ?? "-")")
        // 电影仍走 IMDb find，一查即中
        let movie = TMDBResolver(client: client, config: tmdbCfg)
        XCTAssertEqual(movie.resolve(imdb: "tt2374144", douban: "11615927",
                                     name: "Gekijouban Gintama 2013 1080p Blu-ray"),
                       "https://www.themoviedb.org/movie/245917",
                       "反查失败原因：\(movie.lastError ?? "-")")
    }
}
