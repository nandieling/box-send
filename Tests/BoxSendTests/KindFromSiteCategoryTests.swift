import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import BoxSendKit

/// 2026-10-20 实测（同一颗 WEB-DL 电影散到天空/套/彩虹岛/馒头，类型全落「其他」）：
/// 体裁必须先看站点自己的分类行，豆瓣「◎类　　别」只是影评分类；
/// 站点值表缺 token（彩虹岛音频表没有 E-AC3）时要退到动态匹配，别把下拉留空。
final class KindFromSiteCategoryTests: XCTestCase {
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

    private func value(_ fields: [HTTPClient.MultipartField], _ name: String) -> String? {
        fields.filter { $0.name == name }.last?.value
    }

    /// 真源页：NANA 2 2006 1080p AMZN WEB-DL DDP 2.0 H.264；
    /// 站点「基本信息」行写 类型: 电影，豆瓣块写 类　　别　剧情 / 爱情
    private func source() throws -> ReleaseInfo {
        try adapter("luckpt").parseDetail(
            html: try fixture("luckpt-46561-webddp.html"),
            detailURL: "https://pt.luckpt.de/details.php?id=46561")
    }

    // MARK: - 站点分类行优先

    func testSiteCategoryRowWinsOverDoubanGenre() throws {
        let info = try source()
        XCTAssertEqual(info.siteCategory, "电影")
        XCTAssertEqual(info.kind, .movie, "豆瓣「剧情 / 爱情」不能把电影判成其他")
        XCTAssertEqual(info.genre, "剧情 / 爱情", "豆瓣那行仍要留着：题材标签从它取")
    }

    func testMovieLandsInMovieBucket() throws {
        let info = try source()
        let sky = adapter("hdsky").buildUploadFields(info, page: try fixture("hdsky-upload.html"))
        XCTAssertEqual(value(sky, "type"), "401", "天空 401=Movies/电影，不是 409=Misc/其他")
        let chd = adapter("chdbits").buildUploadFields(info, page: try fixture("chdbits-upload.html"))
        XCTAssertEqual(value(chd, "type"), "401", "彩虹岛 Movie")
    }

    /// 彩虹岛的音频值表没有 eac3：静态值表没命中时要改用动态选项匹配（7=AC3）
    func testStaticValueMapMissFallsBackToDynamicOptions() throws {
        let chd = adapter("chdbits").buildUploadFields(try source(), page: try fixture("chdbits-upload.html"))
        XCTAssertEqual(value(chd, "audiocodec_sel"), "7", "E-AC3 没有选项就按回退链选 AC3")
        XCTAssertEqual(value(chd, "medium_sel"), "18", "WEB-DL")
        XCTAssertEqual(value(chd, "source_sel"), "7", "来源选转载，不是官方")
    }

    // MARK: 同体裁按分辨率/来源分档的站（HDArea）

