import XCTest
@testable import BoxSendKit

/// hdtime 实测（LuckPT 46569 亡国的阿基德第2章）：发种成功 2 秒后就推送，详情页里还没有
/// download.php，推送报「未找到 .torrent 下载链接」；隔几十分钟再推就正常。
/// 站方页面没就绪是暂时情况：要重试，也要在放弃时说清下一步做什么。
final class DeferredPushRetryTests: XCTestCase {
    private static let target = "https://hdtime.org/details.php?id=231456"
    private static let hdtime = SiteConfig(id: "hdtime", name: "HDTime", url: "https://hdtime.org/",
                                          framework: .nexusPHP, enabled: true)

    private final class FlakyAdapter: SiteAdapter {
        let site: SiteConfig
        let client: HTTPClient
        var override: SiteOverride? { nil }
        var canPrecheckDuplicate: Bool { false }
        let failText: String
        /// 站内前几次取不到下载入口
        let failures: Int
        private(set) var detailCalls = 0
        init(site: SiteConfig, client: HTTPClient, failures: Int, failText: String) {
            self.site = site; self.client = client; self.failures = failures; self.failText = failText
        }
        func fetchTorrentList() throws -> [ReleaseInfo] { [] }
        func fetchDetail(detailURL: String) throws -> ReleaseInfo {
            let isTarget = detailURL == DeferredPushRetryTests.target
            if isTarget {
                detailCalls += 1
                if detailCalls <= failures { throw BoxSendError.badInput("\(failText): \(detailURL)") }
            }
            return ReleaseInfo(siteID: site.id, detailURL: detailURL,
                               name: "Code Geass 2 2013 1080p Blu-ray AVC DTS-HD MA 5.1-LuckAni",
                               torrentName: (isTarget ? "hdtime" : "src") + ".torrent",
                               torrentURL: "https://hdtime.org/download.php?id=231456")
        }
        func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String) {
            (Data("seed".utf8), info.torrentName)
        }
        func searchExists(_ info: ReleaseInfo) throws -> String? { nil }
        func searchExists(_ info: ReleaseInfo, relaxed: Bool) throws -> String? { nil }
        func torrentOwnership(detailURL: String, uploadedAt: Date?) -> TorrentOwnership { .unknown }
        func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
            UploadOutcome(success: true, message: "发布成功", detailURL: DeferredPushRetryTests.target)
        }
    }

    private final class FakeDownloader: Downloader {
        var items: [String] = []
        func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                        skipChecking: Bool, upLimit: Int64) throws -> AddTorrentResult {
            items.append("push:\(filename)")
            return AddTorrentResult(id: "hash")
        }
        func testConnection() throws -> String { "fake" }
    }

    /// 工厂每次都返回同一个假适配器（换对象会把 detailCalls 清零），重试也不真等
    private func run(_ failText: String, failures: Int, expectedCalls: Int) throws
            -> (report: ReseedPipeline.Report, dl: FakeDownloader, state: StateStore) {
        var cfg = AppConfig.template()
        cfg.sourceSites = [SiteConfig(id: "src", name: "src", url: "https://src.invalid/",
                                      framework: .nexusPHP, enabled: true), Self.hdtime]
        cfg.targetSites = ["hdtime"]
        let state = StateStore(dataDir: "/tmp/boxsend-deferred-\(UUID().uuidString)")
        let dl = FakeDownloader()
        let pipe = ReseedPipeline(config: cfg, cookies: CookieStore(), state: state, downloader: dl)
        pipe.pushRetryWaits = [0, 0]
        let adapter = FlakyAdapter(site: Self.hdtime, client: HTTPClient(cookies: CookieStore(),
                                                                        userAgent: "boxsend-test"),
                                   failures: failures, failText: failText)
        pipe.adapterFactory = { _, _, _ in adapter }
        let report = try pipe.run(detailURL: "https://src.invalid/details.php?id=1",
                                 sourceSiteID: "src", opts: ReseedPipeline.Options())
        XCTAssertEqual(adapter.detailCalls, expectedCalls, "站内取详情页的次数要对得上")
        return (report, dl, state)
    }

    /// 站内第二个页面就绪了就把推送补上
    func testPushRetriesUntilSiteServesDownloadLink() throws {
        let r = try run("未找到 .torrent 下载链接", failures: 1, expectedCalls: 2)
        XCTAssertTrue(r.dl.items.contains("push:hdtime.torrent"), "第二次成功就要推下去：\(r.dl.items)")
        XCTAssertTrue(r.report.pushes.contains(where: { $0.site == "hdtime" && $0.ok }), "\(r.report.pushes)")
    }

    /// 一直没就绪：放弃时要说明可以稍后重跑补推送
    func testPersistentModerationGapReportsActionableReason() throws {
        // 重试两次就收手，别把整批拖死
        let r = try run("未找到 .torrent 下载链接（站点提示：本种子正在审核中）",
                            failures: 9, expectedCalls: 3)
        XCTAssertFalse(r.dl.items.contains("push:hdtime.torrent"), "\(r.dl.items)")
        let text = r.report.pushes.first(where: { $0.site == "hdtime" })?.message ?? ""
        XCTAssertTrue(text.contains("稍后重跑"), "要说清下一步：\(text)")
        XCTAssertFalse(r.state.isPushed(key: "hdtime#\(DeferredPushRetryTests.target)"),
                       "没推成功就不能标记为已推送，下次重跑要能补")
    }

    /// 会话失效不是暂时情况，重试没意义
    func testCookieFailureIsNotRetried() throws {
        let r = try run("会话失效（站点返回登录页）", failures: 9, expectedCalls: 1)
        XCTAssertFalse((r.report.pushes.first(where: { $0.site == "hdtime" })?.message ?? "").contains("稍后重跑"))
    }

    func testTransientClassification() {
        XCTAssertTrue(ReseedPipeline.transientPushIssue("未找到 .torrent 下载链接: https://x"))
        XCTAssertTrue(ReseedPipeline.transientPushIssue("站点提示：下载过于频繁，请等待 1 秒后再下载。"))
        XCTAssertTrue(ReseedPipeline.transientPushIssue("站点提示：本种子正在审核中"))
        XCTAssertFalse(ReseedPipeline.transientPushIssue("会话失效（站点返回登录页）"))
        XCTAssertFalse(ReseedPipeline.transientPushIssue("种子不存在"))
    }

    /// 站方也回纯文本提示（整页没有标签），这句话就是失败原因，不能丢
    func testPlainSiteNoticeIsExtracted() {
        XCTAssertEqual(NexusPHPAdapter.downloadNotice("下载过于频繁，请等待 1 秒后再下载。"),
                       "下载过于频繁，请等待 1 秒后再下载")
        XCTAssertEqual(NexusPHPAdapter.downloadNotice("<div class=x>本种子正在审核中</div>"),
                       "本种子正在审核中")
    }

    /// 详情页没有下载入口时，把站方那句话一起写进错误里
    func testMissingDownloadLinkErrorCarriesSiteNotice() throws {
        let page = """
        <html><head><title>HDTime :: 种子详情</title></head><body>
        <h1 id="top">Code Geass 2 2013 1080p Blu-ray AVC DTS-HD MA 5.1-LuckAni</h1>
        <div id="kdescr">转载自LuckPT，感谢发布者</div>
        <div class="warn">本种子正在审核中，通过后才能下载。</div>
        </body></html>
        """
        let adapter = NexusPHPAdapter(
            site: Self.hdtime,
            client: HTTPClient(cookies: CookieStore(), userAgent: "box-send-test"))
        XCTAssertThrowsError(try adapter.parseDetail(html: page, detailURL: Self.target)) { err in
            XCTAssertTrue("\(err)".contains("审核"), "要把站方提示带上，实际：\(err)")
        }
    }
}
