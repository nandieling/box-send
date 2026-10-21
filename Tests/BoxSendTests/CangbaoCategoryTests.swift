import XCTest
@testable import BoxSendKit

/// 藏宝阁（cangbao.ge）把动画按形态拆成两个分类：404「动画」放电影与单集，
/// 405「动漫」放整季番剧（实测两栏列表：404 是阿基德剧场版 / 玩具总动员，
/// 405 是 Black Lagoon S02、魔法禁书目录 S03 这类整季包）。通用关键词顺序里
/// 「动漫」排在前面，剧场版会被它抢走——LuckPT 46641 转种时三章剧场版全进了 405。
final class CangbaoCategoryTests: XCTestCase {
    private static let movie =
        "Code Geass: Boukoku no Akito 3 - Kagayakumono Ten Yori Otsu 2015.1080p Blu-ray AVC DTS-HD MA 5.1-LuckAni"
    private static let season = "Black Lagoon S02 2006 1080p Blu-ray Remux AVC LPCM 2.0-LuckAni"

    private func fixture() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("cangbao-upload.html")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func fields(_ info: ReleaseInfo) throws -> [(String, String)] {
        let site = SiteRegistry.prioritySites.first { $0.id == "cangbao" }!
        let adapter = NexusPHPAdapter(site: site,
                                      client: HTTPClient(cookies: CookieStore(), userAgent: "box-send-test"))
        return try adapter.buildUploadFields(info, page: try fixture()).map { ($0.name, $0.value) }
    }

    private func category(_ name: String, _ kind: ReleaseKind) throws -> String? {
        let info = ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=46641",
                               name: name, kind: kind, sourceName: "LuckPT")
        return try fields(info).first(where: { $0.0 == "type" })?.1
    }

    /// 动画电影 / 单集 → 404 动画
    func testAnimeMovieTakesAnimationCategory() throws {
        XCTAssertEqual(try category(Self.movie, .anime), "404", "剧场版要落进「动画」")
    }

    /// 整季番剧 → 405 动漫
    func testWholeSeasonTakesComicCategory() throws {
        XCTAssertEqual(try category(Self.season, .anime), "405", "整季要落进「动漫」")
    }

    /// 其余体裁照旧按文案命中，不受动画换序影响
    func testOtherKindsUnaffected() throws {
        XCTAssertEqual(try category("Shang-Chi 2021 2160p WEB-DL HEVC DDP.5.1", .movie), "401")
        XCTAssertEqual(try category("The Days S01 2024 1080p WEB-DL AAC H.264", .series), "402")
    }
}
