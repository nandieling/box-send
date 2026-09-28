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
                    skipChecking: Bool, upLimit: Int64) throws -> String {
        try login()

        let fields: [String: String] = [
            "savepath": savePath ?? "",
            "category": category ?? "",
            "skip_checking": skipChecking ? "true" : "false",
            "upLimit": String(upLimit),
        ]
        let resp = try client.postMultipart(
            "\(baseURL)/api/v2/torrents/add",
            fields: fields,
            files: [(name: "torrents", filename: filename, data: data, mime: "application/x-bittorrent")],
            referer: baseURL
        )
        let body = String(data: resp.data, encoding: .utf8) ?? ""
        if resp.status == 409 {
            // 5.2+: 未新增任何种子时返回 409 Conflict（典型场景：种子已存在于下载器）
            // 视为已添加，保证重复执行幂等
            return filename
        }
        guard resp.status == 200 else {
            throw BoxSendError.http(status: resp.status, url: "\(baseURL)/api/v2/torrents/add", body: body)
        }
        // 5.2+ 成功时返回 JSON（success_count 等），旧版返回 "Ok."
        if resp.status == 200 && body != "Ok." {
            if let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
               let sc = obj["success_count"] as? Int, sc == 0,
               let fc = obj["failure_count"] as? Int, fc > 0 {
                throw BoxSendError.http(status: 200, url: "\(baseURL)/api/v2/torrents/add", body: body)
            }
        }
        return filename
    }
}
