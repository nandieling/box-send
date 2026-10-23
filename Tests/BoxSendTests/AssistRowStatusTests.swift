import XCTest
@testable import BoxSendKit

/// 界面统计与归类：一条种子 × 一个站算一格，每格算什么、整轮几个数，都由核心库判，
/// mac 与 Windows 只负责上色，免得两端跑出两个数。
final class AssistRowStatusTests: XCTestCase {

    private func row(_ skip: String?, site: String = "a", hash: String = "h")
        -> AssistPipeline.PlanRow {
        AssistPipeline.PlanRow(siteID: site, hash: hash, torrentName: "T", skipReason: skip)
    }

    private func live(_ p: AssistPipeline.Status.Phase, _ text: String = "")
        -> AssistPipeline.LiveRow {
        AssistPipeline.LiveRow(phase: p, text: text)
    }

    /// 计划里的各类预筛 → 对应结论
    func testPlanRowsClassify() {
        XCTAssertEqual(AssistPipeline.status(plan: row(nil)), .pending)
        XCTAssertEqual(AssistPipeline.status(plan: row("该站暂不支持站内检索")), .unsupported)
        XCTAssertEqual(AssistPipeline.status(plan: row("已在该站做种")), .seeding)
        XCTAssertEqual(AssistPipeline.status(plan: row("站内没有（7 天内查过）")), .missing)
        XCTAssertEqual(AssistPipeline.status(plan: row("此前已辅过")), .assisted)
        XCTAssertEqual(AssistPipeline.status(plan: row("本轮检索预算用完")), .pending,
                       "预算用完只是这轮没排上，仍算待辅种")
    }

    /// 跑过的以进展为准：成功、失败都不该被计划里的原因盖掉
    func testLiveProgressWins() {
        XCTAssertEqual(AssistPipeline.status(of: row("站内没有（7 天内查过）"),
                                             live: live(.done, "辅种成功")), .assisted)
        XCTAssertEqual(AssistPipeline.status(of: row(nil),
                                             live: live(.failed, "加进下载器失败：连接断开")), .failed)
        XCTAssertEqual(AssistPipeline.status(of: row(nil),
                                             live: live(.verifying, "待复核")), .verifying)
        // 「跳过」那句话里带着原因，归类要跟着走，不能一律算待辅种
        XCTAssertEqual(AssistPipeline.status(of: row(nil),
                                             live: live(.skipped, "跳过：站内无此种子")), .missing)
        XCTAssertEqual(AssistPipeline.status(of: row(nil),
                                             live: live(.skipped, "跳过：已在该站做种")), .seeding)
        XCTAssertEqual(AssistPipeline.status(of: row(nil),
                                             live: live(.skipped, "待人工确认")), .manual)
        // 还在跑：照计划显示，别让人以为已经跑完
        XCTAssertEqual(AssistPipeline.status(of: row("已在该站做种"),
                                             live: live(.working, "检索中")), .seeding)
    }

    func testTallyCountsEveryBucket() {
        let rows = [
            row(nil, site: "a", hash: "1"),
            row(nil, site: "a", hash: "2"),
            row("站内没有（7 天内查过）", site: "b", hash: "1"),
            row("该站暂不支持站内检索", site: "b", hash: "2"),
            row("已在该站做种", site: "c", hash: "1"),
        ]
        let t = AssistPipeline.tally(rows: rows,
                                     live: ["b|2": live(.failed, "详情或 .torrent 下载失败")])
        XCTAssertEqual(t.total, 5)
        XCTAssertEqual(t.count(.pending), 2, "a|1、a|2 都还没轮到")
        XCTAssertEqual(t.count(.failed), 1, "b|2 计划里算「不支持检索」，真跑过就以失败为准")
        XCTAssertEqual(t.count(.unsupported), 0, "跑过的行不再按计划归类")
        XCTAssertEqual(t.count(.missing), 1)
        XCTAssertEqual(t.count(.seeding), 1)
    }

    /// 统计行的顺序与文案由核心库给；0 也列出来，免得看着像没跑
    func testStatLinesOrderAndLabels() {
        var t = AssistPipeline.Tally()
        t.increase(.assisted); t.increase(.assisted); t.increase(.pending)
        let lines = t.lines
        XCTAssertEqual(lines.map(\.status), AssistPipeline.RowStatus.allCases)
        XCTAssertEqual(lines.first?.status, .assisted)
        XCTAssertEqual(lines.first?.count, 2)
        XCTAssertTrue(lines.allSatisfy { !$0.status.statLabel.isEmpty })
    }

