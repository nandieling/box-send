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
            return verify(hash: hash, upLimit: upLimit, already: true)
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
        return verify(hash: hash, upLimit: upLimit, already: false)
    }

    /// 添加后回查：确认种子存在、限速是否生效（限速端点被隧道挡住时给用户可见提示）
    private func verify(hash: String?, upLimit: Int64, already: Bool) -> AddTorrentResult {
        guard let hash, !already else {
            return AddTorrentResult(id: hash ?? "", note: already ? "已存在于下载器" : "")
        }
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
        return AddTorrentResult(id: hash, note: notes.joined(separator: "；"))
    }
}
