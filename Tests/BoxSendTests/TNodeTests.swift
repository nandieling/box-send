import Foundation
import XCTest
@testable import BoxSendKit

/// TNode（ZHUQUE）适配器测试：真实 API 响应 fixture + 离线字段映射。
final class TNodeTests: XCTestCase {

    private func fixtureData(_ name: String) -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try! Data(contentsOf: url)
    }

    private func makeAdapter() -> TNodeAdapter {
        let site = SiteConfig(id: "zhuque", name: "ZHUQUE", url: "https://zhuque.in/",
                              framework: .tnode, enabled: true)
        return TNodeAdapter(site: site, client: HTTPClient(cookies: CookieStore(), userAgent: "BoxSendTest"))
    }

    /// 用真实 option 响应预置缓存（离线）
    private func primeOptions(_ a: TNodeAdapter) {
        let j = try! JSONSerialization.jsonObject(with: fixtureData("zhuque_option.json")) as! [String: Any]
        let opts = (j["data"] as! [String: Any])["option"] as! [[String: Any]]
        let list = opts.map { TNodeAdapter.Opt(id: $0["id"] as! Int, name: $0["name"] as! String) }
        let ranges: [(TNodeAdapter.Group, Int, Int)] = [
            (.videoCoding, 100, 200), (.medium, 300, 400), (.resolution, 400, 500),
            (.category, 500, 600), (.tags, 600, 700),
        ]
        var cache: [TNodeAdapter.Group: [TNodeAdapter.Opt]] = [:]
        for (g, lo, hi) in ranges {
            cache[g] = list.filter { $0.id > lo && $0.id < hi }
        }
        a.optionsCache = cache
    }

    func testOptionGrouping() throws {
        let a = makeAdapter()
        primeOptions(a)
        let opts = try a.fetchOptions()
        XCTAssertEqual(opts[.videoCoding]?.map(\.id).sorted(), [101, 102, 103, 104, 199])
        XCTAssertEqual(opts[.medium]?.map(\.id).sorted(), [301, 302, 303, 304, 305, 306, 307, 308, 309, 399])
        XCTAssertEqual(opts[.resolution]?.map(\.id).sorted(), [401, 402, 403, 404, 499])
        XCTAssertEqual(opts[.category]?.map(\.id).sorted(), [501, 502, 503, 504, 599])
        XCTAssertEqual(opts[.tags]?.map(\.id).sorted(), [601, 602, 603, 604, 611, 613, 614, 621, 622])
    }

    func testUploadFieldsMapping() throws {
        let a = makeAdapter()
        primeOptions(a)
        var info = ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=42211",
                               name: "Food Inc 2009 1080p BluRay REMUX VC-1 DTS-HD MA 5.1-Ursuya@LuckDocu",
                               imdb: "tt1286537", size: 16_800_000_000, kind: .documentary,
                               subtitle: "毒食难肥/美味代价(台) | 内封简体中文字幕",
                               mediainfo: "General\nUnique ID : 123")
        info.descr = """
        <p>❁ 片 名: Food, Inc.</p>
        <img src="https://i.111666.best/image/a.jpeg" />
        <img src="https://i.111666.best/image/b.jpg" />
        <img src="/static/c.png" />
        """
        // 无网络：不填 imdb 依赖项（findTmdb 跳过）
        info.imdb = nil
        let fields = try a.buildUploadFields(info)
        func v(_ n: String) -> String? { fields.last(where: { $0.name == n })?.value }

        XCTAssertEqual(v("title"), info.name)
        XCTAssertEqual(v("subtitle"), "毒食难肥/美味代价(台) | 内封简体中文字幕")
        XCTAssertEqual(v("category"), "599")          // 纪录片 -> 其他
        XCTAssertEqual(v("medium"), "305")            // REMUX
        XCTAssertEqual(v("videoCoding"), "199")       // VC-1 -> Other
        XCTAssertEqual(v("resolution"), "403")        // 1080p
        XCTAssertEqual(v("anonymous"), "true")
        XCTAssertEqual(v("confirm"), "true")
        XCTAssertEqual(v("zwex"), "0")
        XCTAssertEqual(v("mediainfo"), "General\nUnique ID : 123")
        let shot = v("screenshot") ?? ""
        XCTAssertTrue(shot.contains("https://i.111666.best/image/a.jpeg"))
        XCTAssertTrue(shot.contains("https://pt.luckpt.de/static/c.png"))  // 相对路径绝对化
        XCTAssertFalse(v("tmdbid") != nil)           // 未走网络
        XCTAssertTrue(v("note")?.contains("https://pt.luckpt.de/details.php?id=42211") ?? false)
        // 字幕证据在副标题 -> 勾中字
        let tags = (v("tags") ?? "").split(separator: ",").map(String.init)
        XCTAssertTrue(tags.contains("604"), "应勾中字标签: \(tags)")
    }

    func testUploadFieldsSeriesTags() throws {
        let a = makeAdapter()
        primeOptions(a)
        let info = ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=1",
                               name: "Some Show 2020 S01E01 2160p WEB-DL H265 DTS-HD MA 5.1-GROUP",
                               imdb: nil, kind: .series, subtitle: "某剧 第 1 集",
                               mediainfo: "Format : Matroska")
        let fields = try a.buildUploadFields(info)
        func v(_ n: String) -> String? { fields.last(where: { $0.name == n })?.value }
        XCTAssertEqual(v("category"), "502")          // 剧集
        XCTAssertEqual(v("medium"), "309")            // WEB-DL
        XCTAssertEqual(v("videoCoding"), "102")       // H265
        XCTAssertEqual(v("resolution"), "404")        // 2160p
        let tags = (v("tags") ?? "").split(separator: ",").map(String.init)
        XCTAssertTrue(tags.contains("622"), "应勾分集: \(tags)")
        XCTAssertFalse(tags.contains("621"))
    }

    func testParseDetailFromFixture() throws {
        let a = makeAdapter()
        let url = "https://zhuque.in/torrent/info/54988"
        let info = try a.parseDetail(fixtureData("zhuque_info.json"), detailURL: url)
        XCTAssertEqual(info.name, "Wu fa wu tian fei che dang 1976 1080p Blu-ray AVC DTS-HD MA 2.0-HXTF")
        XCTAssertEqual(info.size, 41159194464)
        XCTAssertEqual(info.imdb, "tt2058740")
        XCTAssertEqual(info.kind, .movie)             // category 501
        XCTAssertTrue(info.torrentName.hasSuffix(".torrent"))
        XCTAssertEqual(info.torrentURL, "https://zhuque.in/api/torrent/download/54988/23be15979e34467b956a91b6cc461bfe")
        XCTAssertTrue(info.descr.contains("<img src=\"https://img3.pixhost.cc/images/6066/776203642_00000_screenshot_001.png\" />"))
        XCTAssertTrue(info.mediainfo.contains("Disc Label"))
        XCTAssertFalse(info.isForbidReseed)
    }

    func testImageURLs() {
        let html = """
        <img src="https://a.com/1.png" />
        <img src="/x/2.png" />
        <img src="https://a.com/1.png" />
        <img src="https://a.com/3.png" />
        """
        let urls = TNodeAdapter.imageURLs(fromHTML: html, base: URL(string: "https://src.pt/abc.php")!)
        XCTAssertEqual(urls, ["https://a.com/1.png", "https://src.pt/x/2.png", "https://a.com/3.png"])
        let capped = TNodeAdapter.imageURLs(fromHTML: html, base: nil, limit: 2)
        XCTAssertEqual(capped.count, 2)
    }

    func testFallbackSubtitle() {
        let info = ReleaseInfo(siteID: "s", detailURL: "u", name: "English Only Name 2020 1080p",
                               descr: "<p>中文名 第一季</p><p>更多描述</p>")
        XCTAssertEqual(TNodeAdapter.fallbackSubtitle(info), "中文名 第一季")
        let empty = ReleaseInfo(siteID: "s", detailURL: "u", name: "English Only Name", descr: "")
        XCTAssertEqual(TNodeAdapter.fallbackSubtitle(empty), "English Only Name")
    }

    func testKindFromCategory() {
        XCTAssertEqual(TNodeAdapter.kindFromCategory(501, name: "x"), .movie)
        XCTAssertEqual(TNodeAdapter.kindFromCategory(502, name: "x"), .series)
        XCTAssertEqual(TNodeAdapter.kindFromCategory(503, name: "x"), .anime)
        XCTAssertEqual(TNodeAdapter.kindFromCategory(504, name: "x"), .tvshow)
        XCTAssertEqual(TNodeAdapter.kindFromCategory(599, name: "Show S01E01 2020 1080p"), .series)
    }
    // MARK: - 实测反馈：截图框不放海报、备注写制作引用

    /// LuckPT 版式的源简介：海报 div + 制作信息 fieldset + 末尾截图
    private func luckptStyleRelease() -> ReleaseInfo {
        var info = ReleaseInfo(
            siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=43749",
            name: "Gekijouban Gintama Kanketsu-hen 2013 1080p Blu-ray AVC DTS-HD MA 5.1-LuckDIY",
            descr: """
            <div class="poster"><img src="https://img2.pixhost.to/images/5566/692556572_ptgen_poster_fyc41z.jpg" /></div>
            <fieldset><legend>制作信息</legend>原盘来自：Gintama Movie 2 1080p JPN Blu-ray-U2娘@Share<br />字幕来自字幕库：jsum@U2</fieldset>
            <img src="https://img2.pixhost.to/images/5566/692557779_01.png" />
            <img src="https://img2.pixhost.to/images/5566/692557792_02.png" />
            """)
        info.extraQuote = "转载自LuckPT，感谢发布者"
        info.imdb = "tt2374144"
        return info
    }

    func testZhuqueScreenshotExcludesPoster() {
        let shots = TNodeAdapter.screenshotValue(luckptStyleRelease()).components(separatedBy: "\n")
        XCTAssertEqual(shots, ["https://img2.pixhost.to/images/5566/692557779_01.png",
                               "https://img2.pixhost.to/images/5566/692557792_02.png"],
                       "截图框只放简介里的截图")
        XCTAssertFalse(shots.contains { $0.contains("poster") })
    }

    func testZhuqueNoteIsSourceQuotePlusProductionCredits() {
        XCTAssertEqual(TNodeAdapter.noteValue(luckptStyleRelease()),
                       "转载自LuckPT，感谢发布者\n原盘来自：Gintama Movie 2 1080p JPN Blu-ray-U2娘@Share\n"
                       + "字幕来自字幕库：jsum@U2",
                       "备注 = 来源引用 + 源简介自带制作引用，不再堆链接")
        var bare = luckptStyleRelease()
        bare.extraQuote = ""
        bare.descr = "<img src=\"https://img2.pixhost.to/x_01.png\" />正文"
        XCTAssertEqual(TNodeAdapter.noteValue(bare),
                       "转载自: https://pt.luckpt.de/details.php?id=43749", "没有来源可抄时退回源站链接")
    }
    func testPosterIsWhateverSitsAbovePTGenInfoBlock() {
        // pt-gen 排版：海报在豆瓣资料表上面，链接与 class 都没有任何提示
        let html = """
        <img src="https://cdn.example.com/a1b2c3.jpg" />
        ◎译　　名　测试片<br />◎豆瓣链接　https://movie.douban.com/subject/26386922/<br />
        <img src="https://cdn.example.com/shot_01.png" />
        <img src="https://cdn.example.com/shot_02.png" />
        """
        XCTAssertEqual(NexusPHPAdapter.posterURLs(from: html, base: "https://pt.luckpt.de/"),
                       ["https://cdn.example.com/a1b2c3.jpg"], "资料表上面的图就是封面")
        var info = ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=1",
                               name: "Test Movie 2020 1080p Blu-ray", descr: html)
        info.extraQuote = "转载自LuckPT，感谢发布者"
        XCTAssertEqual(TNodeAdapter.screenshotValue(info).components(separatedBy: "\n"),
                       ["https://cdn.example.com/shot_01.png", "https://cdn.example.com/shot_02.png"])
        // 没有资料表、也没有海报标记时：全部图片都当截图
        let plain = "<p>只有截图</p><img src=\"https://cdn.example.com/s1.png\" />"
            + "<img src=\"https://cdn.example.com/s2.png\" />"
        info.descr = plain
        XCTAssertEqual(TNodeAdapter.screenshotValue(info).components(separatedBy: "\n").count, 2,
                       "认不出海报时不该砍掉真截图")
    }
}
