import Foundation

/// 从 CookieCloud（cookiecloud.co，PT 站 cookie 云端备份）拉取全部 cookie。
///
/// API: GET {baseURL}/api/cookies
///      请求头 Authorization: Bearer <token>
/// 响应: [{ "name": 站名, "url": 站点地址, "cookies": "k=v; k=v", ... }, ...]
/// （兼容 {"data": [...]} 等对象包裹的数组）
public final class CookieCloudSync {
    let config: CookieCloudConfig
    let client: HTTPClient

    public init(config: CookieCloudConfig, client: HTTPClient) {
        self.config = config
        self.client = client
    }

    public struct PullResult {
        public var imported: Int    // 成功导入的站点数
        public var skipped: Int     // 无法识别站点（无 url 且站名不匹配）而跳过的条数
    }

    /// 解析响应（纯函数，便于单测）
    public static func parseEntries(_ data: Data) throws -> [(name: String, url: String, cookies: String)] {
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BoxSendError.badInput("CookieCloud 响应不是 JSON")
        }
        let arr: [Any]
        if let a = obj as? [Any] {
            arr = a
        } else if let o = obj as? [String: Any] {
            arr = (o["data"] as? [Any]) ?? (o["cookies"] as? [Any]) ?? (o["items"] as? [Any]) ?? []
        } else {
            throw BoxSendError.badInput("CookieCloud 响应结构异常（未找到 cookie 列表）")
        }
        return arr.compactMap { item in
            guard let it = item as? [String: Any],
                  let cookies = it["cookies"] as? String,
                  !cookies.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let name = (it["name"] as? String) ?? ""
            let url = (it["url"] as? String) ?? (it["site"] as? String) ?? ""
            return (name, url, cookies)
        }
    }

    /// 从条目确定归属 host：优先 url 的 host；否则按站名/站 id 匹配已知站点
    public static func hostFor(name: String, url: String,
                               knownSites: [(id: String, name: String, host: String)]) -> String? {
        if let u = URL(string: url), let h = u.host, !h.isEmpty { return h }
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty, let m = knownSites.first(where: { $0.name == n || $0.id == n }) {
            return m.host
        }
        return nil
    }

    @discardableResult
    public func pull(into store: CookieStore, knownSites: [(id: String, name: String, host: String)] = []) throws -> PullResult {
        let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
        let urlStr = base + "/api/cookies"
        let resp: HTTPClient.Response
        do {
            resp = try client.get(urlStr, extraHeaders: ["Authorization": "Bearer \(config.token)"])
        } catch let e as BoxSendError {
            throw e
        }
        guard (200..<300).contains(resp.status) else {
            throw BoxSendError.http(status: resp.status, url: urlStr,
                                    body: String(data: resp.data.prefix(300), encoding: .utf8) ?? "")
        }
        let entries = try Self.parseEntries(resp.data)
        guard !entries.isEmpty else {
            throw BoxSendError.badInput("CookieCloud 返回 0 条 cookie（请检查 API Token 与云端备份）")
        }
        var imported = 0
        var skipped = 0
        for e in entries {
            guard let host = Self.hostFor(name: e.name, url: e.url, knownSites: knownSites) else {
                skipped += 1
                continue
            }
            store.importRawString(host: host, e.cookies)
            imported += 1
        }
        guard imported > 0 else {
            throw BoxSendError.badInput("CookieCloud 的条目无法匹配到已知站点（请检查站点地址）")
        }
        return PullResult(imported: imported, skipped: skipped)
    }
}
