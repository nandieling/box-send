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
}
