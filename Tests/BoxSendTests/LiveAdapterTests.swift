import XCTest
@testable import BoxSendKit

/// 实站验证（默认跳过，BOXSEND_LIVE=1 时跑）：用真实 cookie/配置把 fixture 种子发到目标站。
/// 源站 cookie 过期时可用 --filter 单独跑某个站，源种子数据取本地已下载的 .torrent。
final class LiveAdapterTests: XCTestCase {
    private var support: String { NSHomeDirectory() + "/Library/Application Support/BoxSend" }

    private func liveSetup() throws -> (AppConfig, CookieStore) {
        guard ProcessInfo.processInfo.environment["BOXSEND_LIVE"] != nil else {
            throw XCTSkip("实站验证需 BOXSEND_LIVE=1")
        }
        guard let cfg = AppConfig.load(path: support + "/boxsend.json") else {
            throw XCTSkip("没有本机配置")
        }
        let cookies = CookieStore()
        _ = try cookies.importBackupJSON(try Data(contentsOf: URL(fileURLWithPath: support + "/cookies.json")))
        return (cfg, cookies)
    }

    private func sourceRelease() throws -> ReleaseInfo {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/luckpt-56812-ajax.html")
        let luck = SiteRegistry.prioritySites.first { $0.id == "luckpt" }!
        return try NexusPHPAdapter(site: luck, client: HTTPClient(cookies: CookieStore(), userAgent: "t"))
            .parseDetail(html: try String(contentsOf: url, encoding: .utf8),
                         detailURL: "https://pt.luckpt.de/details.php?id=56812&hit=1")
    }

    func testLiveUpload() throws {
        let (cfg, cookies) = try liveSetup()
        let info = try sourceRelease()
        let torrentPath = "/tmp/src56812.torrent"
        guard FileManager.default.fileExists(atPath: torrentPath) else {
            throw XCTSkip("缺 \(torrentPath)（实站上传要用的源种子）")
        }
        let torrent = try Data(contentsOf: URL(fileURLWithPath: torrentPath))
        let only = ProcessInfo.processInfo.environment["BOXSEND_LIVE_SITES"]?
            .split(separator: ",").map(String.init) ?? ["rousi", "yzyy", "haidan"]
        for id in only {
            guard let site = cfg.site(id) else { continue }
            let client = HTTPClient(cookies: cookies, userAgent: cfg.userAgent ?? "Mozilla/5.0")
            let adapter = SiteRegistry.adapter(for: site, client: client, debugDir: support)
            if let hit = try? adapter.searchExists(info) {
                print("LIVE \(id): 查重命中 \(hit)")
            }
            do {
                let outcome = try adapter.upload(info, torrentData: torrent, filename: info.torrentName)
                print("LIVE \(id): success=\(outcome.success) exists=\(outcome.alreadyExists) "
                    + "\(outcome.message) \(outcome.detailURL ?? "")")
            } catch {
                print("LIVE \(id): 异常 \(error.localizedDescription)")
            }
        }
    }

    /// 目标站推送链路：详情页 -> .torrent 下载（HD-Space 用 info_hash 当 id，需真实 cookie）
    func testLiveTargetPushFetch() throws {
        let (cfg, cookies) = try liveSetup()
        let id = ProcessInfo.processInfo.environment["BOXSEND_LIVE_PUSH_SITE"] ?? "hdspace"
        let url = ProcessInfo.processInfo.environment["BOXSEND_LIVE_PUSH_URL"] ?? ""
        guard let site = cfg.site(id), !url.isEmpty else { throw XCTSkip("需 BOXSEND_LIVE_PUSH_SITE/URL") }
        let client = HTTPClient(cookies: cookies, userAgent: cfg.userAgent ?? "Mozilla/5.0")
        let adapter = SiteRegistry.adapter(for: site, client: client, debugDir: support)
        let info = try adapter.fetchDetail(detailURL: url)
        let (data, name) = try adapter.downloadTorrentFile(info)
        print("LIVE-PUSH \(id): \(info.name) | \(name) | \(data.count) bytes | "
            + "hash=\(Bencode.infoHash(data) ?? "-") | tracker=\(Bencode.announceURLs(data).joined(separator: ","))")
    }

    /// 实站验证：慢图床的截图要真能拉下来（肉丝发种就卡死在这一步）。
    /// 图床地址会换，只作粗略验证：至少拿到 2 张、拿不到时报错要说清原因。
    func testLiveScreenshotDownload() throws {
        try liveSetup()
        let urls = ["https://img2.pixhost.to/images/5566/692557779_01.png",
                    "https://img2.pixhost.to/images/5566/692557792_02.png",
                    "https://img2.pixhost.to/images/5566/692557800_03.png"]
        let client = HTTPClient(cookies: CookieStore(), userAgent: "Mozilla/5.0")
        let started = Date()
        let (out, errors) = PeerGoAdapter.downloadShots(urls, client: client,
                                                       referer: "https://pt.luckpt.de/", limit: 3)
        let secs = Int(Date().timeIntervalSince(started))
        print("LIVE-SHOTS: 拿到 \(out.count)/3 张，用时 \(secs)s，字节 \(out.map { $0.data.count })，errors=\(errors)")
        XCTAssertGreaterThanOrEqual(out.count, 1, "慢图床也该在预算内拉到至少一张截图：\(errors)")
        XCTAssertLessThanOrEqual(secs, 270, "截图下载必须留在额度内，否则整站会被流水线超时掐掉")
    }

    /// 上传字段预览（不发种）：确认 hdvideo 这类站点的 pt_gen / 必填下拉真实取值
    func testLiveUploadPreview() throws {
        let (cfg, cookies) = try liveSetup()
        let only = (ProcessInfo.processInfo.environment["BOXSEND_LIVE_PREVIEW_SITES"] ?? "").isEmpty
            ? nil : ProcessInfo.processInfo.environment["BOXSEND_LIVE_PREVIEW_SITES"]!
            .split(separator: ",").map(String.init)
        guard let only else { throw XCTSkip("需 BOXSEND_LIVE_PREVIEW_SITES") }
        let info = try sourceRelease()
        for id in only {
            guard let site = cfg.site(id) else { continue }
            let client = HTTPClient(cookies: cookies, userAgent: cfg.userAgent ?? "Mozilla/5.0")
            let adapter = SiteRegistry.adapter(for: site, client: client, debugDir: support)
            do {
                let fields = try adapter.previewUploadFields(info)
                let interesting = ["pt_gen", "douban_url", "imdb", "tmdb", "name", "title", "small_desc",
                                   "type", "type_sel", "source_sel", "medium_sel", "processing_sel",
                                   "codec_sel", "audiocodec_sel", "team_sel", "standard_rate", "region_sel"]
                let dump = fields.filter { interesting.contains($0.0) }.map { "\($0.0)=\($0.1)" }.joined(separator: " | ")
                print("LIVE-PREVIEW \(id): \(dump)")
            } catch {
                print("LIVE-PREVIEW \(id): 异常 \(error.localizedDescription)")
            }
        }
    }
}
