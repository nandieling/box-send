import XCTest
@testable import BoxSendKit

/// 多下载器：主下载器 + 附加的，以及「发种用哪台 / 辅种用哪台」的指派
final class MultiDownloaderTests: XCTestCase {

    private func cfgWithExtra(_ name: String, _ url: String) -> (AppConfig, String) {
        var cfg = AppConfig.template()
        let id = "dl-" + name
        var d = cfg.downloader.copiedAs(id: id, name: name)
        d.url = url
        cfg.updateDownloader(d)
        return (cfg, id)
    }

    /// 老配置只有一台，没有新字段：三处都要认它是主下载器
    func testLegacyConfigResolvesToMainDownloader() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppConfig.template())) as! [String: Any]
        json.removeValue(forKey: "downloaders")
        json.removeValue(forKey: "reseedDownloaderID")
        json.removeValue(forKey: "assistDownloaderID")
        let cfg = try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: json))

        XCTAssertEqual(cfg.allDownloaders.count, 1)
        XCTAssertEqual(cfg.reseedDownloader.id, cfg.downloader.id)
        XCTAssertEqual(cfg.assistDownloader.id, cfg.downloader.id)
    }

    func testAddAssignAndRemove() throws {
        var (cfg, id) = cfgWithExtra("家里NAS", "http://192.168.1.5:8080")
        XCTAssertEqual(cfg.allDownloaders.count, 2)

        cfg.assignDownloader(role: "assist", id: id)
        cfg.assignDownloader(role: "reseed", id: id)
        XCTAssertEqual(cfg.reseedDownloader.url, "http://192.168.1.5:8080")
        XCTAssertEqual(cfg.assistDownloader.url, "http://192.168.1.5:8080")

        // 主下载器删不掉
        cfg.removeDownloader(id: cfg.downloader.id)
        XCTAssertEqual(cfg.allDownloaders.count, 2)

        cfg.removeDownloader(id: id)
        XCTAssertEqual(cfg.allDownloaders.count, 1, "附加那台删掉了")
        XCTAssertEqual(cfg.reseedDownloader.id, cfg.downloader.id, "用途指回主下载器")
        XCTAssertEqual(cfg.assistDownloader.id, cfg.downloader.id)
    }

    /// 逐站限速跟着「发种那台」走：换了机器就得写进那台，否则界面设了等于没设
    func testSiteLimitsFollowReseedDownloader() throws {
        var (cfg, id) = cfgWithExtra("VPS2", "http://10.0.0.2:8080")
        cfg.assignDownloader(role: "reseed", id: id)
        cfg.setSiteUpLimitMB(20, siteID: "hdsky")

        XCTAssertEqual(cfg.downloader.siteUpLimits["hdsky"], nil, "主下载器不该被顺手写一笔")
        XCTAssertEqual(cfg.downloaderEntry(id: id).siteUpLimits["hdsky"], 20 * 1_048_576)
        XCTAssertEqual(cfg.effectiveUpLimit(siteID: "hdsky"), 20 * 1_048_576)
    }

    /// 辅种那台没指派时跟发种同一台；单独指派后各走各的
    func testAssistDownloaderFallsBackToReseed() throws {
        var (cfg, id) = cfgWithExtra("NAS", "http://nas:8080")
        cfg.assignDownloader(role: "reseed", id: id)
        XCTAssertNil(cfg.assistDownloaderID)
        XCTAssertEqual(cfg.assistDownloader.url, "http://nas:8080", "没单独指定就跟着发种那台")

        cfg.assignDownloader(role: "assist", id: cfg.downloader.id)
        XCTAssertEqual(cfg.assistDownloader.url, cfg.downloader.url)
        XCTAssertNotEqual(cfg.assistDownloader.url, cfg.reseedDownloader.url)
    }

    func testNewDownloaderNameAvoidsDuplicates() throws {
        // 只有一台时给「下载器 2」
        var cfg = AppConfig.template()
        XCTAssertEqual(cfg.nextDownloaderName(), "下载器 2")

        // 两台且用户自己起的名字正撞上默认序号：加后缀，别出现两台同名
        cfg.updateDownloader(cfg.downloader.copiedAs(id: "x", name: "下载器 2"))
        cfg.updateDownloader(cfg.downloader.copiedAs(id: "y", name: "下载器 3"))
        XCTAssertEqual(cfg.nextDownloaderName(), "下载器 4")

        var renamed = AppConfig.template()
        renamed.updateDownloader(renamed.downloader.copiedAs(id: "x", name: "下载器 2"))
        renamed.updateDownloader(renamed.downloader.copiedAs(id: "y", name: "下载器 2-1"))
        let names = Set(renamed.allDownloaders.map(\.name))
        XCTAssertFalse(names.contains(renamed.nextDownloaderName()), "给出的名字不能撞现有名")
    }
}

