import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// qBittorrent Web API (v2)。
/// 需求 3: add 时携带 upLimit（bytes/s，0 = 不限速），对应 auto_feed 的 siteUpLimits。
final class QBittorrent: Downloader {
    let client: HTTPClient
    let baseURL: String
    let username: String
    let password: String

    init(client: HTTPClient, baseURL: String, username: String, password: String) {
        self.client = client
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.username = username
        self.password = password
    }

    private func login() throws {
        let resp = try client.postForm("\(baseURL)/api/v2/auth/login",
                                       fields: ["username": username, "password": password])
        let body = String(data: resp.data, encoding: .utf8) ?? ""
        // qBittorrent 5.2+: 客户端已有活动会话时返回 204（无内容），同样视为登录成功
        guard (resp.status == 200 && body == "Ok.") || resp.status == 204 else {
            throw BoxSendError.badInput("qBittorrent 登录失败 (HTTP \(resp.status) \(body.prefix(80)))，检查 url/账号/密码")
        }
        // SID 已通过 Set-Cookie 自动存入 CookieStore
    }

    func testConnection() throws -> String {
        try login()
        let resp = try client.get("\(baseURL)/api/v2/app/version")
        guard resp.status == 200 else {
            throw BoxSendError.http(status: resp.status, url: "\(baseURL)/api/v2/app/version",
                                    body: String(data: resp.data, encoding: .utf8) ?? "")
        }
        var version = "未知版本"
        if let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
           let v = obj["version"] as? String {
            version = v
        }
        return "qBittorrent \(version)，登录成功"
    }

    func addTorrent(data: Data, filename: String,
                    savePath: String?, category: String?,
                    skipChecking: Bool, upLimit: Int64) throws -> AddTorrentResult {
        try login()

        let fields = [
            HTTPClient.MultipartField("savepath", savePath ?? ""),
            HTTPClient.MultipartField("category", category ?? ""),
            HTTPClient.MultipartField("skip_checking", skipChecking ? "true" : "false"),
            HTTPClient.MultipartField("upLimit", String(upLimit)),
            // 4.3+：显式启动，避免下载器默认"添加后暂停"导致推送了却不跑
            HTTPClient.MultipartField("started", "true"),
        ]
        let resp = try client.postMultipart(
            "\(baseURL)/api/v2/torrents/add",
            fields: fields,
            files: [(name: "torrents", filename: filename, data: data, mime: "application/x-bittorrent")],
            referer: baseURL
        )
        let body = String(data: resp.data, encoding: .utf8) ?? ""
        let hash = Bencode.infoHash(data)

        if resp.status == 409 {
            // 5.2+: 未新增任何种子时返回 409 Conflict（典型场景：种子已存在于下载器）
            // 视为已添加，保证重复执行幂等；明确提示"已存在"
            return verify(hash: hash, upLimit: upLimit, already: true, torrentData: data)
        }
        guard resp.status == 200 else {
            throw BoxSendError.http(status: resp.status, url: "\(baseURL)/api/v2/torrents/add", body: body)
        }
        // 5.2+ 成功时返回 JSON（success_count 等），旧版返回 "Ok."
        if body != "Ok." {
            if let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
               let sc = obj["success_count"] as? Int, sc == 0,
               let fc = obj["failure_count"] as? Int, fc > 0 {
                throw BoxSendError.http(status: 200, url: "\(baseURL)/api/v2/torrents/add", body: body)
            }
        }
        return verify(hash: hash, upLimit: upLimit, already: false, torrentData: data)
    }

    /// 添加后回查：确认种子存在、限速是否生效（限速端点被隧道挡住时给用户可见提示）
    private func verify(hash: String?, upLimit: Int64, already: Bool,
                        torrentData: Data) -> AddTorrentResult {
        if already {
            guard let hash else { return AddTorrentResult(id: "", note: "已存在于下载器") }
            return AddTorrentResult(id: hash, note: attachSiteTracker(hash: hash, torrentData: torrentData))
        }
        guard let hash else { return AddTorrentResult(id: "", note: "") }
        guard let resp = try? client.get("\(baseURL)/api/v2/torrents/info?hashes=\(hash)"),
              let arr = try? JSONSerialization.jsonObject(with: resp.data) as? [[String: Any]],
              let t = arr.first else {
            return AddTorrentResult(id: hash, note: "")
        }
        var notes: [String] = []
        if let ul = t["up_limit"] as? Int, upLimit > 0, Int64(ul) < upLimit {
            let cur = (ul == -1) ? "跟随全局" : "\(ul) B/s"
            notes.append("限速未生效（当前 \(cur)，请求 \(upLimit) B/s）")
        }
        if let st = t["state"] as? String, st == "missingFiles" {
            notes.append("文件不存在于下载器路径（missingFiles）：在 VPS 上放置对应文件或 qB 里重新定位后才开始上传")
        }
        return AddTorrentResult(id: hash, note: notes.joined(separator: "；"))
    }

