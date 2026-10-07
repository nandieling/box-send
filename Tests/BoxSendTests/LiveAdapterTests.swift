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
        let torrent = try Data(contentsOf: URL(fileURLWithPath: "/tmp/src56812.torrent"))
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
        print("LIVE-PUSH \(id): \(info.name) | \(name) | \(data.count) bytes | hash=\(Bencode.infoHash(data) ?? "-")")
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
