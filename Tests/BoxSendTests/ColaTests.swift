import Foundation
import XCTest
@testable import BoxSendKit

/// 可乐 PT（www.colapt.com）发种字段映射。
///
/// 判据来自全站共用的 QualityTokens，这里锁住的是「可乐这五个下拉怎么选」这件事：
/// 片源（原盘 / DIY原盘 / Remux / BDRip…）、分辨率、视频编码、HDR、音轨、字幕，
/// 以及剧集·动漫·综艺那份 release_scope。规则改动多半源于站点审核意见，
/// 所以每条都写成「为什么这么选」的一句话，方便下次回看。
final class ColaTests: XCTestCase {

    private func site() -> SiteConfig {
        SiteConfig(id: "cola", name: "可乐", url: "https://www.colapt.com/",
                   framework: .cola, enabled: true, overrides: .cola)
    }

    private func info(_ name: String, kind: ReleaseKind? = nil, descr: String = "",
                      mediainfo: String = "", subtitle: String = "",
                      tags: [String] = [], douban: String? = nil, imdb: String? = nil,
                      tmdb: String? = nil, region: String = "", size: Int64? = nil) -> ReleaseInfo {
        var i = ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/details.php?id=1",
                            name: name, descr: descr, imdb: imdb, douban: douban, tmdb: tmdb,
                            size: size, kind: kind, torrentName: name + ".torrent",
                            subtitle: subtitle, mediainfo: mediainfo, region: region,
                            sourceName: "LuckPT", sourceTags: tags)
        i.extraQuote = ""
        return i
    }

    // MARK: - 分类

    func testMediaCategory() {
        XCTAssertEqual(ColaFields.mediaCategory(info("Movie 2020 1080p BluRay", kind: .movie)), "movie")
        XCTAssertEqual(ColaFields.mediaCategory(info("Show S01E02 1080p WEB-DL", kind: .series)), "tv")
        XCTAssertEqual(ColaFields.mediaCategory(info("Anime S01E03 1080p", kind: .anime)), "anime")
        XCTAssertEqual(ColaFields.mediaCategory(info("Variety 2024 E12 1080p", kind: .tvshow)), "variety")
        // 可乐没有纪录片分类，硬塞「电影」会被审核打回，归到「其他」
        XCTAssertEqual(ColaFields.mediaCategory(info("Doc 2021 1080p WEB-DL", kind: .documentary)), "other")
        let fromText = info("Some Title 2019 1080p WEB-DL H.264", descr: "◎类　　别　　纪录片")
        XCTAssertEqual(ColaFields.mediaCategory(fromText), "other")
        XCTAssertEqual(ColaFields.categoryLabel(info("Anime S01E03 1080p", kind: .anime)), "动漫")
        XCTAssertEqual(ColaFields.kind(fromCategory: "tv"), .series)
    }

    // MARK: - 片源（原盘 / DIY原盘 / Remux 的分别）

    func testSourceRemuxBeatsDIY() {
        // Remux 是无损抽出再封装，不是「加装字幕的原盘」：有中文字幕也不进 DIY原盘
        let remux = info("Minami-ke Okawari 2008 S02E04 1080p Blu-ray Remux AVC LPCM 2.0-LuckAni",
                         kind: .anime, descr: "字幕来自字幕库：xxx", tags: ["中字"])
        XCTAssertEqual(ColaFields.source(remux), "Remux")
        XCTAssertFalse(QualityTokens.canonicalTags(remux).contains("diy"),
                       "Remux 不该打 DIY 标签")
    }

    func testSourceBlueRayDIY() {
        // DIY 判据要「外语原声 / 产地」这条证据在，才不会被国产剧的「中文字幕」带偏
        let diy = info("Gintama Movie 2 2013 1080p JPN Blu-ray AVC LPCM 5.1-U2娘",
                       kind: .movie,
                       descr: "字幕来自字幕库：Gintama BDrip", tags: ["中字"], region: "日本")
        XCTAssertEqual(ColaFields.source(diy), "DIY原盘")
    }

    func testSourcePlainDisc() {
        let disc = info("Some Movie 2019 1080p JPN Blu-ray AVC LPCM 2.0-Group", kind: .movie)
        XCTAssertEqual(ColaFields.source(disc), "Blu-ray Disc")
        let uhd = info("Some Movie 2019 2160p UHD Blu-ray HEVC DTS-HD MA 5.1-Group", kind: .movie)
        XCTAssertEqual(ColaFields.source(uhd), "Blu-ray Disc")
    }

    func testSourcePressedDiscIsNotOriginal() {
        // 标题写着 x264：这是压制盘，不是原盘镜像
        let pressed = info("Some Movie 2019 1080p BluRay x264 DTS-HD MA 5.1-Group", kind: .movie)
        XCTAssertEqual(ColaFields.source(pressed), "BDRip")
        let named = info("Some Movie 2019 1080p BDRip AVC AAC-Group", kind: .movie)
        XCTAssertEqual(ColaFields.source(named), "BDRip")
    }

    func testSourceWebAndTVAndDVD() {
        XCTAssertEqual(ColaFields.source(info("Show S01E02 1080p WEB-DL AAC2.0-G")), "WEB-DL")
        XCTAssertEqual(ColaFields.source(info("Show S01E02 1080p WEBRip AAC2.0-G")), "WEBRip")
        XCTAssertEqual(ColaFields.source(info("Show S01E02 720p HDTV AAC-G")), "HDTV")
        XCTAssertEqual(ColaFields.source(info("Movie 2001 DVD5 AVC AAC-G")), "DVD")
        XCTAssertEqual(ColaFields.source(info("Movie 2001 DVDRip AVC AAC-G")), "DVDRip")
        // 一点媒介痕迹都没有：留「未知」让用户自己点，别猜成原盘
        XCTAssertNil(ColaFields.source(info("Some Title 2019 AAC 2.0-G")))
    }

    // MARK: - 分辨率 / 编码 / HDR

    func testResolution() {
        XCTAssertEqual(ColaFields.resolution(info("M 2019 2160p UHD Blu-ray HEVC")), "2160p")
        // 可乐选项表里没有 8K，8K 归到 2160p
        XCTAssertEqual(ColaFields.resolution(info("M 2019 8K Blu-ray HEVC")), "2160p")
        XCTAssertEqual(ColaFields.resolution(info("M 2019 1080p Blu-ray AVC")), "1080p")
        XCTAssertEqual(ColaFields.resolution(info("M 2019 1080i HDTV MPEG-2")), "1080i")
        XCTAssertEqual(ColaFields.resolution(info("M 2019 720p WEB-DL")), "720p")
        // 标题没写分辨率时从 MediaInfo 的高度行认一次
        let mi = "Video\nFormat : AVC\nHeight : 1 080 pixels\nScan type : Interlaced"
        XCTAssertEqual(ColaFields.resolution(info("M 2019 Blu-ray AVC", mediainfo: mi)), "1080i")
        XCTAssertNil(ColaFields.resolution(info("M 2019 FLAC 2.0-G")))
    }

    func testVideoCodec() {
        XCTAssertEqual(ColaFields.videoCodec(info("M 2019 1080p HEVC")), "HEVC / H.265")
        XCTAssertEqual(ColaFields.videoCodec(info("M 2019 1080p x264")), "AVC / H.264")
        XCTAssertEqual(ColaFields.videoCodec(info("M 2019 2160p AV1")), "AV1")
        XCTAssertEqual(ColaFields.videoCodec(info("M 2019 1080p VP9")), "VP9")
        XCTAssertEqual(ColaFields.videoCodec(info("M 2005 1080i VC-1")), "VC-1")
        // 可乐表里没有 Xvid / ProRes：认成这些就留空，别硬塞一个差不多的
        XCTAssertNil(ColaFields.videoCodec(info("M 2005 DVDRip Xvid")))
    }

    func testHDR() {
        XCTAssertEqual(ColaFields.hdr(info("M 2019 2160p Blu-ray HEVC Dolby Vision HDR10+")), "Dolby Vision + HDR10+")
        XCTAssertEqual(ColaFields.hdr(info("M 2019 2160p Blu-ray HEVC Dolby Vision")), "Dolby Vision")
        XCTAssertEqual(ColaFields.hdr(info("M 2019 2160p Blu-ray HEVC HDR10+")), "HDR10+")
        XCTAssertEqual(ColaFields.hdr(info("M 2019 2160p Blu-ray HEVC HDR10")), "HDR10")
        XCTAssertEqual(ColaFields.hdr(info("M 2019 2160p Blu-ray HEVC HDR Vivid")), "HDR Vivid")
        // 「Encoding settings」里那长串常带 hdr 字样，剔掉之后 BT.709 就是 SDR
        let sdr = "Video\nFormat : AVC\nColor primaries : BT.709\n"
            + "Encoding settings : cabac=1 / deblock=1:0:0 / hdr=0"
        XCTAssertEqual(ColaFields.hdr(info("M 2019 1080p Blu-ray AVC", mediainfo: sdr)), "SDR")
        XCTAssertNil(ColaFields.hdr(info("M 2019 1080p Blu-ray AVC")))
    }

    // MARK: - 音轨 / 字幕 / 制作组

    func testAudioTracks() {
        XCTAssertEqual(ColaFields.audioTracks(info("M 2019 Blu-ray AVC DTS-HD MA 5.1-G")), ["DTS-HD MA 5.1"])
        XCTAssertEqual(ColaFields.audioTracks(info("M 2019 Blu-ray AVC TrueHD Atmos 7.1-G")), ["TrueHD 7.1 Atmos"])
        XCTAssertEqual(ColaFields.audioTracks(info("M 2019 WEB-DL HEVC E-AC-3 5.1-G")), ["DDP 5.1"])
        XCTAssertEqual(ColaFields.audioTracks(info("M 2019 Blu-ray AVC LPCM 2.0-G")), ["LPCM 2.0"])
        // 「没有就不选」：认不出音轨时留空，别像暮雪阁那次硬填一个 APE
        XCTAssertTrue(ColaFields.audioTracks(info("M 2019 1080p WEB-DL H.264-G")).isEmpty)
    }

    func testSubtitleLanguages() {
        let zh = info("M 2019 Blu-ray AVC", descr: "字幕来自字幕库：xxx", tags: ["中字"])
        XCTAssertEqual(ColaFields.subtitleLanguages(zh), ["zh"])
        let both = info("M 2019 Blu-ray AVC CHS/ENG", descr: "字幕：中英双字")
        XCTAssertTrue(ColaFields.subtitleLanguages(both).contains("zh"))
        XCTAssertTrue(ColaFields.subtitleLanguages(both).contains("en"))
        XCTAssertTrue(ColaFields.subtitleLanguages(info("M 2019 Blu-ray AVC", tags: ["英字"])).contains("en"))
        XCTAssertTrue(ColaFields.subtitleLanguages(info("M 2019 Blu-ray AVC", descr: "日文字幕")).contains("ja"))
        XCTAssertTrue(ColaFields.subtitleLanguages(info("M 2019 Blu-ray AVC")).isEmpty)
    }

    func testReleaseGroup() {
        XCTAssertEqual(ColaFields.releaseGroup(info("M 2019 1080p Blu-ray AVC LPCM 2.0-LuckAni")), "LuckAni")
        XCTAssertEqual(ColaFields.releaseGroup(info("M 2019 1080p Blu-ray AVC LPCM 2.0-LuckAni.mkv")), "LuckAni")
        // 最后一段是质量词就不是制作组
        XCTAssertNil(ColaFields.releaseGroup(info("M 2019 1080p Blu-ray AVC DTS-HD MA 5.1-1080p")))
    }

    func testTitleRewriteFollowsGlobalRule() {
        // 全站规则：主标题同时带 Blu-ray 与 Remux 时改写为 BluRay（青蛙 / 春天 都这么要求）
        let dotted = ColaFields.title(from: info("Higurashi.no.Naku.Koro.ni.Rei.S01.2009.1080p.Blu-ray.Remux.AVC.LPCM.2.0-LuckAni"))
        XCTAssertTrue(dotted.contains("1080p.BluRay.Remux"), dotted)
        XCTAssertFalse(dotted.lowercased().contains("blu-ray"), dotted)
        // 没有 Remux 段就不动
        let plain = ColaFields.title(from: info("Some Movie 2019 1080p Blu-ray AVC LPCM 2.0-G"))
        XCTAssertTrue(plain.contains("Blu-ray"), plain)
    }

    // MARK: - 发布范围

    func testReleaseScopeAnime() {
        let series = ColaFields.releaseScope(info("Suzumiya Haruhi S01E01 2006 1080p Blu-ray", kind: .anime))
        XCTAssertEqual(series?["category"] as? String, "anime")
        XCTAssertEqual(series?["anime_type"] as? String, "tv")
        XCTAssertEqual(series?["scope"] as? String, "single")
        XCTAssertEqual(series?["episodes"] as? String, "01")

        let movie = ColaFields.releaseScope(info("Gintama Movie 2 2013 1080p Blu-ray", kind: .anime))
        XCTAssertEqual(movie?["anime_type"] as? String, "movie")
        XCTAssertTrue(movie?["season"] is NSNull, "动画电影不该有季")
        XCTAssertTrue(movie?["episodes"] is NSNull, "动画电影不该有集数")

        let whole = ColaFields.releaseScope(info("Some Anime 全24话 1080p Blu-ray", kind: .anime))
        XCTAssertEqual(whole?["scope"] as? String, "complete")

        // 电影 / 其他：站点不问，就不塞
        XCTAssertNil(ColaFields.releaseScope(info("Some Movie 2019 1080p Blu-ray", kind: .movie)))

        let tv = ColaFields.releaseScope(info("The Season S02E08 1080p WEB-DL", kind: .series))
        XCTAssertEqual(tv?["category"] as? String, "tv")
        XCTAssertEqual(tv?["season"] as? String, "02")
    }

    // MARK: - metadata 载荷

    func testMetadataPayload() {
        let i = info("Gintama Movie 2 2013 1080p JPN Blu-ray AVC LPCM 5.1-U2娘", kind: .anime,
                     descr: "<div>◎简　　介　　银时一行人的故事。</div>",
                     mediainfo: "Video\nFormat : AVC\nHeight : 1 080 pixels",
                     tags: ["中字"], douban: "https://movie.douban.com/subject/25734338/",
                     imdb: "tt2374144", region: "日本", size: 8_000_000_000)
        let meta = ColaFields.metadata(info: i, site: site(), mediaID: "rc123",
                                       expectedRevision: 3, screenshots: ["https://x/1.jpg"])
        XCTAssertEqual(meta["expected_revision"] as? Int, 3)
        XCTAssertEqual(meta["media_id"] as? String, "rc123")
        XCTAssertEqual(meta["source"] as? String, "DIY原盘")
        XCTAssertEqual(meta["resolution"] as? String, "1080p")
        XCTAssertEqual(meta["video_codec"] as? String, "AVC / H.264")
        XCTAssertEqual(meta["audio"] as? [String], ["LPCM 5.1"])
        XCTAssertEqual(meta["subtitles"] as? [String], ["zh"])
        XCTAssertEqual(meta["release_group"] as? String, "U2娘")
        XCTAssertEqual(meta["screenshots"] as? [String], ["https://x/1.jpg"])
        // 官方标签只跟源站是不是官种；这条不是官种
        XCTAssertEqual(meta["official"] as? Bool, false)
        // 站点的 spec 是 additionalProperties:false：多塞一个没配的键就会被 422 打回
        let allowed = ["expected_revision", "media_id", "resolution", "source", "video_codec",
                       "hdr", "audio", "subtitles", "description", "media_info", "release_scope",
                       "release_seasons", "release_name", "subtitle", "release_group",
                       "screenshots", "anonymous", "site_expected_revision", "official"]
        for k in meta.keys where !allowed.contains(k) {
            XCTFail("可乐 metadata 不认这个键：\(k)")
        }
        let desc = meta["description"] as? String ?? ""
        XCTAssertTrue(desc.hasPrefix("[quote]"), desc)
        XCTAssertTrue(desc.contains("转载自LuckPT"), desc)
    }

    func testMetadataKeepsSourceQuoteAboveProductionQuote() {
        // 织梦的审核规则：来源引用要和制作引用并成同一个引用块，来源写在第一行
        let i = info("Gintama 2013 1080p Blu-ray", kind: .movie,
                     descr: "<blockquote>原盘来自：Gintama Blu-ray-U2娘@Share<br />字幕来自字幕库：jsum@U2</blockquote>"
                         + "<div>◎简　　介　　正文。</div>")
        let meta = ColaFields.metadata(info: i, site: site(), mediaID: "rc9",
                                       expectedRevision: 1, screenshots: [])
        let desc = meta["description"] as? String ?? ""
        let firstQuote = desc.range(of: "[/quote]")?.lowerBound ?? desc.endIndex
        let head = String(desc[..<firstQuote])
        XCTAssertTrue(head.contains("转载自LuckPT"), "来源要在第一个引用块里：\(desc)")
        XCTAssertTrue(head.contains("原盘来自"), "制作引用要跟来源并成一块：\(desc)")
        XCTAssertEqual(desc.components(separatedBy: "[quote]").count - 1, 1, "不该出现两个引用块")
    }

    func testScreenshotsExcludePoster() {
        let html = """
        <div><img src="https://img2.pixhost.to/images/5566/692556572_ptgen_poster_fyc41z.jpg"></div>
        <div>◎简　　介　　正文</div>
        <div><img src="https://img2.pixhost.to/images/5566/shot_a.jpg"><br>
        <img src="https://img2.pixhost.to/images/5566/shot_b.jpg"></div>
        """
        let shots = ColaFields.screenshots(from: info("M 2019 1080p Blu-ray", descr: html),
                                           base: "https://www.colapt.com/")
        XCTAssertEqual(shots.count, 2, "只该留简介末尾的真截图：\(shots)")
        XCTAssertFalse(shots.contains { $0.contains("poster") })
    }

    // MARK: - 作品关联与 ID 归一

    func testMediaReferenceAndIDs() {
        XCTAssertEqual(ColaFields.doubanID("https://movie.douban.com/subject/25734338/"), "25734338")
        XCTAssertEqual(ColaFields.doubanID("25734338"), "25734338")
        XCTAssertNil(ColaFields.doubanID(""))
        XCTAssertEqual(ColaFields.imdbID("https://www.imdb.com/title/tt2374144/"), "tt2374144")
        // ensure 接口的 imdb_id 只收 7~8 位
        XCTAssertEqual(ColaFields.ensureableIMDB("tt2374144"), "tt2374144")
        XCTAssertNil(ColaFields.ensureableIMDB("tt123456789012"))
        XCTAssertTrue(ColaFields.isMediaReference("rc123"))
        XCTAssertTrue(ColaFields.isMediaReference("tt2374144"))
        XCTAssertTrue(ColaFields.isMediaReference("https://movie.douban.com/subject/25734338/"))
        XCTAssertFalse(ColaFields.isMediaReference("<media_id>"))
        XCTAssertFalse(ColaFields.isMediaReference("12345"))
        XCTAssertEqual(ColaFields.tmdbRef("https://www.themoviedb.org/movie/123456"),
                       "https://www.themoviedb.org/movie/123456")
        XCTAssertNil(ColaFields.tmdbRef("https://tmdb.example.com/movie/1"))
    }

    func testSameSizeAndNormalize() {
        XCTAssertEqual(ColaFields.normalize("A.B_C-D 1080p"), "abcd1080p")
        XCTAssertTrue(ColaFields.sameSize(1_000_000_000, 1_000_000_500))
        XCTAssertFalse(ColaFields.sameSize(2_000_000_000, 1_000_000_000))
        // 源站没给大小时不因大小否掉重复
        XCTAssertTrue(ColaFields.sameSize(9, nil))
    }

    func testNewMediaNeedsAnID() {
        let noIDs = ColaFields.newMedia(info: info("M 2019 1080p Blu-ray", kind: .movie), descr: "简介")
        XCTAssertNil(noIDs, "豆瓣 / IMDb / TMDB 都没有，站点不会收，直接交给上层报错")
        let ok = ColaFields.newMedia(info: info("M 2019 1080p Blu-ray", kind: .movie,
                                               douban: "25734338"), descr: "一段够长的简介文字")
        XCTAssertEqual(ok?["category"] as? String, "movie")
        XCTAssertEqual(ok?["douban_id"] as? String, "25734338")
        XCTAssertEqual(ok?["synopsis"] as? String, "一段够长的简介文字")
    }

    // MARK: - 凭据分流（Key 只有 MoviePilot 兼容面时，发种要能退回 cookie）

    private func colaAdapter(key: String? = nil, cookie: String? = nil) -> ColaAdapter {
        var s = site()
        s.apiKey = key
        let jar = CookieStore()
        if let cookie { jar.importRawString(host: "www.colapt.com", cookie) }
        return ColaAdapter(site: SiteRegistry.effectiveSite(s),
                           client: HTTPClient(cookies: jar, userAgent: "BoxSendTest"))
    }

    /// 站点对「只有兼容面的 Key」和「Key 坏了」都回 403，靠 error.code 分辨
    func testKeyRejectionVsCookieRejection() {
        func resp(_ code: String) -> HTTPClient.Response {
            HTTPClient.Response(status: 403,
                                data: Data("{\"error\":{\"code\":\"\(code)\"}}".utf8),
                                headers: [:], finalURL: "https://www.colapt.com/api/v1/torrents")
        }
        XCTAssertTrue(ColaAdapter.isKeyRejection(resp("api_key_scope_denied")),
                      "权限不够是 Key 这一侧的问题，要能触发退回 cookie")
        XCTAssertTrue(ColaAdapter.isKeyRejection(resp("api_key_invalid")))
        XCTAssertFalse(ColaAdapter.isKeyRejection(resp("authentication_required")),
                       "那是 cookie 失效，换 Key 没用")
        XCTAssertFalse(ColaAdapter.isKeyRejection(
            HTTPClient.Response(status: 403, data: Data("not json".utf8), headers: [:], finalURL: "")))
    }

    func testCredentialChoice() {
        // 没填 Key：走 cookie 面（Origin + CSRF）
        XCTAssertFalse(colaAdapter(cookie: "sid=1").usesAutomation)
        // 填了 Key、本地没 cookie：仍按 Key 试，报错才能指到「Key 缺 torrent.upload」
        let onlyKey = colaAdapter(key: "rcapi_abc")
        onlyKey.cachedKeyCanUpload = false
        XCTAssertTrue(onlyKey.usesAutomation, "没有 cookie 兜底时别偷偷改道，报错要说清是 Key 的权限问题")
        // 填了 Key、探针说没发种权限、且有 cookie：改走 cookie（用户那把只有 mtorrent.compat 的情形）
        let withCookie = colaAdapter(key: "rcapi_abc", cookie: "sid=1")
        withCookie.cachedKeyCanUpload = false
        XCTAssertFalse(withCookie.usesAutomation, "兼容面 Key 开不了发种那扇门，有 cookie 就走 cookie")
        // 探针过了就用 Key
        withCookie.cachedKeyCanUpload = true
        XCTAssertTrue(withCookie.usesAutomation)
        XCTAssertTrue(withCookie.hasCookie)
        XCTAssertFalse(colaAdapter().hasCookie)
    }

    // MARK: - 注册与凭据

    func testSiteRegistrationAndCredentials() {
        let cola = SiteRegistry.prioritySites.first { $0.id == "cola" }
        XCTAssertNotNil(cola)
        XCTAssertEqual(cola?.name, "可乐")
        XCTAssertEqual(cola?.url, "https://www.colapt.com/")
        XCTAssertEqual(cola?.framework, SiteFramework.cola)
        let es = SiteRegistry.effectiveSite(cola!)
        XCTAssertEqual(es.overrides?.apiKeyOptional, true, "可乐两种凭据都收，界面要给出 API Key 入口")
        XCTAssertNil(es.overrides?.usesAPIKey, "别把可乐标成 key-only 站：cookie 同步照样有用")
        XCTAssertTrue(AppService.supportsAPIKey(cola!), "supportsAPIKey 决定界面给不给 Key 输入")
        XCTAssertTrue(AppService.optionalAPIKey(cola!), "可乐是「cookie 与 Key 都收」，状态行要说「可转种」")
        XCTAssertFalse(AppService.usesAPIKey(cola!), "可乐不是只认 Key 的站")
        // 适配器按框架路由到 ColaAdapter
        let a = SiteRegistry.adapter(for: cola!, client: HTTPClient(cookies: CookieStore(),
                                                                    userAgent: "BoxSendTest"))
        XCTAssertTrue(a is ColaAdapter)
    }

    // MARK: - 状态行短说明

    func testStatusBrief() {
        // Key 没权限但 cookie 能用：卡片要说「走 cookie」，而不是含糊的一句「可转种」
        XCTAssertEqual(CookieCheck.brief(ok: true,
            message: "按 cookie 校验通过（nan）；Key 只有 MoviePilot 兼容面（mtorrent.compat）——转种走 cookie"),
            "（走 cookie）")
        XCTAssertEqual(CookieCheck.brief(ok: true, message: "API Key 有效（可发种）"), "（走 Key）")
        XCTAssertEqual(CookieCheck.brief(ok: true, message: "已登录"), "", "普通 cookie 站不加尾巴")
        // 只有兼容面 Key、又没 cookie：短说明要点出缺的是发种权限，不是「凭据失效」那种含混话
        XCTAssertEqual(CookieCheck.brief(ok: false,
            message: "Key 只有 MoviePilot 兼容面（mtorrent.compat），发种要 torrent.upload；本地也没有 cookie"),
            "（Key 缺发种权限）")
        XCTAssertEqual(CookieCheck.brief(ok: false, message: "API Key 已失效或被撤销；本地也没有 cookie"), "（Key 失效）")
        XCTAssertEqual(CookieCheck.brief(ok: false, message: "Key 校验没通（network_error）；本地也没有 cookie"), "（Key 没通过）")
        XCTAssertEqual(CookieCheck.brief(ok: false, message: "cookie 已失效，请重新登录站点并触发备份"), "（cookie 失效）")
        XCTAssertEqual(CookieCheck.brief(ok: false, message: "本地无 cookie"), "（本地无 cookie）")
        XCTAssertEqual(CookieCheck.brief(ok: false, message: "站点未响应（12s 超时），未确认登录态"), "（站点没响应）")
    }
}