/// 增量扫描：种子集合摘要、变化提示、各站已辅计数
final class AssistScanSummaryTests: XCTestCase {

    private final class ListingDownloader: Downloader {
        var torrents: [LocalTorrent] = []
        func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                        skipChecking: Bool, upLimit: Int64) throws -> AddTorrentResult {
            AddTorrentResult(id: "x")
        }
        func testConnection() throws -> String { "fake" }
        func listTorrents() throws -> [LocalTorrent] { torrents }
    }

    private func torrent(_ hash: String) -> LocalTorrent {
        LocalTorrent(hash: hash, name: "T-" + hash, savePath: "/dl", totalSize: 2 * 1_073_741_824,
                     trackerHosts: ["elsewhere.invalid"])
    }

    private func pipe(_ dl: ListingDownloader, dataDir: String = "/tmp/boxsend-scan-\(UUID().uuidString)")
        -> (AssistPipeline, StateStore) {
        var app = AppConfig.template()
        app.assist = AssistConfig(siteIDs: ["hdsky"])
        let state = StateStore(dataDir: dataDir)
        return (AssistPipeline(config: app, cookies: CookieStore(), state: state, downloader: dl), state)
    }

    /// 同一份种子集合摘要要稳定（Swift 的 hashValue 跨进程会变，那样每次都报「有变化」）
    func testDigestIsOrderIndependent() {
        XCTAssertEqual(AssistPipeline.digest(of: ["b", "a"]), AssistPipeline.digest(of: ["a", "b"]))
        XCTAssertNotEqual(AssistPipeline.digest(of: ["a"]), AssistPipeline.digest(of: ["a", "b"]))
    }

    func testSummaryReportsDeltaAndCounts() throws {
        let dl = ListingDownloader()
        dl.torrents = [torrent("aa"), torrent("bb")]
        let (pipe, state) = pipe(dl)

        let first = try pipe.scanAndRecord()
        XCTAssertEqual(first.count, 2)
        XCTAssertNil(first.previousCount)
        XCTAssertTrue(first.changed)
        XCTAssertTrue(first.deltaText.contains("首次扫描"), first.deltaText)

        let again = try pipe.scanAndRecord()
        XCTAssertFalse(again.changed, "集合没变不该报「有变化」")
        XCTAssertEqual(again.deltaText, "与上次扫描一致（2 条）")

        dl.torrents.append(torrent("cc"))
        let third = try pipe.scanAndRecord()
        XCTAssertTrue(third.changed)
        XCTAssertTrue(third.deltaText.contains("比上次多 1 条"), third.deltaText)

        // 只扫已下完的：没下完的不该进候选，也就不算进摘要
        var half = torrent("dd")
        half.progress = 0.4
        dl.torrents.append(half)
        let fourth = try pipe.scanAndRecord()
        XCTAssertEqual(fourth.count, 3, "没下完的那条不算候选")

        state.markAssisted(site: "hdsky", hash: "aa", url: "https://hdsky.me/details.php?id=1",
                           level: "sameHash")
        let fifth = try pipe.scanAndRecord()
        XCTAssertEqual(fifth.assistedBySite["hdsky"], 1)
    }
}
