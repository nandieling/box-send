import XCTest
@testable import BoxSendKit

/// 第二批实测反馈（同一颗银魂剧场版 DIY 原盘散到十站）：
/// 媒介该认「Blu-ray/DIY」而不是原盘、碟片不许退到压制、DTS-HD MA 不算 TrueHD、
/// 制作组没有对应项别勾「个人原创」、DIY 不勾「原盘」标签、来源引用并进制作引用。
final class SiteMediumTagFixTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private let client = HTTPClient(cookies: CookieStore(), userAgent: "BoxSendTest")

    private func adapter(_ id: String) -> NexusPHPAdapter {
        guard let site = SiteRegistry.prioritySites.first(where: { $0.id == id }) else {
            return NexusPHPAdapter(site: SiteConfig(id: id, name: id, url: "https://example.com/",
                                                    framework: .nexusPHP, enabled: true), client: client)
        }
        return NexusPHPAdapter(site: SiteRegistry.effectiveSite(site), client: client)
    }

    private func values(_ fields: [HTTPClient.MultipartField], _ name: String) -> [String] {
        fields.filter { $0.name == name }.map { $0.value }
    }
    private func value(_ fields: [HTTPClient.MultipartField], _ name: String) -> String? {
        values(fields, name).last
    }

    /// 源站解析出的真种子（DIY 蓝光原盘 + DTS-HD MA + 中字，简介最上面是制作引用）
    private func sourceRelease() throws -> ReleaseInfo {
        try adapter("luckpt").parseDetail(
            html: try fixture("luckpt-43749-bdinfo.html"),
            detailURL: "https://pt.luckpt.de/details.php?id=43749")
    }

    private func nonDIY(_ info: ReleaseInfo) -> ReleaseInfo {
        var copy = info
        copy.name = info.name.replacingOccurrences(of: "-LuckDIY", with: "-U2")
            .replacingOccurrences(of: "LuckDIY", with: "U2")
        copy.sourceTags = info.sourceTags.filter { !$0.lowercased().contains("diy") }
        return copy
    }

    // MARK: - 1/5/6 媒介：DIY 蓝光要选 "Blu-ray/DIY"

    func testPlatinumHomePicksBluRayDIY() throws {
        let info = try sourceRelease()
        let f = adapter("pthome").buildUploadFields(info, page: try fixture("pthome-upload.html"))
        XCTAssertEqual(value(f, "medium_sel"), "14", "铂金家 14=Blu-ray/DIY，不是 1=Blu-ray(原盘)")
        XCTAssertEqual(value(f, "audiocodec_sel"), "19", "有 DTS-HD MA 选项就选它")
        let plain = adapter("pthome").buildUploadFields(nonDIY(info), page: try fixture("pthome-upload.html"))
        XCTAssertEqual(value(plain, "medium_sel"), "1", "不带 DIY 时仍按原盘")
    }

    func testDIYMediumWinsOnOtherSiteShapes() {
        let ctx = QualityMatcher.Context(isDIY: true, isDisc: true)
        // 1PT：1=Blu-ray(原盘) 19=Blu-ray/DIY
        XCTAssertEqual(QualityMatcher.match(token: "bluray", attr: "medium", options: [
            ("0", "请选择一项"), ("1", "Blu-ray(原盘)"), ("16", "UHD Blu-ray"),
            ("17", "UHD Blu-ray/DIY"), ("19", "Blu-ray/DIY"), ("3", "Remux"), ("7", "Encode"),
        ], ctx: ctx), "19")
        // 咖啡：4=Blu-ray 原盘 5=Blu-ray DIY
        XCTAssertEqual(QualityMatcher.match(token: "bluray", attr: "medium", options: [
            ("0", "请选择一项"), ("1", "UHD Blu-ray 原盘"), ("4", "Blu-ray 原盘"),
            ("5", "Blu-ray DIY"), ("7", "Encode"), ("13", "Other"),
        ], ctx: ctx), "5")
        // 库非：写 "BD" 不写 "Blu-ray"，且 "UHD 压制" 会抢
        XCTAssertEqual(QualityMatcher.match(token: "bluray", attr: "medium", options: [
            ("0", "请选择一项"), ("5", "BD DIY"), ("4", "BD 原盘"), ("6", "BD Remux"),
            ("7", "UHD 压制"), ("16", "Others"),
        ], ctx: ctx), "5")
        // 不是 DIY 时别蹭 DIY 选项
        XCTAssertEqual(QualityMatcher.match(token: "bluray", attr: "medium", options: [
            ("0", "请选择"), ("1", "Blu-ray(原盘)"), ("14", "Blu-ray/DIY"),
        ], ctx: QualityMatcher.Context(isDisc: true)), "1")
    }

    // MARK: - 2 聆音：碟片不退到「压制」，落 Other

    func testDiscReleaseFallsToOtherNotEncode() {
        let ctx = QualityMatcher.Context(isDIY: true, isDisc: true)
        let opts: [(String, String)] = [("0", "请选择一项"), ("12", "Other"), ("11", "DSD"),
                                        ("10", "APE/FLAC"), ("4", "MiniBD"), ("7", "Encode")]
        XCTAssertEqual(QualityMatcher.match(token: "bluray", attr: "medium", options: opts, ctx: ctx), "12",
                       "聆音媒介只有 MiniBD/Encode 沾边：Encode 是重编码，应选 Other")
    }

    // MARK: - 4 1PT：DTS-HD MA 勾 DTS，不是 TrueHD

    func testDTSFamilyNeverClaimsTrueHD() {
        let opts: [(String, String)] = [("0", "请选择一项"), ("1", "FLAC"), ("2", "APE"), ("3", "DTS"),
                                        ("4", "MP3"), ("6", "AAC"), ("7", "Other"), ("31", "TrueHD")]
        XCTAssertEqual(QualityMatcher.match(token: "dtsma", attr: "audiocodec", options: opts), "3",
                       "DTS-HD MA 属 DTS 家族，有 DTS 就不该勾杜比 TrueHD")
        // 站点只有 TrueHD 这一项高清音轨时，仍用它兜底（不如 AC3 差）
        XCTAssertEqual(QualityMatcher.match(token: "dtsma", attr: "audiocodec", options: [
            ("0", "请选择"), ("11", "TrueHD"), ("10", "AC3"),
        ]), "11")
    }

    // MARK: - 3 时光：没有对应制作组就别宣称「个人原创」

    func testTimeTeamUsesOtherNotPersonalOriginal() throws {
        let page = try fixture("hdtime-upload.html")
        let f = adapter("hdtime").buildUploadFields(try sourceRelease(), page: page)
        XCTAssertEqual(value(f, "team_sel[4]"), "5", "时光 5=Other；9=个人原创是宣称自己做的")
        XCTAssertNotEqual(value(f, "team_sel[4]"), "9")
        XCTAssertEqual(value(f, "medium_sel[4]"), "1", "时光媒介没有 DIY 项，1=Blu-ray")
    }

    // MARK: - 9/10 DIY 不勾「原盘」标签

    func testDIYReleaseDropsBareDiscTag() throws {
        let tags = QualityTokens.canonicalTags(try sourceRelease())
        XCTAssertTrue(tags.contains("diy"))
        XCTAssertFalse(tags.contains("disc"), "DIY 不该带「原盘」标签（52PT/劳改所按互斥审核）")
        XCTAssertTrue(QualityTokens.canonicalTags(nonDIY(try sourceRelease())).contains("disc"),
                      "不是 DIY 时原盘标签照旧")
    }

    func test52PTChecksDIYWithoutBareDisc() throws {
        let f = adapter("pt52").buildUploadFields(try sourceRelease(), page: try fixture("pt52-upload.html"))
        let tags = values(f, "tags[]")
        XCTAssertTrue(tags.contains("DIY"), "DIY 标签照勾：\(tags)")
        XCTAssertFalse(tags.contains("原盘"), "DIY 不勾原盘：\(tags)")
        XCTAssertEqual(value(f, "medium_sel"), "2", "2=Blu-ray DIY")
    }

    // MARK: - 7 来源引用并进制作引用（织梦审核）

    func testSourceQuoteMergesIntoProductionQuote() {
        let merged = NexusPHPAdapter.mergeIntoLeadingQuote(
            source: "转载自LuckPT，感谢发布者",
            text: "[quote]\n原盘来自：X 1080p JPN Blu-ray-U2娘@Share\n字幕来自字幕库：Y\n[/quote]\n[img]a.jpg[/img]")
        XCTAssertEqual(merged, "[quote]\n转载自LuckPT，感谢发布者\n原盘来自：X 1080p JPN Blu-ray-U2娘@Share\n"
                     + "字幕来自字幕库：Y\n[/quote]\n[img]a.jpg[/img]")
    }

    func testSourceQuoteNotMergedIntoTechnicalOrDeclaredBlock() {
        // BDInfo / MediaInfo 引用块是技术参数，不并
        let bdinfo = (0..<8).map { "Stream Size \(0 + $0) : 1 GB" }.joined(separator: "\n")
        XCTAssertNil(NexusPHPAdapter.mergeIntoLeadingQuote(
            source: "转载自LuckPT", text: "[quote]\nDISC INFO:\n" + bdinfo + "\n[/quote]\n正文"))
        // 块里已经声明过来源，不重复插
        XCTAssertNil(NexusPHPAdapter.mergeIntoLeadingQuote(
            source: "转载自LuckPT", text: "[quote]\n转载自HDSky\n[/quote]\n正文"))
        // 简介开头不是引用块时不并（照旧另起一段）
        XCTAssertNil(NexusPHPAdapter.mergeIntoLeadingQuote(
            source: "转载自LuckPT", text: "[img]a.jpg[/img]\n正文"))
    }
}