    /// 同 hash 的种子已在下载器（跨站转种太常见：很多站不改 info 段，源站和目标站的 .torrent
    /// 算出来是同一个 hash，qB 直接回 409 什么也不加）。这时目标站的 tracker 根本没挂上，
    /// 站内等于没做种——把本站 announce 补进那条种子，推送才算真落地。
    private func attachSiteTracker(hash: String, torrentData: Data) -> String {
        let announce = Bencode.announceURLs(torrentData)
        guard !announce.isEmpty else { return "已存在于下载器（种子文件里没有 tracker，无法补挂）" }
        let hosts = announce.compactMap { URL(string: $0)?.host }.joined(separator: "、")
        guard let existing = trackerURLs(hash: hash) else {
            return "已存在于下载器，本站 tracker（\(hosts)）补挂失败：读不到该种子现有的 tracker"
        }
        // 同一 host 视为同一个 tracker（换 passkey 重推不该重复挂）
        func host(_ url: String) -> String { URL(string: url)?.host?.lowercased() ?? url.lowercased() }
        let missing = announce.filter { a in !existing.contains { host($0) == host(a) } }
        guard !missing.isEmpty else { return "已存在于下载器，本站 tracker 已在种子中，跨种已生效" }
        if let err = patchTrackers(hash: hash, existing: existing, add: missing) {
            return "已存在于下载器，本站 tracker（\(hosts)）补挂失败：\(err)"
        }
        return "已存在于下载器，已补挂本站 tracker（\(hosts)），跨种已生效"
    }

    /// 读现有 tracker 用的参数名：qB 5.x（WebAPI 2.11+）只认 hash，
    /// 用旧的 hashes 会回 400「缺少必需参数：hash」；4.x 用 infohash，两个都试一次
    static let trackerHashParams = ["hash", "infohash"]

    /// 该种子现有的 tracker URL；读不到返回 nil
    func trackerURLs(hash: String) -> [String]? {
        for param in Self.trackerHashParams {
            guard let resp = try? client.get("\(baseURL)/api/v2/torrents/trackers?\(param)=\(hash)",
                                             referer: baseURL),
                  resp.status == 200,
                  let arr = try? JSONSerialization.jsonObject(with: resp.data) as? [[String: Any]] else { continue }
            return arr.compactMap { $0["url"] as? String }
        }
        return nil
    }

    /// tracker 改写接口的参数：hash（qB 5.x）+ hashes（4.x），多出来的那一份会被忽略
    static func trackerPatchFields(hash: String, add: [String]) -> [String: String] {
        ["hash": hash, "hashes": hash, "urls": add.joined(separator: "\n")]
    }

    /// 4.3+ 用 addTrackers（只追加）；老版本只有 setTrackers（整表重写，得把原有的带上）
    private func patchTrackers(hash: String, existing: [String], add: [String]) -> String? {
        do {
            // qB 5.x 要 hash（单个），老版本认 hashes：两个都带上，多出来的参数会被忽略
            let resp = try client.postForm("\(baseURL)/api/v2/torrents/addTrackers",
                                           fields: Self.trackerPatchFields(hash: hash, add: add),
                                           referer: baseURL)
            if resp.status == 200 || resp.status == 204 { return nil }
            guard resp.status == 404 || resp.status == 400 || resp.status == 405 else {
                return "HTTP \(resp.status)"
            }
        } catch {
            return "补挂请求没通（\(error.localizedDescription)）"
        }
        // qB 5.x 已删掉 setTrackers（404），只有 4.x 会走到这里
        let merged = existing + add
        guard let resp = try? client.postForm("\(baseURL)/api/v2/torrents/setTrackers",
                                              fields: Self.trackerPatchFields(hash: hash, add: merged),
                                              referer: baseURL) else {
            return "补挂请求没通"
        }
        return (resp.status == 200 || resp.status == 204) ? nil : "HTTP \(resp.status)"
    }
}
