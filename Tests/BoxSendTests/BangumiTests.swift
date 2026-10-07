import XCTest
@testable import BoxSendKit

/// Bangumi 条目解析/检索词生成/候选打分（馒头动画发种依赖）
final class BangumiTests: XCTestCase {

    /// 馒头 media/bangumi/search 实测响应（截断，站方把 id/type/eps 都返回成字符串）
    private static let rows: [[String: Any]] = [
        ["id": "14588", "name": "ゆるゆり", "name_cn": "摇曳百合", "date": "2011-07-04", "type": "2", "nsfw": false, "platform": "TV", "eps": "12"],
        ["id": "28900", "name": "ゆるゆり♪♪", "name_cn": "摇曳百合♪♪", "date": "2012-07-02", "type": "2", "nsfw": false, "platform": "TV", "eps": "12"],
        ["id": "99796", "name": "ゆるゆり なちゅやちゅみ!", "name_cn": "摇曳百合 夏日时光！", "date": "2015-02-18", "type": "2", "nsfw": false, "platform": "OVA", "eps": "1"],
        ["id": "127573", "name": "ゆるゆり さん☆ハイ！", "name_cn": "摇曳百合 3☆High!", "date": "2015-10-05", "type": "2", "nsfw": false, "platform": "TV", "eps": "12"],
        ["id": "136311", "name": "ゆるゆり なちゅやちゅみ!+", "name_cn": "摇曳百合 夏日时光！+", "date": "2015-08-20", "type": "2", "nsfw": false, "platform": "TV", "eps": "2"],
        ["id": "40001", "name": "ゆるゆり", "name_cn": "摇曳百合", "date": "2011-01-01", "type": "3", "nsfw": true, "platform": "TV", "eps": "12"],
    ]

    private func candidates() -> [Bangumi.Candidate] { Self.rows.compactMap { Bangumi.Candidate(row: $0) } }

    /// 站方响应把 id/type 都当字符串返回，解析要吃得下
    func testCandidateParsesStringTypedAPITypes() {
        let row: [String: Any] = ["id": "127573", "name": "ゆるゆり さん☆ハイ！", "name_cn": "摇曳百合 3☆High!",
                                  "date": "2015-10-05", "type": "2", "nsfw": false, "platform": "TV", "eps": "12"]
        let c = Bangumi.Candidate(row: row)
        XCTAssertEqual(c?.id, "127573")
        XCTAssertEqual(c?.type, 2)
        XCTAssertEqual(c?.platform, "TV")
        XCTAssertEqual(c?.episodes, 12)
        XCTAssertEqual(c?.year, 2015)
        XCTAssertEqual(Bangumi.pick([c!], keywords: ["摇曳百合"], year: 2015)?.link,
                       Bangumi.link(subjectID: "127573"))
    }

    func testSubjectIDAcceptsLinksAndBareID() {
        XCTAssertEqual(Bangumi.subjectID(from: "https://bangumi.tv/subject/14588"), "14588")
        XCTAssertEqual(Bangumi.subjectID(from: "https://bgm.tv/subject/127573?utm_source=imdb"), "127573")
        XCTAssertEqual(Bangumi.subjectID(from: "https://chibimaru.tv/subject/99/"), "99")
        XCTAssertEqual(Bangumi.subjectID(from: "14588"), "14588")
        XCTAssertNil(Bangumi.subjectID(from: "https://movie.douban.com/subject/26339249/"))
        XCTAssertNil(Bangumi.subjectID(from: ""))
        XCTAssertEqual(Bangumi.link(subjectID: "14588"), "https://bangumi.tv/subject/14588")
    }

    func testFindInDescription() {
        let html = "<p>来源</p><a href=\"https://bangumi.tv/subject/28900\">bangumi</a>"
        XCTAssertEqual(Bangumi.subjectID(inHTML: html), "28900")
        XCTAssertNil(Bangumi.subjectID(inHTML: "<p>没有条目</p>"))
    }

    /// 检索词：站名标签、季号、清晰度都不该进去
    func testSearchKeywordsFromSitePrefixedName() {
        let info = ReleaseInfo(siteID: "luckpt", detailURL: "https://x/t",
                              name: "[LuckPT].摇曳百合.第三季.Yuru.Yuri.S03.2015.1080p.BluRay.Remux.AVC.LPCM 2.0-LuckAni")
        let kws = Bangumi.searchKeywords(from: info)
        XCTAssertTrue(kws.contains("摇曳百合"), "\(kws)")
        XCTAssertTrue(kws.contains("Yuru Yuri"), "\(kws)")
        XCTAssertFalse(kws.contains { $0.contains("第三季") || $0.contains("LuckPT") || $0.contains("1080p") }, "\(kws)")
    }

    /// 同名多季：年份决定选哪一条；同年还有 OVA/SP 时选正季（第三季 2015 vs 夏日时光 OVA 2015）
    func testPickChoosesSeasonByYear() {
        let cands = candidates()
        XCTAssertEqual(Bangumi.pick(cands, keywords: ["摇曳百合"], year: 2015)?.link,
                       Bangumi.link(subjectID: "127573"))
        XCTAssertEqual(Bangumi.pick(cands, keywords: ["摇曳百合"], year: 2011)?.link,
                       Bangumi.link(subjectID: "14588"))
    }

