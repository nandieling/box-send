import XCTest
@testable import BoxSendKit

/// 上传给目标站的 .torrent 文件名。实测 LuckPT 把中文片名写进了文件名
///（「[LuckPT].南家三姐妹 再来一碗.Minami-ke: Okawari.2008.S02.1080p.…」），
/// 照原样传上去，NexusPHP 家族那一片站全报「无效的文件名！」，一站都传不上去
final class UploadFilenameTests: XCTestCase {
    /// 出问题的真名（从 debug/fields-cmct-*.txt 第一行抄的）
    private let real = "[LuckPT].南家三姐妹 再来一碗.Minami-ke: Okawari"
        + ".2008.S02.1080p.Blu-Ray.Remux.AVC.LPCM 2.0-LuckAni.torrent"

    /// 站点最窄那条校验（只认字母数字下划线点连字符）必须过
    private let strict = "^[A-Za-z0-9_.-]+\\.torrent$"

    func testRealChineseFilenameBecomesASCIISceneStyle() {
        let out = ReseedPipeline.uploadFilename(real, title: "Minami-ke Okawari 2008")
        XCTAssertEqual(out, "LuckPT.Minami-ke.Okawari.2008.S02.1080p.Blu-Ray.Remux.AVC.LPCM"
            + ".2.0-LuckAni.torrent", out)
        XCTAssertTrue(out.range(of: strict, options: .regularExpression) != nil, out)
        XCTAssertFalse(out.unicodeScalars.contains { $0.value > 127 }, out)
        XCTAssertFalse(out.contains(".."), out)
    }

    /// 文件名整段都是中文：主标题（发给目标站的名字，本来就是 ASCII）顶上
    func testFallsBackToReleaseTitle() {
        let out = ReseedPipeline.uploadFilename("南家三姐妹.torrent",
                                               title: "Minami-ke.Okawari.2008.1080p.BluRay-LuckAni")
        XCTAssertEqual(out, "Minami-ke.Okawari.2008.1080p.BluRay-LuckAni.torrent", out)
    }

    /// 文件名和主标题都没法用：兜底一个能传上去的名字，别交个空名上去
    func testAlwaysYieldsUsableName() {
        XCTAssertEqual(ReseedPipeline.uploadFilename("种子.torrent", title: "无名"), "release.torrent")
        XCTAssertEqual(ReseedPipeline.uploadFilename("", title: ""), "release.torrent")
    }

    /// 已经是干净点分名的一律不动：改了反而让站方和人都对不上号
    func testCleanNameUntouched() {
        let clean = "Some.Movie.2020.1080p.WEB-DL.DDP5.1.x264-GRP.torrent"
        XCTAssertEqual(ReseedPipeline.uploadFilename(clean, title: "Whatever"), clean)
    }

    /// 站点少见的字符（斜杠、冒号、方括号、井号）全收成点，路径分隔不能留
    func testPathSeparatorsAndPunctuationCollapse() {
        let out = ReseedPipeline.uploadFilename("A/B:C [D]#1.torrent", title: "t")
        XCTAssertEqual(out, "A.B.C.D.1.torrent", out)
        XCTAssertTrue(out.range(of: strict, options: .regularExpression) != nil, out)
    }

    /// 长名字收在 120 以内，且截断落在分隔上，不留半个词和一个孤零零的点
    func testLongNameTruncatedOnSeparator() {
        let long = String(repeating: "Segment.", count: 40) + "Group"
        let out = ReseedPipeline.uploadFilename(long + ".torrent", title: "t")
        XCTAssertLessThanOrEqual(out.count, 120 + ".torrent".count)
        XCTAssertFalse(out.hasPrefix("."))
        XCTAssertFalse(out.dropLast(".torrent".count).hasSuffix("."), out)
    }

    func testAsciiSafeNameKeepsWordChars() {
        XCTAssertEqual(ReseedPipeline.asciiSafeName("中文 Title 2024 x265"), "Title.2024.x265")
        XCTAssertEqual(ReseedPipeline.asciiSafeName("中文"), "")
    }
}

