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

    /// 12 个结论收成界面上的 5 组：归法在核心库里，mac 与 Windows 不会跑出两套「待你处理」
    func testStatusesGroupIntoFiveBuckets() {
        var t = AssistPipeline.Tally()
        t.increase(.assisted, 3); t.increase(.verifying)                    // 已完成
        t.increase(.manual); t.increase(.review)                            // 待你处理
        t.increase(.failed, 2)                                              // 出问题
        t.increase(.seeding); t.increase(.missing); t.increase(.rejected)
        t.increase(.filtered); t.increase(.unsupported)                     // 不用辅
        t.increase(.pending); t.increase(.paused)                           // 没轮到
        XCTAssertEqual(t.count(.done), 4)
        XCTAssertEqual(t.count(.action), 2)
        XCTAssertEqual(t.count(.trouble), 2)
        XCTAssertEqual(t.count(.skip), 5)
        XCTAssertEqual(t.count(.waiting), 2)
        XCTAssertEqual(t.buckets.map(\.bucket), AssistPipeline.Bucket.allCases,
                       "5 组固定顺序、0 也列出来")
        XCTAssertEqual(t.summaryLine, "已完成 4 · 待你处理 2 · 出问题 2 · 不用辅 5 · 没轮到 2")
        XCTAssertTrue(t.breakdown(.done).contains("已完成辅种 3"),
                      "悬停提示给出这一组里的细分")
        XCTAssertTrue(t.breakdown(.action).contains("待人工确认 1"))
        XCTAssertEqual(AssistPipeline.Tally().summaryLine, "没有格子")
    }

    /// 每个结论都得有归属：漏一个就会从 5 组计数里凭空消失
    func testEveryStatusLandsInExactlyOneBucket() {
        for st in AssistPipeline.RowStatus.allCases {
            var t = AssistPipeline.Tally()
            t.increase(st)
            XCTAssertEqual(t.buckets.reduce(0) { $0 + $1.count }, 1, "\(st.rawValue) 归组归重了或漏了")
        }
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

/// 全量目录计划：计数按全量算，格子按页摊
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

        // 40 条种子 × 3 站：目录整份留着（体积倒序），格子按页摊，计数仍按全量
        let torrents = (0..<40).map { torrent("h\($0)", Int64(1_000 * (40 - $0))) }
        let plan = pipe.planCatalog(torrents)

        XCTAssertEqual(plan.torrents.prefix(5).map(\.hash), ["h0", "h1", "h2", "h3", "h4"],
                       "按体积倒序排，收益最大的先做")
        XCTAssertEqual(plan.torrents.count, 40, "目录不裁条数：整库都要能翻到")
        let firstPage = plan.rows(Array(plan.torrents.prefix(5)))
        XCTAssertEqual(Set(firstPage.map(\.hash)).count, 5)
        XCTAssertEqual(firstPage.count, 15, "列出的每条种子要摊开它在全站的格子")
        XCTAssertEqual(plan.total, 120, "计数按全量算")
        XCTAssertEqual(plan.willSearch, 120)
        XCTAssertEqual(plan.tally.count(.pending), 120)
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
        XCTAssertEqual((stats?["buckets"] as? [[String: Any]])?.count,
                       AssistPipeline.Bucket.allCases.count,
                       "界面上摆的那 5 组也随快照回来")
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
                                  roundBudget: 50, listPageSize: 2)
        try JSONEncoder().encode(app).write(to: URL(fileURLWithPath: cfgPath))
        let svc = try AppService(configPath: cfgPath, dataDir: dir.path)
        let dl = SeededDownloader(hashes: ["h1", "h2", "h3"])
        svc.assistPipelineFactory = { cfg, client in
            AssistPipeline(config: cfg, cookies: CookieStore(), state: svc.state, downloader: dl)
        }

        let out = try svc.invoke("assist.scan", [:])
        XCTAssertEqual((out["torrents"] as? [[String: Any]])?.count, 2, "第一页只回这一页的种子")
        XCTAssertEqual(out["torrentTotal"] as? Int, 3, "目录条数按全量报，不按这一页报")
        XCTAssertEqual(out["pageCount"] as? Int, 2, "每页 2 条 → 3 条种子两页")
        XCTAssertEqual(out["pageSize"] as? Int, 2)
        let rows = (out["rows"] as? [[String: Any]]) ?? []
        XCTAssertEqual(rows.count, 4, "这一页 2 条种子 × 2 个站")
        XCTAssertEqual(rows.first?["status"] as? String, "pending")
        XCTAssertEqual(rows.first?["statusText"] as? String, "待辅种")
        let stats = out["stats"] as? [String: Any]
        let lines = (stats?["lines"] as? [[String: Any]]) ?? []
        XCTAssertEqual(lines.first { ($0["status"] as? String) == "pending" }?["count"] as? Int, 6)
        let buckets = (stats?["buckets"] as? [[String: Any]]) ?? []
        XCTAssertEqual(buckets.map { ($0["bucket"] as? String) ?? "" },
                       AssistPipeline.Bucket.allCases.map(\.rawValue),
                       "5 组的顺序与归法由核心库给")
        XCTAssertEqual(buckets.first { ($0["bucket"] as? String) == "waiting" }?["count"] as? Int, 6)
        XCTAssertTrue(buckets.allSatisfy { (($0["detail"] as? String) ?? "").isEmpty == false },
                      "每组都给细分说明，悬停才有的可看")
        XCTAssertEqual(rows.first?["bucket"] as? String, "waiting", "一格归哪一组也随格子回来")
        let listed = (out["torrents"] as? [[String: Any]]) ?? []
        XCTAssertEqual(listed.first?["summary"] as? String, "没轮到 2",
                       "明细行那句汇总由核心库拼，两端不各算一遍")
        XCTAssertEqual(listed.first?["attention"] as? Bool, false,
                       "还没跑：这条没有要人处理的，界面默认收起")
        XCTAssertEqual(stats?["total"] as? Int, 6, "整份计数 = 3 条种子 × 2 站")

        // 同一份统计也要随快照回来：跑动中计数才会自己更新
        let assist = svc.snapshot()["assist"] as? [String: Any]
        let snapStats = assist?["stats"] as? [String: Any]
        XCTAssertEqual(snapStats?["total"] as? Int, 6)

        // 翻页：换一页只换格子，目录与计数不动，也不必再读一遍下载器
        let page2 = try svc.invoke("assist.page", ["page": 1])
        XCTAssertEqual(page2["page"] as? Int, 1)
        XCTAssertEqual(page2["torrentTotal"] as? Int, 3)
        XCTAssertEqual((page2["torrents"] as? [[String: Any]])?.count, 1, "第二页只剩一条")
        XCTAssertEqual((page2["rows"] as? [[String: Any]])?.count, 2, "1 条种子 × 2 个站")
        XCTAssertEqual((page2["stats"] as? [String: Any])?["total"] as? Int, 6, "计数按全量，不随页变化")
    }

    /// 分段计时（BOXSEND_LIVE=1）：读下载器 vs 建全量目录计划，各花多久
    func testLiveScanBreakdown() throws {
        guard ProcessInfo.processInfo.environment["BOXSEND_LIVE"] != nil else {
            throw XCTSkip("实站验证需 BOXSEND_LIVE=1")
        }
        let support = NSHomeDirectory() + "/Library/Application Support/BoxSend"
        guard let cfg = AppConfig.load(path: support + "/boxsend.json") else {
            throw XCTSkip("没有本机配置")
        }
        let jar = CookieStore()
        let pipe = AssistPipeline(
            config: cfg, cookies: jar, state: StateStore(dataDir: support),
            downloader: DownloaderFactory.makeForAssist(cfg,
                client: HTTPClient(cookies: jar, userAgent: cfg.userAgent)))
        let t0 = Date()
        let all = try pipe.scanCandidates()
        let t1 = Date().timeIntervalSince(t0)
        let plan = pipe.planCatalog(all)
        let t2 = Date().timeIntervalSince(t0)
        XCTAssertFalse(plan.torrents.isEmpty)
        NSLog("实站分段：读下载器 %.1fs（%@ 条）/ 建计划 %.1fs（去重后 %@ 条、%@ 格）",
              t1, String(all.count), t2 - t1, String(plan.torrents.count), String(plan.total))
    }

    /// 实站验证（默认跳过，BOXSEND_LIVE=1 时跑）：拿本机真配置走一遍 assist.scan，
    /// 上万条种子 + 上百个辅种站时载荷仍然只回「这一页种子 × 全站格子」这一小块
    func testLiveScanPayload() throws {
        guard ProcessInfo.processInfo.environment["BOXSEND_LIVE"] != nil else {
            throw XCTSkip("实站验证需 BOXSEND_LIVE=1")
        }
        let support = NSHomeDirectory() + "/Library/Application Support/BoxSend"
        guard AppConfig.load(path: support + "/boxsend.json") != nil else {
            throw XCTSkip("没有本机配置")
        }
        let svc = try AppService(configPath: support + "/boxsend.json", dataDir: support)
        let began = Date()
        let out = try svc.invoke("assist.scan", [:])
        let scanned = Date().timeIntervalSince(began)
        let torrents = (out["torrents"] as? [[String: Any]]) ?? []
        let rows = (out["rows"] as? [[String: Any]]) ?? []
        let total = out["planTotal"] as? Int ?? 0
        XCTAssertGreaterThan(out["torrentTotal"] as? Int ?? 0, 0, "下载器里应能读到种子")
        XCTAssertLessThanOrEqual(torrents.count,
                                 (out["pageSize"] as? Int) ?? 10,
                                 "界面只回这一页的种子")
        XCTAssertFalse(rows.isEmpty)
        XCTAssertGreaterThan(total, rows.count, "计数按全量、行只回列出的那几条")
        XCTAssertNotNil(rows.first?["statusText"] as? String)
        XCTAssertNotNil(rows.first?["bucket"] as? String, "每格都带归组，Windows 才拼得出汇总")
        let stats = out["stats"] as? [String: Any]
        XCTAssertEqual(stats?["total"] as? Int, total)

        // 翻页不许再读一遍下载器：上万条要好几秒，翻一页应该几乎是瞬时
        let pageCount = out["pageCount"] as? Int ?? 1
        if pageCount > 1 {
            let paged = try svc.invoke("assist.page", ["page": 1])
            XCTAssertEqual(paged["page"] as? Int, 1, "回到第 2 页")
            XCTAssertEqual(paged["torrentTotal"] as? Int, out["torrentTotal"] as? Int,
                           "目录不因翻页而变")
            XCTAssertFalse(((paged["rows"] as? [[String: Any]]) ?? []).isEmpty)
        }
        let paged = try svc.invoke("assist.page", ["page": 0])
        let pagedAt = Date().timeIntervalSince(began) - scanned
        XCTAssertLessThan(pagedAt, 1.0, "翻页耗时应该只跟一页的行数有关：\(pagedAt)s")
        // 覆盖率与待处理队列：真实库上也要给出那句话，界面才有进度可看
        let cov = out["coverage"] as? [String: Any]
        XCTAssertNotNil(cov, "扫描结果要带覆盖率")
        XCTAssertEqual(cov?["total"] as? Int, total, "覆盖率的分母就是全量组合数")
        let percent = cov?["percent"] as? Double ?? -1
        XCTAssertTrue(percent >= 0 && percent <= 1, "百分比要在 0…1：\(percent)")
        XCTAssertFalse((cov?["line"] as? String ?? "").isEmpty, "那句覆盖率的话不能空")
        let queue = (out["queue"] as? [[String: Any]]) ?? []
        XCTAssertLessThanOrEqual(queue.count, 200, "队列有上限，几万条失败也不整表摊开")
        for item in queue.prefix(3) {
            XCTAssertFalse((item["key"] as? String ?? "").isEmpty, "队列条目要能定位到格子")
            XCTAssertFalse((item["siteName"] as? String ?? "").isEmpty, "要说清是哪个站")
        }
        NSLog("实站辅种计划：种子 %@ 条（去重前 %@）/ 本页 %@ 条 / 全量 %@ 格 / 扫描 %.1fs / 翻页 %.2fs",
              String(describing: out["torrentTotal"]), String(describing: out["torrentRaw"]),
              String(torrents.count), String(total), scanned, pagedAt)
        NSLog("实站覆盖率：%@（待处理 %@ 条）", cov?["line"] as? String ?? "-", String(queue.count))
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
