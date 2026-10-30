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
        /// 站点没给出可判定的响应（超时 / 5xx / 连不上）：只能记「未确认」，不能据此说 cookie 失效
        public var unconfirmed: Bool
        public init(siteID: String, ok: Bool, message: String, unconfirmed: Bool = false) {
            self.siteID = siteID
            self.ok = ok
            self.message = message
            self.unconfirmed = unconfirmed
        }
    }

    /// 卡片状态行后面那半句短说明。站点卡片宽度有限，长结论只能放悬停提示，
    /// 而 mac 卡片的悬停提示被「点击停用」那句占了，所以关键判据必须能塞进状态行本身。
    /// 文案在核心算，两端只管渲染。
    public static func brief(ok: Bool, message: String) -> String {
        if ok {
            if message.contains("按 cookie 校验通过") { return "（走 cookie）" }
            if message.contains("API Key 有效") { return "（走 Key）" }
            if message.contains("cookie 有效") { return "（cookie）" }
            return ""
        }
        if message.contains("兼容面") { return "（Key 缺发种权限）" }
        if message.contains("API Key 已失效") { return "（Key 失效）" }
        if message.contains("Key 校验没通") { return "（Key 没通过）" }
        if message.contains("cookie 已失效") { return "（cookie 失效）" }
        if message.contains("本地无 cookie") { return "（本地无 cookie）" }
        if message.contains("本地也没有") { return "（无可用凭据）" }
        if message.contains("网络错误") || message.contains("未响应") { return "（站点没响应）" }
        return ""
    }

    public static func brief(_ result: Result) -> String {
        brief(ok: result.ok, message: result.message)
    }

    /// 检测时间预算：截止时间 + 上限秒数（回显用）
    public struct Budget {
        public let until: Date
        public let seconds: TimeInterval
        public var expired: Bool { Date() >= until }
        public init(until: Date, seconds: TimeInterval) {
            self.until = until
            self.seconds = seconds
        }
    }

    static func timeoutResult(_ site: SiteConfig, _ budget: Budget?) -> Result {
        Result(siteID: site.id, ok: false,
               message: "站点未响应（\(Int(budget?.seconds ?? timeout))s 超时），未确认登录态", unconfirmed: true)
    }

    /// Cloudflare 522/524 与源站抖动很常见（观众/龙等站实测会偶发），预算内重试一次
    private static func retryPause(_ budget: Budget?) -> Bool {
        guard budget?.expired == false else { return false }
        Thread.sleep(forTimeInterval: 1.5)
        return true
    }

    private static let loginRedirectMarkers = ["login", "signin", "sign_in"]
    private static let loggedInMarkers = ["usercp", "userdetails.php", "bonus.php", "welcome back", "欢迎回来", "我的主页", "用户组"]
    private static let notLoggedInMarkers = ["未登录", "请登录", "尚未登录", "log in to"]

    /// 单站检测时长上限（秒）。慢站/挂起的站只影响自己这一格，不再拖住整批检测。
    /// 可用环境变量 BOXSEND_CHECK_TIMEOUT 临时调整（秒）。
    public static var timeout: TimeInterval = {
        if let v = ProcessInfo.processInfo.environment["BOXSEND_CHECK_TIMEOUT"], let d = Double(v), d >= 2 {
            return d
        }
        return 12
    }()

    /// 带时长上限的检测：把上限换算成请求超时 + 截止时间传给同步检测，
    /// 卡住的站最多占用 `timeout` 秒就被记为「检测超时」，不拖累同批其它站。
    public static func checked(site: SiteConfig, client: HTTPClient, limit: TimeInterval? = nil) async -> Result {
        let cap = limit ?? timeout
        client.setRequestTimeout(cap)
        return check(site: site, client: client, budget: Budget(until: Date().addingTimeInterval(cap), seconds: cap))
    }

    /// 带时长上限的检测（自建连接池：某个站卡死时只作废它自己的连接）
    public static func checked(site: SiteConfig, cookies: CookieStore, userAgent: String,
                              limit: TimeInterval? = nil) async -> Result {
        let client = HTTPClient(cookies: cookies, userAgent: userAgent)
        return await checked(site: site, client: client, limit: limit)
    }

    public static func check(site: SiteConfig, client: HTTPClient, budget: Budget? = nil) -> Result {
        // 合并内置 overrides（用户配置可能没带，如馒头的 apiBase / usesAPIKey）
        let es = SiteRegistry.effectiveSite(site)
        // API Key 站点（馒头、肉丝等）：不走 cookie，用 API Key 检测
        if es.overrides?.usesAPIKey == true, (es.overrides?.apiBase ?? "") != "" {
            return checkAPIKey(es, client)
        }
        switch es.framework {
        case .cola:
            // 可乐两种凭据都收：填了 Key 验 Key，没填写验同步下来的 cookie
            return checkCola(es, client)
        case .yemapt:
            return checkYemaPT(site, client)
        case .tnode:
            return checkTNode(site, client)
        default:
            return checkGeneric(site, client, budget: budget)
        }
    }

    /// PeerGo（肉丝 rousi.pro）：`Authorization: Bearer <api-key>`，
    /// 用需要登录的列表端点验钥匙（200 = 有效，401/403 = 无效）。
    /// `/api/v1/me/api-key` 只认站点会话（不认 API Key），不能拿它验钥匙。
    private static func checkPeerGo(_ site: SiteConfig, key: String, base: String, client: HTTPClient) -> Result {
        let url = base + "/api/v1/torrents"
        let resp: HTTPClient.Response
        do {
            resp = try client.get(url, referer: site.url, extraHeaders: ["Authorization": "Bearer " + key])
        } catch {
            return Result(siteID: site.id, ok: false, message: "网络错误（站点不可达？）: \(error.localizedDescription)")
        }
        if resp.status == 401 || resp.status == 403 {
            return Result(siteID: site.id, ok: false, message: "API Key 未通过鉴权，请到站点「账号/API Key」重新生成")
        }
        if resp.status >= 200 && resp.status < 300 {
            return Result(siteID: site.id, ok: true, message: "API Key 有效")
        }
        return Result(siteID: site.id, ok: false,
                      message: "站点返回 HTTP \(resp.status)（API 地址或权限变更？）")
    }

    // MARK: - API Key（M-Team 等 Unit3D API 站点）

    /// 馒头（m-team）新网关：POST {apiBase}/api/member/profile + `x-api-key` 头。
    /// 旧写法（GET /api/user/get_user_details?api_key=）已失效：
    /// 网关不认查询参数鉴权（返回 code=401），且该路径根本不存在（"No static resource"），
    /// 于是有效 Key 也被误判为「API Key 无效或已过期」。
    /// 现网返回：有效 {"code":"0","message":"SUCCESS","data":{"username":...}}；
    /// 无效 {"code":1,"message":"key無效"}；无凭证 {"code":401,...}。
    private static func checkAPIKey(_ site: SiteConfig, _ client: HTTPClient) -> Result {
        let key = site.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            return Result(siteID: site.id, ok: false, message: "未配置 API Key（站点页「API Key」输入框）")
        }
        let base = (site.overrides?.apiBase ?? site.url).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if (site.overrides?.apiKeyStyle ?? "") == "peergo" {
            return checkPeerGo(site, key: key, base: base, client: client)
        }
        let url = base + "/api/member/profile"
        let resp: HTTPClient.Response
        do {
            resp = try client.postJSON(url, object: [:], referer: site.url,
                                       extraHeaders: ["x-api-key": key, "Origin": site.url])
        } catch {
            return Result(siteID: site.id, ok: false, message: "网络错误（站点不可达？）: \(error.localizedDescription)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any] else {
            return Result(siteID: site.id, ok: false,
                          message: "站点未返回 JSON（HTTP \(resp.status)，可能被网关拦截或 API 地址已变更）")
        }
        let code = apiCode(obj) ?? resp.status
        let msg = (obj["message"] as? String) ?? ""
        if resp.status == 401 || resp.status == 403 || code == 401 || code == 403 {
            return Result(siteID: site.id, ok: false, message: "API Key 未通过鉴权，请到站点页重新生成")
        }
        if code == 0 || msg.uppercased() == "SUCCESS" {
            if let data = obj["data"] as? [String: Any] {
                let name = (data["username"] as? String) ?? (data["name"] as? String) ?? ""
                return Result(siteID: site.id, ok: true,
                              message: name.isEmpty ? "API Key 有效" : "API Key 有效（\(name)）")
            }
            return Result(siteID: site.id, ok: true, message: "API Key 有效")
        }
        if msg.contains("無效") || msg.contains("无效") || msg.lowercased().contains("invalid") {
            return Result(siteID: site.id, ok: false, message: "API Key 无效或已过期（站点返回：\(msg)）")
        }
        return Result(siteID: site.id, ok: false, message: "API 返回 code=\(code)：\(msg)")
    }

    /// 站点返回码兼容字符串/数字（馒头用 "0" 表示成功）
    static func apiCode(_ obj: [String: Any]) -> Int? {
        if let i = obj["code"] as? Int { return i }
        if let d = obj["code"] as? Double { return Int(d) }
        if let str = obj["code"] as? String { return Int(str) }
        return nil
    }

    /// 可乐 PT：两种凭据分开验，别把「Key 没这门权限」说成「Key 失效」。
    /// 站点的 API Key 带 scope（torrent.upload 发种面 / mtorrent.compat MoviePilot 兼容面），
    /// 只有兼容面的 Key 去敲 Web 面（GET /me）会被回 403 api_key_scope_denied——
    /// 那是我们敲错了门，不是钥匙坏了。因此：
    ///   1) 发种面探针 GET /automation/me/torrents：过了就说明这把 Key 真能发种；
    ///   2) 没过再看 cookie（GET /api/v1/me）：cookie 能用就报「按 cookie 校验通过，转种走 cookie」，
    ///      并把 Key 的权限状况一并写在结论里；
    ///   3) 两样都不通才说失效，并说清缺哪一门。
    private static func checkCola(_ site: SiteConfig, _ client: HTTPClient) -> Result {
        let api = site.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1"
        let key = site.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = URL(string: site.url)?.host ?? ""
        var keyNote = ""
        if !key.isEmpty {
            let headers = ["Accept": "application/json", "Referer": site.url, "x-api-key": key]
            let probe: HTTPClient.Response? = try? client.get(api + "/automation/me/torrents?page_size=1",
                                                              referer: site.url, extraHeaders: headers)
            if let probe, probe.status < 400 {
                return Result(siteID: site.id, ok: true,
                              message: "API Key 有效（可发种）\(colaName(probe.data).isEmpty ? "" : "（\(colaName(probe.data))）")")
            }
            let code = probe.flatMap { colaErrorCode($0) } ?? "network_error"
            if code.contains("api_key") || code.contains("scope_denied") {
                if code.contains("scope_denied") {
                    keyNote = "Key 只有 MoviePilot 兼容面（mtorrent.compat），发种要 torrent.upload"
                } else {
                    keyNote = "API Key 已失效或被撤销"
                }
            } else {
                keyNote = "Key 校验没通（\(code)）"
            }
        }
        // B 计划：站点网页端登录后的 cookie（写接口要 Origin + X-CSRF-Token，读 /me 只要 cookie）
        let cookieProbe: HTTPClient.Response? = try? client.get(api + "/me", referer: site.url,
                                                                extraHeaders: ["Accept": "application/json"])
        let cookieOK = cookieProbe.map { $0.status < 400 } ?? false
        if cookieOK {
            let name = colaName(cookieProbe!.data)
            let tail = name.isEmpty ? "" : "（\(name)）"
            if keyNote.isEmpty {
                return Result(siteID: site.id, ok: true, message: "cookie 有效\(tail)")
            }
            // Key 不行但 cookie 能用：转种照样能跑，结论给 ok，并把 Key 的状况说清
            return Result(siteID: site.id, ok: true,
                          message: "按 cookie 校验通过\(tail)；\(keyNote)——转种走 cookie，"
                                 + "要用 Key 就到站点「个人中心 → API Keys」申请发种面权限，或清空 Key")
        }
        if !keyNote.isEmpty {
            return Result(siteID: site.id, ok: false,
                          message: "\(keyNote)；本地也没有\(host) 的有效 cookie：登录站点后同步一次，"
                                 + "或在「手动添加cookie或api key」里粘一样")
        }
        let status = cookieProbe?.status ?? 0
        if status == 401 || status == 403 {
            return Result(siteID: site.id, ok: false,
                          message: "cookie 已失效，请重新登录站点并触发 PT-depiler / CookieCloud 备份")
        }
        if status == 0 {
            return Result(siteID: site.id, ok: false, message: "网络错误（站点不可达？）")
        }
        return Result(siteID: site.id, ok: false, message: "站点返回 HTTP \(status)")
    }

    /// 站点错误体是 {"error":{code,…}}：取 code 用来分「Key 没权限」还是「Key 坏了」
    private static func colaErrorCode(_ resp: HTTPClient.Response) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
              let err = obj["error"] as? [String: Any],
              let code = err["code"] as? String else { return nil }
        return code.lowercased()
    }

    /// 探针回包里能带出的用户名（列表接口没有就留空，不影响结论）
    private static func colaName(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return (obj["username"] as? String)
            ?? ((obj["user"] as? [String: Any])?["username"] as? String) ?? ""
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

    private static func checkGeneric(_ site: SiteConfig, _ client: HTTPClient, budget: Budget?) -> Result {
        var resp: HTTPClient.Response
        do {
            resp = try client.get(site.url)
        } catch {
            guard retryPause(budget) else { return timeoutResult(site, budget) }
            do { resp = try client.get(site.url) } catch {
                return Result(siteID: site.id, ok: false,
                              message: "站点不可达（未确认登录态）: \(error.localizedDescription)", unconfirmed: true)
            }
        }
        if resp.status == 429 || resp.status >= 500, retryPause(budget),
           let again = try? client.get(site.url), (200..<300).contains(again.status) {
            resp = again
        }
        guard (200..<300).contains(resp.status) else {
            // 5xx / 429 多是 CDN 或源站抖动，说成「cookie 失效」会误导
            let unstable = resp.status == 429 || resp.status >= 500
            return Result(siteID: site.id, ok: false,
                          message: unstable ? "站点返回 HTTP \(resp.status)（源站/CDN 抖动），未确认登录态"
                                            : "HTTP \(resp.status)", unconfirmed: unstable)
        }
        let finalURL = resp.finalURL.lowercased()
        if loginRedirectMarkers.contains(where: { finalURL.contains($0) }) {
            return Result(siteID: site.id, ok: false, message: "跳转到登录页，cookie 已失效")
        }
        let body = (String(data: resp.data, encoding: .utf8) ?? "").lowercased()
        // 先判已登录标记再判未登录标记：部分站（熊猫/咖啡/OK 等）已登录首页也含"未登录"文案
        if let hit = loggedInMarkers.first(where: { body.contains($0) }) {
            return Result(siteID: site.id, ok: true, message: "已登录（命中「\(hit)」）")
        }
        if let hit = notLoggedInMarkers.first(where: { body.contains($0) }) {
            return Result(siteID: site.id, ok: false, message: "页面出现「\(hit)」，疑似未登录")
        }
        // 首页无法确认登录态时，NexusPHP 家族再探 userdetails.php（仅登录后可达）
        if site.framework == .nexusPHP || site.framework == .haidan {
            // 已经用完时间预算：不再二次探测，直接记超时（避免慢站翻倍耗时）
            if budget?.expired == true { return timeoutResult(site, budget) }
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