    /// HDArea 把电影按分辨率/来源切成十档，站方又把 4K 排第一个：
    /// 1080p WEB-DL 曾被选成 300=Movie UHD-4K
    func testHDAreaCategoryFollowsResolutionAndSource() throws {
        let page = try fixture("hdarea-upload.html")
        func type(_ name: String) throws -> String? {
            let info = ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=46561",
                                   name: name, kind: .movie)
            return value(adapter("hdarea").buildUploadFields(info, page: page), "type")
        }
        XCTAssertEqual(try type("NANA 2 2006 1080p AMZN WEB-DL DDP 2.0 H.264-LuckWeb"), "410",
                       "410=Movies 1080p，不是 300=Movie UHD-4K")
        XCTAssertEqual(try type("NANA 2 2006 2160p AMZN WEB-DL DDP5.1 H265-LuckWeb"), "300",
                       "4K 发布才落 UHD-4K 档")
        XCTAssertEqual(try type("NANA 2 2006 1080p BluRay Remux AVC LPCM-Luck"), "415", "Movies REMUX")
        XCTAssertEqual(try type("NANA 2 2006 1080p BluRay AVC DTS-HD MA5.1-Luck"), "401", "Movies Blu-ray")
        XCTAssertEqual(try type("NANA 2 2006 720p WEB-DL AAC H.264-Luck"), "411", "Movies 720p")
    }

    // MARK: - ReleaseKind 判据

    func testFromCategoryTextOnlyKnowsContentCategories() {
        XCTAssertEqual(ReleaseKind.fromCategoryText("紀錄"), .documentary)
        XCTAssertEqual(ReleaseKind.fromCategoryText("剧集"), .series)
        XCTAssertEqual(ReleaseKind.fromCategoryText("电视剧"), .series)
        XCTAssertEqual(ReleaseKind.fromCategoryText("卡通動漫"), .anime)
        XCTAssertEqual(ReleaseKind.fromCategoryText("影剧/综艺"), .tvshow)
        XCTAssertEqual(ReleaseKind.fromCategoryText("Movies/电影"), .movie)
        XCTAssertNil(ReleaseKind.fromCategoryText("剧情 / 爱情"), "影评分类不是体裁")
        XCTAssertNil(ReleaseKind.fromCategoryText("Misc(其他)"), "站点兜底分类不算体裁")
    }

    func testLinksRescueReleasesWithNoCategoryRow() {
        // 站点没有分类行、豆瓣类别也认不出时：外链决定电影 / 剧集
        XCTAssertEqual(ReleaseKind.infer(from: "NANA 2 2006 1080p WEB-DL", genre: "剧情 / 爱情",
                                         imdb: "tt0882791"), .movie)
        XCTAssertEqual(ReleaseKind.infer(from: "NANA 2 2006 1080p WEB-DL", douban: "1915393"), .movie)
        XCTAssertEqual(ReleaseKind.infer(from: "Some Show 2020 1080p WEB",
                                         tmdb: "https://www.themoviedb.org/tv/93192"), .series)
        XCTAssertEqual(ReleaseKind.infer(from: "Some Film 2020 1080p WEB",
                                         tmdb: "https://www.themoviedb.org/movie/634649"), .movie)
        XCTAssertEqual(ReleaseKind.infer(from: "某综艺 2026 第3期"), .series, "集数痕迹优先于链接")
        XCTAssertEqual(ReleaseKind.infer(from: "Random Pack 1080p"), .other, "什么线索都没有才留其他")
    }

    func testAtmosAudioPrefersAtmosOption() {
        let opts: [(value: String, label: String)] = [
            ("0", "请选择"), ("9", "TrueHD"), ("10", "TrueHD Atmos"),
            ("12", "E-AC3(DDP)"), ("13", "E-AC3 Atmos(DDP Atmos)"),
        ]
        XCTAssertEqual(QualityMatcher.match(token: "truehd atmos", attr: "audiocodec", options: opts), "10")
        XCTAssertEqual(QualityMatcher.match(token: "eac3 atmos", attr: "audiocodec", options: opts), "13")
        // 站点没有 Atmos 选项时退回同名编码本身，不再整栏留空
        let plain: [(value: String, label: String)] = [("0", "请选择"), ("9", "TrueHD"), ("12", "DDP")]
        XCTAssertEqual(QualityMatcher.match(token: "truehd atmos", attr: "audiocodec", options: plain), "9")
        XCTAssertEqual(QualityMatcher.match(token: "eac3 atmos", attr: "audiocodec", options: plain), "12")
    }

    // MARK: - 馒头（Unit3D）编码/分辨率/媒介

    private func mteam(handler: @escaping (URLRequest) -> HTTPClient.Response) throws -> Unit3DAdapter {
        var raw = SiteConfig(id: "mteam", name: "馒头", url: "https://kp.m-team.cc/",
                             framework: .unit3D, enabled: true)
        raw.apiKey = "test-key"
        let c = HTTPClient(cookies: CookieStore(), userAgent: "boxsend-test")
        c.performOverride = { handler($0) }
        return Unit3DAdapter(site: SiteRegistry.effectiveSite(raw), client: c)
    }

    private func msite() -> ReleaseInfo {
        ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=46561",
                    name: "NANA 2 2006 1080p AMZN WEB-DL DDP 2.0 H.264-LuckWeb", kind: .movie)
    }

    /// 字典接口不可用：用核对过的兜底 id（电影/HD=419、Web-DL=10、1080p=1、H.264=1、E-AC3=12）
    func testMTeamQualityFieldsFallBackToKnownIDs() throws {
        Unit3DAdapter.resetOptionCache()
        let adapter = try mteam { _ in
            HTTPClient.Response(status: 500, data: Data(), headers: [:], finalURL: "https://api.m-team.cc/x")
        }
        let f = try adapter.uploadFields(msite())
        XCTAssertEqual(value(f, "category"), "419")
        XCTAssertEqual(value(f, "medium"), "10")
        XCTAssertEqual(value(f, "standard"), "1")
        XCTAssertEqual(value(f, "videoCodec"), "1")
        XCTAssertEqual(value(f, "audioCodec"), "12")
        XCTAssertEqual(value(f, "source"), "8")
    }

    /// 字典可用时以站方返回的 id 为准（站方 2024 年后加过编码项，写死会过期）
    func testMTeamQualityFieldsUseSiteDictionary() throws {
        Unit3DAdapter.resetOptionCache()
        let adapter = try mteam { req in
            let body: String
            switch req.url!.path {
            case "/api/torrent/videoCodecList":
                body = #"{"code":"0","message":"SUCCESS","data":[{"id":"42","name":"H.264(x264/AVC)"}]}"#
            case "/api/torrent/audioCodecList":
                body = #"{"code":"0","message":"SUCCESS","data":[{"id":"77","name":"E-AC3(DDP)"}]}"#
            case "/api/torrent/standardList":
                body = #"{"code":"0","message":"SUCCESS","data":[{"id":"31","name":"1080p"}]}"#
            case "/api/torrent/mediumList":
                body = #"{"code":"0","message":"SUCCESS","data":[{"id":"88","name":"Web-DL"}]}"#
            default:
                body = #"{"code":"1","message":"No static resource"}"#   // sourceList：走兜底
            }
            return HTTPClient.Response(status: 200, data: Data(body.utf8), headers: [:],
                                       finalURL: "https://api.m-team.cc/x")
        }
        let f = try adapter.uploadFields(msite())
        XCTAssertEqual(value(f, "videoCodec"), "42")
        XCTAssertEqual(value(f, "audioCodec"), "77")
        XCTAssertEqual(value(f, "standard"), "31")
        XCTAssertEqual(value(f, "medium"), "88")
        XCTAssertEqual(value(f, "source"), "8")
        Unit3DAdapter.resetOptionCache()
    }

    /// 电影/影剧/动画按介质与分辨率分档
    func testMTeamCategoryFollowsMedium() {
        func cat(_ name: String, _ kind: ReleaseKind) -> Int {
            Unit3DAdapter.uploadCategory(for: ReleaseInfo(
                siteID: "luckpt", detailURL: "https://x/detail/1", name: name, kind: kind))
        }
        XCTAssertEqual(cat("A 2006 1080p WEB-DL DDP H.264", .movie), 419, "电影/HD")
        XCTAssertEqual(cat("A 2006 2160p BluRay x265 DTS", .movie), 421, "电影/BluRay")
        XCTAssertEqual(cat("A 2006 1080p BluRay Remux LPCM", .movie), 439, "电影/Remux")
        XCTAssertEqual(cat("A 1998 DVD9 AC3", .movie), 401, "电影/SD")
        XCTAssertEqual(cat("A 1998 DVDiso AC3", .movie), 420, "电影/DVDiSo")
        XCTAssertEqual(cat("A 2006 2160p WEB-DL DDP H265", .movie), 419, "4K 流媒体仍算 HD 档")
        XCTAssertEqual(cat("A 2006 1080p BluRay x264", .series), 438, "影剧/综艺/BluRay（站方自己就这么放）")
        XCTAssertEqual(cat("A 2011 1080p WEB-DL AAC", .tvshow), 402, "影剧/综艺/HD")
        XCTAssertEqual(cat("A S01 2011 1080p BluRay Remux", .anime), 453, "动画/BluRay")
        XCTAssertEqual(cat("A S01 2011 1080p WEB-DL", .anime), 405, "动画")
        XCTAssertEqual(cat("A 2006 1080p WEB-DL", .other), 409)
    }
}
