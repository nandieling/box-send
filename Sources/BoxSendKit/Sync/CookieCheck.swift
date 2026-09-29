import Foundation

/// Cookie 健康检测（尽力而为）：带 cookie 访问站点首页，判断登录态。
/// 规则：跳转登录页 / 页面出现"未登录"标记 -> 失效；出现已登录标记 -> 有效；
/// 其余情况（首页可访问但无法确认）-> 可达但未确认。
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
        return Result(siteID: site.id, ok: true, message: "首页可达（HTTP \(resp.status)），未确认登录态")
    }
}
