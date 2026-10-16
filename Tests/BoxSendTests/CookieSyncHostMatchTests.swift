import Foundation
import XCTest
@testable import BoxSendKit

/// cookie 同步的两处回归（Windows 实测）：
/// 浏览器备份按 cookie 域分组，铂金家这类站点的 cookie 记在主域 `pthome.net` 下，
/// 站点配的却是 `www.pthome.net`，只比字符串会把整站判成「本地无 cookie」（mac 版按主域/子域认）；
/// 以及快照要逐站带出「正在检测」，界面才不会整页停在「检测中」。
final class CookieSyncHostMatchTests: XCTestCase {
    private func makeService() throws -> AppService {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("boxsend-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try AppService(configPath: dir.appendingPathComponent("boxsend.json").path, dataDir: dir.path)
    }

    private func configuredSites(_ svc: AppService) -> [SiteConfig] {
        let sites = svc.snapshot()["sites"] as! [[String: Any]]
        XCTAssertTrue(sites.contains { ($0["id"] as? String) == "pthome" }, "模板里应带铂金家这站")
        return AppConfig.load(path: svc.configPath)?.sourceSites ?? []
    }

    /// 备份记在主域：要认成铂金家，并按站点自己的 host 落进 cookie 罐
    func testApexDomainBackupCookieLandsOnThatSite() throws {
        let svc = try makeService()
        _ = try svc.invoke("sites.add", ["ids": ["pthome"], "group": -1])   // 先纳管这站
        let r = svc.importBackupRaws([("CookieCloud", ["pthome.net": "uid=7; passkey=abcdef"])])
        XCTAssertEqual(r.imported, 1, "cookie 记在 pthome.net 下也要认出来")
        XCTAssertEqual(r.skipped, 0)

        let cookies = svc.snapshot()["cookies"] as! [String: Any]
        let hosts = (cookies["hosts"] as! [[String: Any]]).compactMap { $0["host"] as? String }
        XCTAssertEqual(hosts, ["www.pthome.net"], "要落到站点自己的 host，检测与发种才拿得到")

        let row = (svc.snapshot()["sites"] as! [[String: Any]]).first { ($0["id"] as? String) == "pthome" }
        XCTAssertEqual(row?["hasCookie"] as? Bool, true)
    }

    /// 备份里带前导点、大写（CookieCloud 就是这么存的）也要认
    func testBackupHostFormDoesNotMatter() throws {
        let svc = try makeService()
        let sites = configuredSites(svc)
        for raw in ["pthome.net", ".pthome.net", ".PTHome.NET", "www.pthome.net"] {
            XCTAssertEqual(AppService.matchBackupHost(raw, in: sites)?.id, "pthome", "\(raw) 应认成铂金家")
        }
        XCTAssertNil(AppService.matchBackupHost("site.without.us", in: sites))
    }

    /// 两个都能对上时取完全相同的那个：主域那站优先于「主域是它子域」的另一站
    func testExactHostWinsOverSuffixMatch() {
        let apex = SiteConfig(id: "apex", name: "主域", url: "https://pthome.net/", framework: .nexusPHP, enabled: true)
        let www = SiteConfig(id: "www", name: "带 www", url: "https://www.pthome.net/", framework: .nexusPHP, enabled: true)
        XCTAssertEqual(AppService.matchBackupHost("pthome.net", in: [www, apex])?.id, "apex")
        XCTAssertEqual(AppService.matchBackupHost("www.pthome.net", in: [apex, www])?.id, "www")
        // 只有「主域 ↔ 带 www 的同一个主机」互通：子域不同的两个站不能被认成一个
        let sub = SiteConfig(id: "sv", name: "聆音", url: "https://www.soulvoice.club/",
                             framework: .nexusPHP, enabled: true)
        XCTAssertEqual(AppService.matchBackupHost("soulvoice.club", in: [sub])?.id, "sv")
        XCTAssertNil(AppService.matchBackupHost("pt.soulvoice.club", in: [sub]),
                     "pt.soulvoice.club 是另一个站，不能塞给 www.soulvoice.club")
    }

    /// 认不出是哪个站的 host 只记 skipped，不往 cookie 罐里塞垃圾
    func testUnknownBackupHostIsSkipped() throws {
        let svc = try makeService()
        let r = svc.importBackupRaws([("CookieCloud", ["who.knows.example": "uid=1"])])
        XCTAssertEqual(r.skipped, 1)
        XCTAssertEqual(r.imported, 0)
        let cookies = svc.snapshot()["cookies"] as! [String: Any]
        XCTAssertEqual((cookies["hosts"] as? [[String: Any]])?.isEmpty, true)
    }

    /// 快照的站点项要带「正在检测」，卡片才能逐站显示进度而不是整页一个「检测中」
    func testSnapshotCarriesPerSiteCheckingFlag() throws {
        let svc = try makeService()
        let sites = svc.snapshot()["sites"] as! [[String: Any]]
        XCTAssertFalse(sites.isEmpty)
        XCTAssertTrue(sites.allSatisfy { $0["checking"] is Bool }, "每个站点项都要有 checking")
        XCTAssertTrue(sites.allSatisfy { ($0["checking"] as? Bool) == false }, "没在检测时不能报检测中")
    }
}
