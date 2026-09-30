import Foundation

/// Cookie 健康检测（尽力而为）：
/// - YemaPT / TNode：走各自 JSON API（未登录返回 401/403 或 success=false，判定准确）
/// - NexusPHP 家族：首页标记探测 + `userdetails.php` 二次确认
/// - 其余：首页探测（跳转登录页 / "未登录"标记 -> 失效；已登录标记 -> 有效；否则可达但未确认）
public enum CookieCheck {
    public struct Result {
        public var siteID: String
        public var ok: Bool
        public var message: String
        public init(siteID: String, ok: Bool, message: String) {
            self.siteID = siteID
            self.ok = ok
            self.message = message
        }
    }

    private static let loginRedirectMarkers = ["login", "signin", "sign_in"]
    private static let loggedInMarkers = ["usercp", "userdetails.php", "bonus.php", "welcome back", "欢迎回来", "我的主页", "用户组"]
    private static let notLoggedInMarkers = ["未登录", "请登录", "尚未登录", "log in to"]

    public static func check(site: SiteConfig, client: HTTPClient) -> Result {
        switch site.framework {
        case .yemapt:
            return checkYemaPT(site, client)
        case .tnode:
            return checkTNode(site, client)
        default:
            return checkGeneric(site, client)
        }
    }

    // MARK: - YemaPT（fetchUploadOptions 需登录）

    private static func checkYemaPT(_ site: SiteConfig, _ client: HTTPClient) -> Result {
        let url = site.url + "api/torrent/fetchUploadOptions"
        let resp: HTTPClient.Response
        do {
            resp = try client.get(url, referer: site.url)
        } catch {
            return Result(siteID: site.id, ok: false, message: "网络错误（站点不可达？）: \(error.localizedDescription)")
        }
        if resp.status == 401 || resp.status == 403 {
            return Result(siteID: site.id, ok: false, message: "API \(resp.status)，cookie 已失效")
        }
        guard resp.status == 200 else {
            return Result(siteID: site.id, ok: false, message: "API HTTP \(resp.status)，状态未确认")
        }
        if let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
           obj["success"] as? Bool == true {
            return Result(siteID: site.id, ok: true, message: "已登录（fetchUploadOptions 200）")
        }
        return Result(siteID: site.id, ok: false, message: "API 返回 success=false，cookie 已失效")
    }

    // MARK: - TNode（api/torrent/option 需登录 + csrf）

    private static func checkTNode(_ site: SiteConfig, _ client: HTTPClient) -> Result {
        let adapter = TNodeAdapter(site: site, client: client)
        do {
            _ = try adapter.fetchOptions()
            return Result(siteID: site.id, ok: true, message: "已登录（api/torrent/option 200）")
        } catch BoxSendError.http(let status, _, _) where status == 401 || status == 403 {
            return Result(siteID: site.id, ok: false, message: "API \(status)，cookie 已失效")
        } catch {
            return Result(siteID: site.id, ok: false, message: "检测失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 通用（NexusPHP 家族 + 其它）

    private static func checkGeneric(_ site: SiteConfig, _ client: HTTPClient) -> Result {
        let resp: HTTPClient.Response
        do {
            resp = try client.get(site.url)
        } catch {
            return Result(siteID: site.id, ok: false, message: "网络错误（站点不可达？）: \(error.localizedDescription)")
        }
        guard (200..<300).contains(resp.status) else {
            return Result(siteID: site.id, ok: false, message: "HTTP \(resp.status)")
        }
        let finalURL = resp.finalURL.lowercased()
        if loginRedirectMarkers.contains(where: { finalURL.contains($0) }) {
            return Result(siteID: site.id, ok: false, message: "跳转到登录页，cookie 已失效")
        }
        let body = (String(data: resp.data, encoding: .utf8) ?? "").lowercased()
        if let hit = notLoggedInMarkers.first(where: { body.contains($0) }) {
            return Result(siteID: site.id, ok: false, message: "页面出现「\(hit)」，疑似未登录")
        }
        if let hit = loggedInMarkers.first(where: { body.contains($0) }) {
            return Result(siteID: site.id, ok: true, message: "已登录（命中「\(hit)」）")
        }
        // 首页无法确认登录态时，NexusPHP 家族再探 userdetails.php（仅登录后可达）
        if site.framework == .nexusPHP || site.framework == .haidan {
            if let r2 = try? client.get(site.url + "userdetails.php", referer: site.url),
               (200..<300).contains(r2.status) {
                let f2 = r2.finalURL.lowercased()
                if loginRedirectMarkers.contains(where: { f2.contains($0) }) {
                    return Result(siteID: site.id, ok: false, message: "userdetails 跳转到登录页，cookie 已失效")
                }
                let b2 = (String(data: r2.data, encoding: .utf8) ?? "").lowercased()
                if b2.contains("userdetails.php") || b2.contains("user details")
                    || b2.contains("bonus.php") || b2.contains("用户组") {
                    return Result(siteID: site.id, ok: true, message: "已登录（userdetails 页可达）")
                }
            }
        }
        return Result(siteID: site.id, ok: true, message: "首页可达（HTTP \(resp.status)），未确认登录态")
    }
}
