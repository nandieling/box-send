import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 从 PT-depiler 的 GitHub Gist 备份拉取 cookie。
///
/// 备份结构（gist 内文件）:
///   _manifest.json  -> { time, encryption, files: { cookies: { name: "cookies.txt" } } }
///   cookies.txt     -> AES-256-CBC 加密（口令 = MD5(备份密码|gistID) 前 16 位 hex）
///   解密后          -> { "host": [chrome.cookies.Cookie] }
public final class GistSync {
    let config: GistSyncConfig
    let client: HTTPClient   // 不带 cookie 的裸客户端（访问 api.github.com）

    public init(config: GistSyncConfig, client: HTTPClient) {
        self.config = config
        self.client = client
    }

    public struct FetchResult {
        public var data: Data          // 解密后的 {host: [cookie...]} JSON
        public var backupTime: String
    }

    public struct PullResult {
        public var hosts: [String]
        public var cookieCount: Int
        public var backupTime: String
        public var changed: Bool
    }

    /// 拉取 gist 并解密（不做导入）；供互补同步在后台线程调用，避免阻塞 UI
    public func fetch() throws -> FetchResult {
        let resp = try client.get("https://api.github.com/gists/\(config.gistID)",
                                  extraHeaders: [
                                      "Authorization": "Bearer \(config.token)",
                                      "Accept": "application/vnd.github+json",
                                      "X-GitHub-Api-Version": "2022-11-28",
                                  ])
        guard (200..<300).contains(resp.status) else {
            throw BoxSendError.http(status: resp.status, url: "api.github.com/gists/\(config.gistID)",
                                    body: String(data: resp.data.prefix(300), encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
              let files = obj["files"] as? [String: [String: Any]] else {
            throw BoxSendError.badInput("gist 响应结构异常")
        }

        let manifestContent = files["_manifest.json"]?["content"] as? String ?? ""
        guard let manifestData = manifestContent.data(using: .utf8),
              let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let fileMap = manifest["files"] as? [String: [String: Any]],
              let cookiesEntry = fileMap["cookies"],
              let cookiesFileName = cookiesEntry["name"] as? String else {
            throw BoxSendError.badInput("manifest 中未找到 cookies 文件（请确认 PT-depiler 备份勾选了 Cookie 字段）")
        }
        let backupTime = manifest["time"].map { ISO8601Time.fromMillis($0 as? Double ?? 0) } ?? "?"

        var fileContent = files[cookiesFileName]?["content"] as? String
        if fileContent == nil || (files[cookiesFileName]?["truncated"] as? Bool ?? false) {
            if let rawURL = files[cookiesFileName]?["raw_url"] as? String,
               let u = URL(string: rawURL) {
                let r2 = try client.get(u.absoluteString)
                fileContent = String(data: r2.data, encoding: .utf8)
            }
        }
        guard let content = fileContent else {
            throw BoxSendError.badInput("找不到 \(cookiesFileName) 内容")
        }

        // 解密：Gist 备份总是加密（口令 = MD5(userKey|gistID) 前 16 位）
        var decrypted: Data
        if cookiesFileName.hasSuffix(".txt") {
            let pass = CryptoJSCompat.gistPassword(userKey: config.encryptionKey, gistID: config.gistID)
            decrypted = try CryptoJSCompat.decryptOpenSSL(base64: content, password: pass)
        } else {
            decrypted = Data(content.utf8)
        }
        return FetchResult(data: decrypted, backupTime: backupTime)
    }

    @discardableResult
    public func pull(into store: CookieStore, state: StateStore) throws -> PullResult {
        let f = try fetch()
        let imported = try store.importBackupJSON(f.data)
        state.setLastGistSync(Date().timeIntervalSince1970)
        let hosts = store.hosts()
        return PullResult(hosts: hosts, cookieCount: imported, backupTime: f.backupTime,
                          changed: true)
    }
}

extension ISO8601Time {
    static func fromMillis(_ ms: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
