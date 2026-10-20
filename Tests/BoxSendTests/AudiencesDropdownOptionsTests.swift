import XCTest
@testable import BoxSendKit

/// 观众（audiences.me）实测（LuckPT 46569 亡国的阿基德第2章）：媒介选成了「Blu-ray 原盘」，
/// 这份内封中字的蓝光盘应该选「Blu-ray DIY」。观众的选项写在自定义下拉里
/// （隐藏 input + `<ul>` 里 `<a data-value>`），读不到选项就只能照配置表写死 1。
final class AudiencesDropdownOptionsTests: XCTestCase {
    private static let name =
        "Code Geass: Boukoku No Akito 2 - Hikisakareshi Yokuryuu 2013 1080p Blu-ray AVC DTS-HD MA 5.1-LuckAni"

    private func fixture() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("audiences-upload.html")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func fields(_ info: ReleaseInfo) throws -> [(String, String)] {
        let site = SiteRegistry.prioritySites.first { $0.id == "audiences" }!
        let adapter = NexusPHPAdapter(site: site,
                                      client: HTTPClient(cookies: CookieStore(), userAgent: "box-send-test"))
        return try adapter.buildUploadFields(info, page: try fixture()).map { ($0.name, $0.value) }
    }

    private func first(_ fields: [(String, String)], _ name: String) -> String? {
        fields.first(where: { $0.0 == name })?.1
    }

    private func release(subtitle: String, region: String) -> ReleaseInfo {
        var info = ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=46569",
                               name: Self.name, kind: .anime, sourceName: "LuckPT")
        info.subtitle = subtitle
        info.region = region
        return info
    }

    /// 自定义下拉的选项要能读到，否则「更准的那一项」永远选不到
    func testDropdownOptionsAreReadable() throws {
        let groups = HTMLUtil.selectGroups(try fixture(), name: "medium_sel")
        let opts = groups.first?.options ?? []
        XCTAssertEqual(opts.first(where: { $0.value == "14" })?.label, "Blu-ray DIY")
        XCTAssertEqual(opts.first(where: { $0.value == "1" })?.label, "Blu-ray 原盘")
    }

    func testDIYDiscTakesBLURAYDIY() throws {
        let f = try fields(release(subtitle: "亡国的阿基德 第2章：翼龙折翅 [内封中字]", region: "日本"))
        XCTAssertEqual(first(f, "medium_sel"), "14", "内封中字的蓝光盘要选「Blu-ray DIY」")
        XCTAssertEqual(first(f, "codec_sel"), "1", "编码照旧是 H.264(AVC)")
        XCTAssertEqual(first(f, "standard_sel"), "1")
        XCTAssertEqual(first(f, "audiocodec_sel"), "19", "音频照旧是 DTS-HD MA")
    }

    /// 没有中文字幕证据的蓝光盘仍是原盘
    func testPlainDiscStillTakesRawOption() throws {
        let f = try fields(release(subtitle: "亡国的阿基德 第2章：翼龙折翅", region: "日本"))
        XCTAssertEqual(first(f, "medium_sel"), "1", "没证据就不自作主张选 DIY")
    }
}