/// 站内检索「报错」与「站内没有」是两回事；换宽松查询词再问也只该发生在后者之后
final class AssistSearchErrorRetryTests: XCTestCase {
    /// 两档检索分开计数的假站点：严格档可注入异常，宽松档可注入「这回找到了」
    private final class Probe: SiteAdapter {
        let site: SiteConfig
        let client: HTTPClient
        var override: SiteOverride? { site.overrides }
        var canPrecheckDuplicate = true
        var strictThrows = false
        var strictResult: String?
        var relaxedResult: String?
        var strictCalls = 0
        var relaxedCalls = 0
        init(site: SiteConfig, client: HTTPClient) {
            self.site = site; self.client = client
        }
        func fetchTorrentList() throws -> [ReleaseInfo] { [] }
        func fetchDetail(detailURL: String) throws -> ReleaseInfo {
            ReleaseInfo(siteID: site.id, detailURL: detailURL, name: "站内那条",
                        torrentURL: site.url + "download.php?id=1")
        }
        func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String) {
            (Data([0x64, 0x65, 0x65, 0x64]), "site.torrent")
        }
        func searchExists(_ info: ReleaseInfo) throws -> String? {
            strictCalls += 1
            if strictThrows { throw BoxSendError.badInput("站内 500") }
            return strictResult
        }
        func searchExists(_ info: ReleaseInfo, relaxed: Bool) throws -> String? {
            guard relaxed else { return try searchExists(info) }
            relaxedCalls += 1
            if strictThrows { throw BoxSendError.badInput("站内 500") }
            return relaxedResult
        }
        func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
            UploadOutcome(success: false, message: "", detailURL: nil)
        }
    }

    private final class DLStub: Downloader {
        func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                        skipChecking: Bool, upLimit: Int64) throws -> AddTorrentResult {
            AddTorrentResult(id: "")
        }
        func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                        skipChecking: Bool, upLimit: Int64, paused: Bool) throws -> AddTorrentResult {
            AddTorrentResult(id: "")
        }
        func testConnection() throws -> String { "fake" }
        func listTorrents() throws -> [LocalTorrent] { [] }
        func torrentFiles(hash: String) throws -> [(path: String, size: Int64)] { [] }
        func setPaused(hashes: [String], paused: Bool) throws {}
        func removeTorrent(hash: String, keepFiles: Bool) throws {}
        func torrentProgress(hash: String) throws -> (progress: Double, state: String)? { nil }
    }

    private func site(_ id: String) -> SiteConfig {
        SiteConfig(id: id, name: id, url: "https://\(id).invalid/",
                   framework: .nexusPHP, enabled: true)
    }

    private func torrent(_ hash: String) -> LocalTorrent {
        LocalTorrent(hash: hash, name: "Movie.\(hash).1080p", savePath: "/dl",
                     totalSize: 10 * 1_073_741_824, progress: 1,
                     trackerHosts: ["elsewhere.invalid"])
    }

    private var opts: AssistPipeline.Options {
        var o = AssistPipeline.Options()
        o.sleep = { _ in }
        return o
    }

    private func probe(relaxedRetry: Bool = true) -> (AssistPipeline, Probe, StateStore) {
        var app = AppConfig.template()
        app.sourceSites = [site("s1")]
        app.assist = AssistConfig(siteIDs: ["s1"], perSiteIntervalSec: 0, jitterSec: 0,
                                  roundBudget: 50, relaxedRetrySearch: relaxedRetry)
        let state = StateStore(dataDir: "/tmp/boxsend-er-\(UUID().uuidString)")
        let p = AssistPipeline(config: app, cookies: CookieStore(), state: state,
                               downloader: DLStub())
        let pr = Probe(site: site("s1"), client: HTTPClient(cookies: CookieStore(), userAgent: "t"))
        p.adapterFactory = { _, _ in pr }
        return (p, pr, state)
    }

    /// cookie 失效、站点 500 这类：记失败，不记「站内没有」，下一轮还得再问
    func testSearchErrorIsNotAFinalMiss() throws {
        let (p, pr, state) = probe()
        pr.strictThrows = true
        let r = p.run(torrents: [torrent("h1")], opts: opts)
        XCTAssertEqual(pr.strictCalls, 1)
        XCTAssertEqual(pr.relaxedCalls, 0, "报错不该再花一次宽松检索")
        XCTAssertTrue(r.outcomes.first?.failed == true)
        XCTAssertTrue(r.outcomes.first?.message.contains("站内检索失败") == true)
        XCTAssertNil(state.assistMissedAt(site: "s1", hash: "h1", ttlSeconds: 7 * 86_400),
                     "报错被钉成「站内没有」的话，整站要被封 7 天不再问")
        XCTAssertTrue(state.assistFailHashes(site: "s1").contains("h1"))
        _ = p.run(torrents: [torrent("h1")], opts: opts)
        XCTAssertEqual(pr.strictCalls, 2, "失败不是结论，下一轮照问")
    }

    /// 站内确实没有：严格 + 宽松各问一次，然后打负缓存，下一轮不再问
    func testCleanMissCostsTwoQueriesThenGetsCached() throws {
        let (p, pr, state) = probe()
        let r = p.run(torrents: [torrent("h1")], opts: opts)
        XCTAssertEqual(pr.strictCalls, 1)
        XCTAssertEqual(pr.relaxedCalls, 1)
        XCTAssertEqual(p.relaxedHits, 0)
        XCTAssertTrue(r.outcomes.first?.message.contains("没找到同名种子") == true)
        XCTAssertNotNil(state.assistMissedAt(site: "s1", hash: "h1", ttlSeconds: 7 * 86_400))
        _ = p.run(torrents: [torrent("h1")], opts: opts)
        XCTAssertEqual(pr.strictCalls, 1, "负缓存生效，不重复检索")
    }

    /// 站内标题与本地不同（重新打包、加了中文前缀）：宽松查询词把那条捞回来
    func testRelaxedQueryRescuesRenamedRelease() throws {
        let (p, pr, state) = probe()
        pr.relaxedResult = "https://s1.invalid/details.php?id=9"
        _ = p.run(torrents: [torrent("h1")], opts: opts)
        XCTAssertEqual(pr.relaxedCalls, 1)
        XCTAssertEqual(p.relaxedHits, 1)
        XCTAssertNil(state.assistMissedAt(site: "s1", hash: "h1", ttlSeconds: 7 * 86_400),
                     "找到了就不能记「站内没有」")
    }

    /// 关掉宽松重试：每格只问一次
    func testRelaxedRetryCanBeTurnedOff() throws {
        let (p, pr, _) = probe(relaxedRetry: false)
        _ = p.run(torrents: [torrent("h1")], opts: opts)
        XCTAssertEqual(pr.strictCalls, 1)
        XCTAssertEqual(pr.relaxedCalls, 0)
        XCTAssertEqual(p.relaxedHits, 0)
    }

    /// 预算能中途追加：界面上那个「追加 200 次」走的就是这个口子
    func testAddBudgetRaisesCeilingMidRound() {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let t = SiteThrottle(limits: .init(perSiteInterval: 0, jitter: 0, roundBudget: 2),
                             now: { clock }, pause: { _ in clock = clock.addingTimeInterval(1) })
        XCTAssertTrue(t.acquire("s1"))
        XCTAssertTrue(t.acquire("s1"))
        XCTAssertEqual(t.budget.used, 2)
        XCTAssertEqual(t.budget.total, 2)
        XCTAssertFalse(t.acquire("s1"))
        t.addBudget(3)
        XCTAssertEqual(t.remaining, 3)
        XCTAssertTrue(t.acquire("s1"))
        t.addBudget(-5)
        XCTAssertEqual(t.budget.total, 5, "负数不该把上限改小")
    }
}
