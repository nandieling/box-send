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

    func addTorrent(data: Data, filename: String,
                    savePath: String?, category: String?,
                    skipChecking: Bool, upLimit: Int64) throws -> String {
        let loginResp = try client.postForm("\(baseURL)/api/v2/auth/login",
                                            fields: ["username": username, "password": password])
        let loginBody = String(data: loginResp.data, encoding: .utf8) ?? ""
        // qBittorrent 5.2+: 客户端已有活动会话时返回 204（无内容），同样视为登录成功
        guard (loginResp.status == 200 && loginBody == "Ok.") || loginResp.status == 204 else {
            throw BoxSendError.badInput("qBittorrent 登录失败 (HTTP \(loginResp.status) \(loginBody.prefix(80)))，检查 url/账号/密码")
        }
        // SID 已通过 Set-Cookie 自动存入 CookieStore

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
        guard resp.status == 200, body == "Ok." else {
            throw BoxSendError.http(status: resp.status, url: "\(baseURL)/api/v2/torrents/add", body: body)
        }
        return filename
    }
}