    /// 辅种失败要和「跳过」分开：done 与 failed 两个标记不能混
    func testFailedFlagIsItsOwnThing() {
        let o = AssistOutcome(siteID: "a", torrentName: "T", level: .sameHash,
                              detailURL: "u", message: "加进下载器失败", failed: true)
        XCTAssertFalse(o.done)
        XCTAssertTrue(o.failed)
        XCTAssertEqual(AssistPipeline.status(ofLive: live(.failed, o.message)), .failed)
    }
}

/// 计划预览：按「种子」裁行，计数仍按全量
final class PlanPreviewCapTests: XCTestCase {
    private func torrent(_ hash: String, _ size: Int64) -> LocalTorrent {
        LocalTorrent(hash: hash, name: "T-\(hash)", savePath: "/dl", totalSize: size,
                     progress: 1, trackerHosts: ["other.invalid"])
    }

    private func site(_ id: String) -> SiteConfig {
        SiteConfig(id: id, name: id, url: "https://\(id).invalid/",
                   framework: .nexusPHP, enabled: true)
    }

    func testPreviewCapsTorrentsButCountsFullRound() throws {
        let sites = (0..<3).map { site("s\($0)") }
        var app = AppConfig.template()
        app.sourceSites = sites
        app.assist = AssistConfig(siteIDs: sites.map(\.id), perSiteIntervalSec: 0, jitterSec: 0,
                                  roundBudget: 50)
        let pipe = AssistPipeline(config: app, cookies: CookieStore(),
                                  state: StateStore(dataDir: "/tmp/boxsend-plan-\(UUID().uuidString)"),
                                  downloader: EmptyDownloader())

        // 40 条种子 × 3 站：界面只列体积最大的 5 条，但摊开的格子要全
        let torrents = (0..<40).map { torrent("h\($0)", Int64(1_000 * (40 - $0))) }
        let preview = pipe.planPreview(torrents: torrents, torrentCap: 5)

        XCTAssertEqual(preview.torrents.map(\.hash), ["h0", "h1", "h2", "h3", "h4"],
                       "按体积倒序裁，收益最大的先做")
        XCTAssertEqual(Set(preview.rows.map(\.hash)).count, 5)
        XCTAssertEqual(preview.rows.count, 15, "列出的每条种子要摊开它在全站的格子")
        XCTAssertEqual(preview.total, 120, "计数按全量算")
        XCTAssertEqual(preview.allRows.count, 120)
        XCTAssertEqual(preview.willSearch, 120)
    }

    /// 只为了满足 Downloader 协议：计划预览不读下载器
    private final class EmptyDownloader: Downloader {
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
    }
}

/// 快照里的辅种块：Windows 端照这份画，不必自己从日志文案里猜数
final class AssistSnapshotStatsTests: XCTestCase {
    func testSnapshotCarriesStatLines() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("boxsend-assist-stats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let svc = try AppService(configPath: dir.appendingPathComponent("boxsend.json").path,
                                 dataDir: dir.path)

