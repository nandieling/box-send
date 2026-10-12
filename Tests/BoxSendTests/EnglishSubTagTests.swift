import XCTest
@testable import BoxSendKit

/// 龙（longpt.org）等站的「英字」标签：源种子带英文字幕时要勾上。
/// 判据只认字幕语境里的「英」，别把「语言：英语」这类语种说明当成字幕。
final class EnglishSubTagTests: XCTestCase {
    private let client = HTTPClient(cookies: CookieStore(), userAgent: "BoxSendTest")

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func adapter(_ id: String) -> NexusPHPAdapter {
        let site = SiteRegistry.prioritySites.first(where: { $0.id == id })!
        return NexusPHPAdapter(site: SiteRegistry.effectiveSite(site), client: client)
    }

    private func release(_ name: String, descr: String) -> ReleaseInfo {
        var r = ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=1",
                            name: name, kind: .anime)
        r.descr = descr
        return r
    }

    func testEnglishSubtitleWordingIsDetected() {
        let name = "Show S01 2015 1080p Blu-ray Remux AVC AC3-LuckAni"
        let wordings: [String] = [
            "<p>字幕：中英字幕</p>",
            "<p>◎字　　幕　英文字幕</p>",
            "<p>字幕：中英特效字幕</p>",
            "<p>内封简中 / 内封英字</p>",
            "<p>字幕：中英双字</p>",
        ]
        for descr in wordings {
            XCTAssertTrue(QualityTokens.canonicalTags(release(name, descr: descr)).contains("english_sub"),
                          "应认出英文字幕：\(descr)")
        }
        // 只有发布名里的成对标注也算
        for shot in ["Show.S01.2015.1080p.Blu-ray.Remux.AVC.AC3.CHS.ENG-LuckAni",
                     "Show S01 2015 1080p Blu-ray Remux AVC AC3 ENG SUB-LuckAni"] {
            XCTAssertTrue(QualityTokens.canonicalTags(
                release(shot, descr: "<p>正文里没有字幕说明</p>")).contains("english_sub"),
                "发布名里的字幕标注也要认出：\(shot)")
        }
    }

    func testLanguageLineAloneIsNotEnglishSubtitles() {
        let cases = [
            ("<p>◎语　　言　英语</p><p>字幕：中文字幕</p>"),
            ("<p>语言: 日语 / 英语</p>"),
            ("<p>本作英文原名 Little Witch Academia</p><p>字幕：中字</p>"),
            ("<p>Overall bit rate : 46.1 Mb/s</p>"),
        ]
        for descr in cases {
            XCTAssertFalse(QualityTokens.canonicalTags(
                release("Show 2015 1080p Blu-ray Remux AVC AC3-X", descr: descr)).contains("english_sub"),
                "不该误判出英文字幕：\(descr)")
        }
    }

    /// 龙发种表单里 9=英字（tags[4][]），判到英文字幕就要勾上
    func testLongptTicksEnglishSubTag() throws {
        let page = try fixture("longpt-upload.html")
        let longpt = adapter("longpt")
        let base = "<p>◎字　　幕　中文字幕</p>"
        let plain = longpt.buildUploadFields(
            release("Show 2015 1080p Blu-ray Remux AVC AC3-LuckAni", descr: base), page: page)
        let noEng = plain.filter { $0.name == "tags[4][]" }.map { $0.value }
        XCTAssertFalse(noEng.contains("9"), "没有英文字幕时不勾英字；实际 \(noEng)")
        XCTAssertTrue(noEng.contains("6"), "中字照旧")

        let withEng = longpt.buildUploadFields(
            release("Show 2015 1080p Blu-ray Remux AVC AC3-LuckAni",
                    descr: base + "<p>◎字　　幕　中英双字幕</p>"), page: page)
        let tags = withEng.filter { $0.name == "tags[4][]" }.map { $0.value }
        XCTAssertTrue(tags.contains("9"), "9=英字；实际勾了 \(tags)")
    }
}
