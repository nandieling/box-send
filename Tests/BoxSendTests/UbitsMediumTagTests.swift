import XCTest
@testable import BoxSendKit

/// 优堡（ubits.club）实测（源站 LuckPT 48806「Minami-ke: Tadaima S04 2013 1080p Blu-Ray x265 FLAC 2.0-LuckAni」）：
/// ① 媒介别被标题里的 FLAC 带去 Track，源站媒介行写着 Encode、标题写着 x265，就是压制；
/// ② 「高分国剧」这种带限定词的标签，限定词不成立就不勾（日本动画不是国剧）；
/// ③ 站点没有「完结」标签，整季剧集勾「合集」、单集勾「连载」。
final class UbitsMediumTagTests: XCTestCase {
    private let client = HTTPClient(cookies: CookieStore(), userAgent: "BoxSendTest")

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func adapter(_ id: String) -> NexusPHPAdapter {
        let site = SiteRegistry.prioritySites.first { $0.id == id }!
        return NexusPHPAdapter(site: SiteRegistry.effectiveSite(site), client: client)
    }

    private func source() throws -> ReleaseInfo {
        try adapter("luckpt").parseDetail(
            html: try fixture("luckpt-48806.html"),
            detailURL: "https://pt.luckpt.de/details.php?id=48806&hit=1")
    }

    private func fields(_ id: String, _ info: ReleaseInfo) throws -> [HTTPClient.MultipartField] {
        try adapter(id).buildUploadFields(info, page: try fixture("\(id)-upload.html"))
    }
    private func values(_ fields: [HTTPClient.MultipartField], _ name: String) -> [String] {
        fields.filter { $0.name.hasPrefix(name) }.map { $0.value }
    }

    // MARK: 源站把媒介讲明了，要带出来

    func testSourceMediumRowCarried() throws {
        let info = try source()
        XCTAssertEqual(info.kind, .anime)
        XCTAssertEqual(info.sourceMedium, "Encode", "详情页「媒介: Encode」连排在类型行里，也要取出来")
    }

    // MARK: ① 媒介 = 压制(Encode)

    func testUbitsMediumPicksEncodeNotTrack() throws {
        let f = try fields("ubits", source())
        let medium = values(f, "medium_sel")
        XCTAssertTrue(medium.contains("7"), "压制(Encode)=7：\(medium)")
        XCTAssertFalse(medium.contains("9"), "Track 是无损音乐轨，FLAC 音轨的动画不该落在这")
        XCTAssertFalse(medium.contains("1"), "标题写着 x265，不是蓝光原盘")
        XCTAssertEqual(values(f, "codec_sel").last, "7", "x265 → H265(HEVC/x265)")
    }

    // MARK: ② 限定词标签

    func testUbitsSkipsQualifiedMainlandTag() throws {
        let f = try fields("ubits", source())
        let tags = values(f, "tags[4]")
        XCTAssertTrue(tags.contains("6"), "中字要勾")
        XCTAssertFalse(tags.contains("21"), "高分国剧：日本动画不是国剧，限定词不成立就不勾")
        XCTAssertFalse(tags.contains("17"), "原生原盘：压制件不勾")
        XCTAssertFalse(tags.contains("4"), "DIY：站点没有 DIY 证据（源站标签也没写）就不勾")
    }

    // MARK: ③ 连载 / 合集

    func testUbitsWholeSeasonUsesPackTag() throws {
        let tags = values(try fields("ubits", source()), "tags[4]")
        XCTAssertTrue(tags.contains("20"), "整季（源站标签「完结」）→ 合集")
        XCTAssertFalse(tags.contains("23"), "整季不勾连载")
    }

    func testUbitsSingleEpisodeUsesSerialTag() throws {
        var info = try source()
        info.name = "Minami-ke: Tadaima S04E05 2013 1080p Blu-Ray x265 FLAC 2.0-LuckAni"
        info.sourceTags = ["中字"]        // 没有「完结」标签的单集
        let tags = values(try fields("ubits", info), "tags[4]")
        XCTAssertTrue(tags.contains("23"), "单集剧集 → 连载")
        XCTAssertFalse(tags.contains("20"), "单集不勾合集")
    }

    func testSerialPackTagsAreOptIn() throws {
        // 没开 serialPackTags 的站不受这条派生影响
        let tags = values(try fields("pthome", source()), "tags")
        XCTAssertFalse(tags.contains("合集"), "未开启派生的站点不凭空多出「合集」")
    }

    // MARK: 媒介判据本身

    func testMediumFollowsSourceEncodeWithoutTitleHints() {
        XCTAssertEqual(QualityTokens.medium(from: "Minami-ke Tadaima 2013 FLAC 2.0-LuckAni",
                                             kind: .anime, sourceMedium: "Encode"), "encode",
                       "标题没写编码器时，源站媒介行写着 Encode 就按压制")
    }

    func testMediumSoftwareEncoderRules() {
        XCTAssertEqual(QualityTokens.medium(from: "Kono Subarashii Sekai 2016 1080p Blu-ray AVC LPCM 2.0-U2",
                                             kind: .anime), "bluray",
                       "AVC / H.264 只是编码格式，原生碟片不算压制")
        XCTAssertEqual(QualityTokens.medium(from: "Kono Subarashii Sekai 2016 1080p Blu-ray x264 FLAC 2.0-LuckAni",
                                             kind: .anime), "encode",
                       "标题写 x264 就是压制")
        XCTAssertEqual(QualityTokens.medium(from: "Kono Subarashii Sekai 2016 1080p Blu-ray AVC FLAC 2.0-LuckAni",
                                             kind: .anime,
                                             mediainfo: "Writing library : x265 core 109"), "encode",
                       "MediaInfo 写着 x265 也算压制")
        XCTAssertEqual(QualityTokens.medium(from: "Some Show 2020 1080p WEB-DL x265 AAC-Luck", kind: .series),
                       "webdl", "流媒体来源仍按来源分档，x265 归编码下拉")
    }

    func testMediumStillTrackForMusic() {
        XCTAssertEqual(QualityTokens.medium(from: "Ayaka Best 2013 FLAC 2.0-Luck", kind: .music), "track")
        XCTAssertEqual(QualityTokens.medium(from: "Ayaka Best 2013 FLAC 2.0-Luck", kind: nil,
                                            sourceMedium: "Track"), "track")
    }

    // MARK: 限定词判定

    func testQualifiedLabelAllowed() throws {
        let anime = try source()
        XCTAssertFalse(QualityTokens.qualifiedLabelAllowed(anime, keyword: "高分", label: "高分国剧"),
                       "日本动画不满足「国剧」")
        XCTAssertTrue(QualityTokens.qualifiedLabelAllowed(anime, keyword: "中字", label: "中字"),
                       "限定词完全一致时照常勾")
        XCTAssertTrue(QualityTokens.qualifiedLabelAllowed(anime, keyword: "中字", label: "内嵌中字"),
                       "限定词只是标签的一部分时按标签整体查事实")
        var mainland = anime
        mainland.region = "中国大陆"
        XCTAssertTrue(QualityTokens.qualifiedLabelAllowed(mainland, keyword: "高分", label: "高分国剧"),
                      "国产剧集满足「国剧」")
        var drama = anime
        drama.region = ""
        drama.kind = .movie
        XCTAssertFalse(QualityTokens.qualifiedLabelAllowed(drama, keyword: "高分", label: "高分国剧"),
                       "体裁对不上（电影 vs 剧）也不勾")
    }
}