    /// 剧场版发布应挑短篇条目，而不是当年的 TV 正季
    func testPickPrefersOVAForSpecialRelease() {
        let cands = candidates()
        XCTAssertEqual(Bangumi.pick(cands, keywords: ["摇曳百合"], year: 2015, special: true)?.link,
                       Bangumi.link(subjectID: "99796"))
    }

    /// 站方搜索命中多条时，年份就近兜底也不能挑特别篇
    func testLatinOnlyFallbackAvoidsSpecials() {
        let latinOnly = candidates().map { Bangumi.Candidate(id: $0.id, names: ["ゆるゆり"], date: $0.date,
                                                             type: $0.type, nsfw: $0.nsfw,
                                                             platform: $0.platform, episodes: $0.episodes) }
        let hit = Bangumi.pick(latinOnly, keywords: ["Yuru Yuri"], year: 2015)
        XCTAssertEqual(hit?.link, Bangumi.link(subjectID: "127573"))
    }

    /// 没年份时宁可不出结果，也不要把 S01 硬安到 S03 上
    func testPickRejectsWeakMatches() {
        let cands = candidates()
        XCTAssertNil(Bangumi.pick(cands, keywords: ["孤独摇滚"], year: 2022)?.link)
        XCTAssertNil(Bangumi.pick(cands, keywords: ["摇曳百合"], year: nil, minScore: 20)?.link)
    }

    func testResolveUsesSourceProvidedLinkWithoutSearching() {
        let info = ReleaseInfo(siteID: "luckpt", detailURL: "https://x/t", name: "任意动画",
                               bangumi: "https://bgm.tv/subject/28900")
        var searched = false
        let hit = Bangumi.resolve(info) { _ in searched = true; return [] }
        XCTAssertEqual(hit?.link, Bangumi.link(subjectID: "28900"))
        XCTAssertFalse(searched, "源站已给条目时不应再检索")
    }

    func testResolveSearchesAndReturnsNormalizedLink() {
        let info = ReleaseInfo(siteID: "luckpt", detailURL: "https://x/t",
                              name: "[LuckPT].摇曳百合.第三季.Yuru.Yuri.S03.2015.1080p.BluRay")
        var keywords: [String] = []
        let hit = Bangumi.resolve(info) { kw in keywords.append(kw); return candidates() }
        XCTAssertEqual(hit?.link, Bangumi.link(subjectID: "127573"))
        XCTAssertEqual(keywords.first, "摇曳百合")
    }

    /// 纯英文标题（无中日文）也要能检索
    func testResolveWithLatinOnlyTitle() {
        let info = ReleaseInfo(siteID: "hdbits", detailURL: "https://x/t",
                              name: "Yuru Yuri S03 2015 1080p BluRay Remux-LuckAni")
        XCTAssertEqual(Bangumi.latinTitle(in: info.name), "Yuru Yuri")
        var searched: [String] = []
        let hit = Bangumi.resolve(info) { kw in searched.append(kw); return candidates() }
        XCTAssertEqual(searched.first, "Yuru Yuri")
        XCTAssertNotNil(hit)
    }

    func testResolveReturnsNilWhenNothingMatches() {
        let info = ReleaseInfo(siteID: "luckpt", detailURL: "https://x/t", name: "某动画.S01.2020.1080p")
        XCTAssertNil(Bangumi.resolve(info) { _ in [] })
    }

    /// 打真实站点接口验证（默认跳过）：BOXSEND_LIVE=1 且本机配置里有馒头 API Key 时才跑
    func testLiveResolveAgainstSiteAPI() throws {
        guard ProcessInfo.processInfo.environment["BOXSEND_LIVE"] == "1" else { throw XCTSkip("需 BOXSEND_LIVE=1") }
        let cfg = ("$HOME" as NSString).expandingTildeInPath.isEmpty
            ? "" : FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/BoxSend/boxsend.json").path
        guard let data = FileManager.default.contents(atPath: cfg),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sites = obj["sourceSites"] as? [[String: Any]],
              let mteam = sites.first(where: { ($0["id"] as? String) == "mteam" }),
              let key = mteam["apiKey"] as? String, !key.isEmpty else {
            throw XCTSkip("本机配置里没有馒头 API Key")
        }
        var raw = SiteConfig(id: "mteam", name: "馒头", url: "https://kp.m-team.cc/",
                             framework: .unit3D, enabled: true)
        raw.apiKey = key
        let client = HTTPClient(cookies: CookieStore(), userAgent: "Mozilla/5.0")
        let adapter = Unit3DAdapter(site: SiteRegistry.effectiveSite(raw), client: client)
        let info = ReleaseInfo(siteID: "luckpt",
                               detailURL: "https://pt.luckpt.de/detail.php?id=56812",
                               name: "[LuckPT].摇曳百合.第三季.Yuru.Yuri.S03.2015.1080p.BluRay.Remux.AVC.LPCM.2.0-LuckAni")
        guard let hit = adapter.resolveBangumi(info) else { return XCTFail("真实接口应能命中条目") }
        XCTAssertEqual(hit, Bangumi.link(subjectID: "127573"), "2015 年的第三季应对应 摇曳百合 3☆High!")
    }

    func testNSFWEntryScoresLowerThanNormalOne() {
        let cands = candidates()
        let nsfw = cands.first { $0.nsfw }!
        let normal = cands.first { $0.id == "14588" }!
        XCTAssertLessThan(Bangumi.score(nsfw, keywords: ["摇曳百合"], year: 2011),
                          Bangumi.score(normal, keywords: ["摇曳百合"], year: 2011))
    }
}