        let assist = try svc.invoke("snapshot")["assist"] as? [String: Any]
        XCTAssertNotNil(assist, "快照要带辅种状态，Windows 不必另开一条轮询")
        let stats = assist?["stats"] as? [String: Any]
        XCTAssertNotNil(stats, "整轮计数随快照回来")
        let lines = stats?["lines"] as? [[String: Any]]
        XCTAssertEqual(lines?.count, AssistPipeline.RowStatus.allCases.count,
                       "每一类给一行，0 也列出来")
        XCTAssertTrue(lines?.allSatisfy { ($0["label"] as? String)?.isEmpty == false } ?? false,
                      "标签连文案一起给，两端显示同一套话")
    }

    /// assist.scan 的整份载荷：列出的种子、每格结论、整轮计数，一次给全
    func testScanPayloadCarriesCellsAndStats() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("boxsend-assist-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let cfgPath = dir.appendingPathComponent("boxsend.json").path
        var app = AppConfig.template()
        app.sourceSites = (0..<2).map {
            SiteConfig(id: "s\($0)", name: "站\($0)", url: "https://s\($0).invalid/",
                       framework: .nexusPHP, enabled: true)
        }
        app.assist = AssistConfig(siteIDs: ["s0", "s1"], perSiteIntervalSec: 0, jitterSec: 0,
                                  roundBudget: 50)
        try JSONEncoder().encode(app).write(to: URL(fileURLWithPath: cfgPath))
        let svc = try AppService(configPath: cfgPath, dataDir: dir.path)
        let dl = SeededDownloader(hashes: ["h1", "h2", "h3"])
        svc.assistPipelineFactory = { cfg, client in
            AssistPipeline(config: cfg, cookies: CookieStore(), state: svc.state, downloader: dl)
        }

        let out = try svc.invoke("assist.scan", [:])
        XCTAssertEqual((out["torrents"] as? [[String: Any]])?.count, 3, "列出的种子就是下载器里那几条")
        let rows = (out["rows"] as? [[String: Any]]) ?? []
        XCTAssertEqual(rows.count, 6, "3 条种子 × 2 个站")
        XCTAssertEqual(rows.first?["status"] as? String, "pending")
        XCTAssertEqual(rows.first?["statusText"] as? String, "待辅种")
        let stats = out["stats"] as? [String: Any]
        let lines = (stats?["lines"] as? [[String: Any]]) ?? []
        XCTAssertEqual(lines.first { ($0["status"] as? String) == "pending" }?["count"] as? Int, 6)
        XCTAssertEqual(stats?["total"] as? Int, 6)

        // 同一份统计也要随快照回来：跑动中计数才会自己更新
        let assist = svc.snapshot()["assist"] as? [String: Any]
        let snapStats = assist?["stats"] as? [String: Any]
        XCTAssertEqual(snapStats?["total"] as? Int, 6)
    }

    /// 实站验证（默认跳过，BOXSEND_LIVE=1 时跑）：拿本机真配置走一遍 assist.scan，
    /// 上万条种子 + 上百个辅种站时载荷仍然只回「前若干条种子 × 全站格子」这一小块
    func testLiveScanPayload() throws {
        guard ProcessInfo.processInfo.environment["BOXSEND_LIVE"] != nil else {
            throw XCTSkip("实站验证需 BOXSEND_LIVE=1")
        }
        let support = NSHomeDirectory() + "/Library/Application Support/BoxSend"
        guard AppConfig.load(path: support + "/boxsend.json") != nil else {
            throw XCTSkip("没有本机配置")
        }
        let svc = try AppService(configPath: support + "/boxsend.json", dataDir: support)
        let out = try svc.invoke("assist.scan", [:])
        let torrents = (out["torrents"] as? [[String: Any]]) ?? []
        let rows = (out["rows"] as? [[String: Any]]) ?? []
        let total = out["planTotal"] as? Int ?? 0
        XCTAssertGreaterThan(out["torrentTotal"] as? Int ?? 0, 0, "下载器里应能读到种子")
        XCTAssertLessThanOrEqual(torrents.count, AssistPipeline.planTorrentCap,
                                 "界面只回裁好的那几条")
        XCTAssertFalse(rows.isEmpty)
        XCTAssertGreaterThan(total, rows.count, "计数按全量、行只回列出的那几条")
        XCTAssertNotNil(rows.first?["statusText"] as? String)
        let stats = out["stats"] as? [String: Any]
        XCTAssertEqual(stats?["total"] as? Int, total)
        NSLog("实站辅种计划：种子 %@ 条 / 列出 %@ 条 / 全量 %@ 格",
              String(describing: out["torrentTotal"]), String(torrents.count), String(total))
    }

    /// 报几条种子的假下载器
    private final class SeededDownloader: Downloader {
        let torrents: [LocalTorrent]
        init(hashes: [String]) {
            torrents = hashes.enumerated().map { i, h in
                LocalTorrent(hash: h, name: "T-\(h)", savePath: "/dl",
                             totalSize: Int64(1_000 * (10 - i)), progress: 1,
                             trackerHosts: ["elsewhere.invalid"])
            }
        }
        func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                        skipChecking: Bool, upLimit: Int64) throws -> AddTorrentResult {
            AddTorrentResult(id: "")
        }
        func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                        skipChecking: Bool, upLimit: Int64, paused: Bool) throws -> AddTorrentResult {
            AddTorrentResult(id: "")
        }
        func testConnection() throws -> String { "fake" }
        func listTorrents() throws -> [LocalTorrent] { torrents }
        func torrentFiles(hash: String) throws -> [(path: String, size: Int64)] { [] }
        func setPaused(hashes: [String], paused: Bool) throws {}
        func removeTorrent(hash: String, keepFiles: Bool) throws {}
    }
}
