import XCTest
@testable import BoxSendKit

/// 逐站推送顺序：一站转完必须立刻把该站种子推给下载器，再进下一站（不等整组转完）
final class PushOrderTests: XCTestCase {
    private final class Log {
        private var items_: [String] = []
        private let lock = NSLock()
        var items: [String] { lock.lock(); defer { lock.unlock() }; return items_ }
        func add(_ s: String) { lock.lock(); defer { lock.unlock() }; items_.append(s) }
    }

    private final class FakeAdapter: SiteAdapter {
        let site: SiteConfig
        let client: HTTPClient
        var override: SiteOverride? { nil }
        let log: Log
        init(site: SiteConfig, client: HTTPClient, log: Log) {
            self.site = site
            self.client = client
            self.log = log
        }
        func fetchTorrentList() throws -> [ReleaseInfo] { [] }
        func fetchDetail(detailURL: String) throws -> ReleaseInfo {
            ReleaseInfo(siteID: site.id, detailURL: detailURL, name: "T",
                        torrentName: "\(site.id).torrent", torrentURL: detailURL)
        }
        func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String) {
            (Data("seed".utf8), "\(site.id).torrent")
        }
        func searchExists(_ info: ReleaseInfo) throws -> String? { nil }
        func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
            log.add("reseed:\(site.id)")
            return UploadOutcome(success: true, message: "发布成功",
                                 detailURL: site.url + "details.php?id=1")
        }
    }

    private final class FakeDownloader: Downloader {
        let log: Log
        init(log: Log) { self.log = log }
        func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                        skipChecking: Bool, upLimit: Int64) throws -> AddTorrentResult {
            log.add("push:\(filename)")
            return AddTorrentResult(id: "hash")
        }
        func testConnection() throws -> String { "fake" }
    }

    private func site(_ id: String) -> SiteConfig {
        SiteConfig(id: id, name: id, url: "https://\(id).invalid/", framework: .nexusPHP, enabled: true)
    }

    func testEachSiteIsPushedBeforeTheNextSiteIsReseeded() throws {
        let log = Log()
        var cfg = AppConfig.template()
        cfg.sourceSites = [site("src"), site("ta"), site("tb")]
        cfg.targetSites = ["ta", "tb"]
        let pipe = ReseedPipeline(config: cfg, cookies: CookieStore(),
                                  state: StateStore(dataDir: "/tmp/boxsend-order-\(UUID().uuidString)"),
                                  downloader: FakeDownloader(log: log))
        pipe.adapterFactory = { s, client, _ in FakeAdapter(site: s, client: client, log: log) }
        var events: [String] = []
        var o = ReseedPipeline.Options()
        o.onSiteEvent = { e in events.append("\(e.siteID)/\(e.text)") }
        o.onSitePush = { e in events.append("\(e.siteID)/\(e.text)") }

        let report = try pipe.run(detailURL: "https://src.invalid/details.php?id=1",
                                  sourceSiteID: "src", opts: o)

        XCTAssertEqual(log.items, ["push:src.torrent",        // 源站种子先推，尽早开始做种
                                   "reseed:ta", "push:ta.torrent",   // 转完 ta 立刻推 ta
                                   "reseed:tb", "push:tb.torrent"],
                       "推送必须紧跟本站转种，不能等整组转完")
        XCTAssertEqual(report.outcomes.map { $0.site }, ["ta", "tb"])
        XCTAssertTrue(report.pushed)
        XCTAssertEqual(events.prefix(5),
                       ["ta/转种中…", "ta/转种成功", "ta/推送中…", "ta/已推送", "tb/转种中…"],
                       "站点卡片应先看到本站推送完成，再进入下一站")
    }

    /// 下载器连不上：记一条推送失败，后面的站点照常转种
    func testDownloaderFailureDoesNotBlockOtherSites() throws {
        let log = Log()
        struct Boom: Error, LocalizedError { var errorDescription: String? { "连不上" } }
        final class BrokenDownloader: Downloader {
            let log: Log
            init(log: Log) { self.log = log }
            func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                            skipChecking: Bool, upLimit: Int64) throws -> AddTorrentResult {
                log.add("push:\(filename)")
                throw Boom()
            }
            func testConnection() throws -> String { "fake" }
        }
        var cfg = AppConfig.template()
        cfg.sourceSites = [site("src"), site("ta"), site("tb")]
        cfg.targetSites = ["ta", "tb"]
        let pipe = ReseedPipeline(config: cfg, cookies: CookieStore(),
                                  state: StateStore(dataDir: "/tmp/boxsend-order-\(UUID().uuidString)"),
                                  downloader: BrokenDownloader(log: log))
        pipe.adapterFactory = { s, client, _ in FakeAdapter(site: s, client: client, log: log) }
        var failed: [String] = []
        var o = ReseedPipeline.Options()
        o.onSitePush = { e in if e.phase == .failed { failed.append(e.siteID) } }

        let report = try pipe.run(detailURL: "https://src.invalid/details.php?id=1",
                                  sourceSiteID: "src", opts: o)
        XCTAssertEqual(log.items,
                       ["push:src.torrent", "reseed:ta", "push:ta.torrent", "reseed:tb", "push:tb.torrent"],
                       "推送失败不该打断后续转种")
        XCTAssertEqual(report.outcomes.map { $0.site }, ["ta", "tb"])
        XCTAssertEqual(Set(failed), ["ta", "tb"])
        XCTAssertFalse(report.pushed)
    }
}
