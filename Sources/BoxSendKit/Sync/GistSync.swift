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

    public struct PullResult {
        public var hosts: [String]
        public var cookieCount: Int
        public var backupTime: String
        public var changed: Bool
    }

    @discardableResult
    public func pull(into store: CookieStore, state: StateStore) throws -> PullResult {
        var req = URLRequest(url: URL(string: "https://api.github.com/gists/\(config.gistID)")!)
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let sem = DispatchSemaphore(value: 0)
        var respData: Data?
        var respStatus = 0
        var respError: Error?
        let task = client.session0.dataTask(with: req) { d, r, e in
            defer { sem.signal() }
            respData = d
            respStatus = (r as? HTTPURLResponse)?.statusCode ?? 0
            respError = e
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 30)
        if let e = respError { throw e }
        guard let raw = respData else { throw BoxSendError.badInput("gist 无响应") }
        guard (200..<300).contains(respStatus) else {
            throw BoxSendError.http(status: respStatus, url: "api.github.com/gists/\(config.gistID)",
                                    body: String(data: raw.prefix(300), encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
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

        let imported = try store.importBackupJSON(decrypted)
        state.setLastGistSync(Date().timeIntervalSince1970)
        let hosts = store.hosts()
        return PullResult(hosts: hosts, cookieCount: imported, backupTime: backupTime,
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
