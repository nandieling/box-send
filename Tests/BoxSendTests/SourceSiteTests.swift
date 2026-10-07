import XCTest
@testable import BoxSendKit

/// 源站识别：站点分组里添加过的站点（以及所有内置收录站）都要能当源站
final class SourceSiteTests: XCTestCase {

    private func cfg(_ sites: [SiteConfig]) -> AppConfig {
        var c = AppConfig.template()
        c.sourceSites = sites
        return c
    }

    /// 内置名录每一站都要能从自己的详情页链接反查出来（否则用户贴链接就报「未找到源站配置」）
    func testEveryRosterSiteResolvesFromItsOwnURL() {
        let all = SiteRegistry.prioritySites
        XCTAssertFalse(all.isEmpty)
        let c = cfg(all)
        for s in all {
            XCTAssertEqual(c.site(forURL: s.url + "details.php?id=1")?.id, s.id,
                           "\(s.id) 应能从 \(s.url) 反查为源站")
        }
    }

    func testWWWAndSubdomainVariants() {
        let c = cfg(SiteRegistry.prioritySites)
        XCTAssertEqual(c.site(forURL: "https://www.totheglory.im/details.php?id=836735")?.id, "ttg")
        // 站点配置写的是子域，链接用了主域（站点迁移/镜像入口）
        XCTAssertEqual(c.site(forURL: "https://m-team.cc/detail/123")?.id, "mteam")
        // 反过来也一样
        XCTAssertEqual(c.site(forURL: "https://kp.m-team.cc/detail/123")?.id, "mteam")
        XCTAssertNil(c.site(forURL: "https://never-heard-of.example.org/details.php?id=1"))
    }

    /// 同域名多条配置（用户另存了一条）：优先已添加并启用的那条
    func testManagedSiteWinsOnSameDomain() {
        let unmanaged = SiteConfig(id: "ttg", name: "套", url: "https://totheglory.im/",
                                   framework: .nexusPHP, enabled: false, managed: false)
        let added = SiteConfig(id: "ttg2", name: "套（镜像）", url: "https://totheglory.im/",
                               framework: .nexusPHP, enabled: true, managed: true)
        XCTAssertEqual(cfg([unmanaged, added]).site(forURL: "https://totheglory.im/details.php?id=1")?.id, "ttg2")
        // 未添加也能当源站：只有一条时按那条走
        XCTAssertEqual(cfg([unmanaged]).site(forURL: "https://totheglory.im/x")?.id, "ttg")
    }
}
