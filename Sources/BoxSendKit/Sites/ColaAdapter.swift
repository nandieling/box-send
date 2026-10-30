import Foundation

/// 可乐 PT（www.colapt.com）：Vue SPA + REST API，没有 NexusPHP 那套上传表单。
/// 站方把 OpenAPI 编译进前端包（`api/v1` 下的 paths / components 两段 JSON），
/// 2026-10-30 照它对接（字段名、枚举值、必填项都取自那份 spec）：
///   POST {api}/media/ensure            {douban_id|imdb_id|tmdb_ref} -> {media_id, created}
///   POST {api}/torrents                裸 .torrent 正文，Content-Type: application/x-bittorrent
///                                      -> {id, revision, publication_stage:"draft"}；409 = 站内已有
///   PUT  {api}/torrents/{id}/metadata  {expected_revision, media_id, source, resolution, ...}
///   POST {api}/torrents/{id}/submit    {expected_revision, media_id} -> 进审核队列
/// 鉴权有两条路：站方给外部工具的是 API Key（`rcapi_…`，scope `torrent.upload`，
/// 认 `x-api-key` 头），配 `/api/v1/automation/*` 那组端点用——那组不查 Origin / CSRF；
/// 没填 Key 时退回 Web 端那条「站点 cookie + Origin + X-CSRF-Token」，CSRF 从 GET {api}/me 取。
final class ColaAdapter: SiteAdapter {
    let site: SiteConfig
    let client: HTTPClient
    let override: SiteOverride?
    let debugDir: String?

    init(site: SiteConfig, client: HTTPClient, debugDir: String? = nil) {
        self.site = site
        self.client = client
        self.override = site.overrides
        self.debugDir = debugDir
    }

    // MARK: - 端点与鉴权

    /// API 根（{site.url}api/v1）；站点换网关时可在 overrides.apiBase 里覆盖
    private var api: String {
        let base = (override?.apiBase?.isEmpty == false ? override?.apiBase : site.url) ?? site.url
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return trimmed + "/api/v1"
    }

    /// 站点写接口校验来源：Origin 必须是 scheme://host（不带结尾斜杠）
    private var origin: String {
        guard let u = URL(string: site.url), let s = u.scheme, let h = u.host else {
            return site.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return "\(s)://\(h)"
    }

    private var key: String? {
        guard let k = site.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty
        else { return nil }
        return k
    }

    /// 本地有没有该站的 cookie（可乐的 B 计划：Key 只能走兼容面时，发种退回 cookie）
    var hasCookie: Bool {
        guard let host = URL(string: site.url)?.host else { return false }
        return client.cookies.cookieHeader(forHost: host) != nil
    }

    // MARK: 用哪把钥匙
    //
    // 可乐的 API Key 分两种权限（站方 spec：scopes ∈ torrent.upload | mtorrent.compat）：
    //   torrent.upload   —— 发种面，即 /api/v1/automation/* 那组写端点
    //   mtorrent.compat  —— MoviePilot 兼容面，站外工具能用，但它开不了发种那扇门
    // 老写法「填了 Key 就只认 Key」会把只有兼容面的用户直接判死：
    // 挂种子 403 api_key_scope_denied，界面显示「API Key 失效」，可他删掉 Key 用 cookie 本来转得好好的。
    // 现在按权限分流：先拿只读的 /automation/me/torrents 探一次，探得过才走 Key；
    // 探不过且有 cookie 就走 cookie（Origin + CSRF）；没 cookie 就仍用 Key，
    // 至少报错能说清「是这把 Key 缺 torrent.upload」。判定每个适配器缓存一次，别每步都探。
    /// 探针结果缓存（internal：测试直接给结论，不打网络）
    var cachedKeyCanUpload: Bool?

    private var keyCanUpload: Bool {
        if let cached = cachedKeyCanUpload { return cached }
        let ok = probeKeyForUpload()
        cachedKeyCanUpload = ok
        return ok
    }

    /// 站点按「Key 这一把钥匙」拒绝的信号（区别于 cookie 的 authentication_required）
    static func isKeyRejection(_ resp: HTTPClient.Response) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
              let err = obj["error"] as? [String: Any],
              let code = (err["code"] as? String)?.lowercased() else { return false }
        return code.contains("api_key") || code.contains("scope_denied")
    }

    /// 只读探针：能列出「我的种子」= 这把 Key 有发种面权限
    private func probeKeyForUpload() -> Bool {
        guard let k = key else { return false }
        guard let resp = try? send("GET", api + "/automation/me/torrents?page_size=1",
                                   body: nil, contentType: nil,
                                   headers: ["Accept": "application/json", "Referer": site.url,
                                            "x-api-key": k])
        else { return false }
        return resp.status < 400
    }

    var usesAutomation: Bool {
        if usesCookieOverride { return false }
        guard key != nil else { return false }
        // 没 cookie 兜底时仍按 Key 试：报错信息能指到「Key 缺哪门权限」
        return hasCookie ? keyCanUpload : true
    }

    /// 写操作现场被 Key 拒了（权限没开、Key 过期）且本地有 cookie：这次改走 cookie
    private var usesCookieOverride = false

    private var root: String { usesAutomation ? api + "/automation" : api }

    private func headers(csrf: String? = nil) -> [String: String] {
        var h = ["Accept": "application/json", "Referer": site.url]
        if usesAutomation {
            if let k = key { h["x-api-key"] = k }
        } else {
            h["Origin"] = origin
            if let csrf { h["X-CSRF-Token"] = csrf }
        }
        return h
    }

    /// cookie 模式写操作前要一枚 CSRF；API Key 模式不需要
    private func csrfToken() -> String? {
        guard !usesAutomation else { return nil }
        guard let data = try? send("GET", api + "/me", body: nil, contentType: nil,
                                  headers: headers()).data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = obj["session"] as? [String: Any],
              let token = session["csrf_token"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    @discardableResult
    private func send(_ method: String, _ url: String, body: Data?, contentType: String?,
                      headers: [String: String]) throws -> HTTPClient.Response {
        do {
            if let body, let contentType {
                return try client.postRaw(url, body: body, contentType: contentType,
                                          referer: site.url, extraHeaders: headers, method: method)
            }
            if method == "GET" {
                return try client.get(url, referer: site.url, extraHeaders: headers)
            }
            return try client.postJSON(url, object: [:], referer: site.url, extraHeaders: headers)
        } catch {
            throw BoxSendError.badInput("\(site.name) 接口不通（\(method) \(url)）：\(error.localizedDescription)")
        }
    }

    /// 站点错误体固定是 {"error":{code,message,fields}}；按 code 压成一句能看懂的原因。
    /// 关键是把「Key 没这门权限」和「Key 失效」分开：站点对只有 mtorrent.compat 的 Key
    /// 也回 403，一刀切报「失效」会让人以为钥匙坏了，其实是我们敲错了门。
    private func failure(_ resp: HTTPClient.Response, _ what: String) -> BoxSendError {
        var code = ""
        var detail = ""
        if let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
           let err = obj["error"] as? [String: Any] {
            code = (err["code"] as? String) ?? ""
            let msg = (err["message"] as? String) ?? ""
            detail = [code, msg].filter { !$0.isEmpty }.joined(separator: "：")
            if let fields = err["fields"] as? [String: Any], !fields.isEmpty {
                detail += "（字段：\(fields.keys.sorted().joined(separator: "、"))）"
            }
        }
        let head = "\(site.name) \(what)"
        let tail = detail.isEmpty ? "" : "（\(detail)）"
        if resp.status == 401 || resp.status == 403 {
            let lower = code.lowercased()
            if lower.contains("scope_denied") {
                // 有 cookie 的话上面已经自动改道了；走到这里说明只能靠 Key
                return BoxSendError.apiKeyInvalid(
                    "\(head) 被站点按权限拦下\(tail)：这把 Key 只有 MoviePilot 兼容面"
                    + "（mtorrent.compat），发种要的是 torrent.upload。"
                    + "去站点「个人中心 → API Keys」申请发种面权限；"
                    + "或清空 Key、登录网页端后用同步下来的 cookie 转种。")
            }
            if lower.contains("api_key") {
                return BoxSendError.apiKeyInvalid(
                    "\(head) 未通过\(tail)：API Key 已失效或被撤销，重新生成一把，"
                    + "或清空 Key 改用同步下来的 cookie。")
            }
            return BoxSendError.cookieExpired(
                "\(head) 鉴权未通过\(tail)：cookie 已失效，重新登录站点并触发"
                + " PT-depiler / CookieCloud 同步；用 API Key 的话要带 torrent.upload 权限。")
        }
        return BoxSendError.http(status: resp.status, url: site.url,
                                 body: detail.isEmpty ? "\(what)（HTTP \(resp.status)）"
                                                      : "\(what)（HTTP \(resp.status)）：\(detail)")
    }

    /// 发一次接口并解 JSON。
    /// - Parameter automation: 该端点在 `/automation` 面上有没有；站方只在 automation 下开了
    ///   写操作与 `GET /automation/torrents/{id}`，`GET /media`（查重）只有 Web 面有，
    ///   所以填了 Key 时读查重也得回落到 `api` 根，不然会 404。
    private func json(_ method: String, _ path: String, object: [String: Any]? = nil,
                      raw: Data? = nil, contentType: String? = nil,
                      automation: Bool = true, csrfRetry: Bool = true) throws -> [String: Any] {
        let body: Data?
        let type: String?
        if let raw {
            body = raw
            type = contentType ?? "application/x-bittorrent"
        } else if let object {
            body = try? JSONSerialization.data(withJSONObject: object)
            type = "application/json"
        } else {
            body = nil
            type = nil
        }
        func attempt(_ csrf: String?) throws -> HTTPClient.Response {
            try send(method, (automation ? root : api) + path,
                     body: body, contentType: type, headers: headers(csrf: csrf))
        }
        let csrf = method == "GET" ? nil : csrfToken()
        var resp = try attempt(csrf)
        // Key 现场被拒（权限没开放 / Key 过期）而本地有 cookie：整站改走 cookie 再试一次
        if resp.status == 401 || resp.status == 403, usesAutomation, hasCookie,
           ColaAdapter.isKeyRejection(resp) {
            usesCookieOverride = true
            cachedKeyCanUpload = false
            resp = try attempt(method == "GET" ? nil : csrfToken())
        }
        // cookie 模式下 CSRF 是一次性票据（用过一次/过期就 403）：换一枚新的再试一次
        if resp.status == 403, csrfRetry, !usesAutomation, method != "GET" {
            resp = try attempt(csrfToken())
        }
        if resp.status >= 400 { throw failure(resp, path) }
        guard let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any] else {
            throw BoxSendError.badInput("\(site.name) \(path) 未返回 JSON（HTTP \(resp.status)）")
        }
        return obj
    }

    // MARK: - 作品关联（media_id）

    /// 站方发种强制「先关联作品」：拿豆瓣 / IMDb / TMDB 号去 ensure 一个 media_id。
    /// 返回的是 MediaReference（rc… / tt… / 豆瓣条目 URL），提交时原样回填。
    func ensureMedia(_ info: ReleaseInfo) throws -> String {
        var tried: [String] = []
        for candidate in mediaCandidates(info) {
            tried.append(candidate.key)
            do {
                let obj = try json("POST", "/media/ensure", object: [candidate.key: candidate.value])
                if let id = obj["media_id"] as? String, !id.isEmpty { return id }
            } catch {
                continue
            }
        }
        if let poster = ColaFields.newMedia(info: info, descr: ColaFields.synopsis(from: info)) {
            let obj = try json("POST", "/media/ensure", object: ["new_media": poster])
            if let id = obj["media_id"] as? String, !id.isEmpty { return id }
        }
        throw BoxSendError.badInput("""
        \(site.name) 发种要先关联作品：豆瓣 / IMDb / TMDB 三个号都没拿到（试过 \(tried.joined(separator: "、"))）。
        源站简介里补一个链接，或在「批量转种」页把链接贴上再转。
        """)
    }

    /// ensure 接口的入参名与值：豆瓣号 / IMDb 号 / TMDB 引用
    private func mediaCandidates(_ info: ReleaseInfo) -> [(key: String, value: String)] {
        var out: [(String, String)] = []
        if let d = ColaFields.doubanID(info.douban) { out.append(("douban_id", d)) }
        if let i = ColaFields.imdbID(info.imdb) { out.append(("imdb_id", i)) }
        if let t = ColaFields.tmdbRef(info.tmdb) { out.append(("tmdb_ref", t)) }
        return out
    }

    // MARK: - SiteAdapter

    func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
        let mediaID = try ensureMedia(info)
        let shots = ColaFields.screenshots(from: info, base: site.url)
        guard !shots.isEmpty else {
            throw BoxSendError.badInput("\(site.name) 发种至少要一张截图：源简介里没取到图片地址")
        }
        // 1) 挂种子：裸 .torrent 正文，站点回 id + revision（409 = 这份种子站内已有）
        let created = try createTorrent(torrentData)
        if let existing = created.duplicate {
            return UploadOutcome(success: true, message: "站内已有这条种子（\(existing)）",
                                 detailURL: created.detailURL, alreadyExists: true)
        }
        guard let torrentID = created.id, let revision = created.revision else {
            throw BoxSendError.badInput("\(site.name) 挂种子后没拿到 id/revision")
        }
        // 2) 填元信息（分类、片源、分辨率、编码、HDR、音轨、字幕、简介、截图、发布范围）
        var revisionNow = revision
        let meta = ColaFields.metadata(info: info, site: site, mediaID: mediaID,
                                       expectedRevision: revisionNow, screenshots: shots)
        let updated = try json("PUT", "/torrents/\(torrentID)/metadata", object: meta)
        if let r = updated["revision"] as? Int { revisionNow = r }
        // 3) 提交进审核队列（站点要求带 expected_revision + media_id）
        let stage = try submit(torrentID: torrentID, revision: revisionNow, mediaID: mediaID)
        let url = site.url + "torrents/\(torrentID)"
        return UploadOutcome(success: true,
                             message: "已提交（\(stage)）",
                             detailURL: url)
    }

    private struct CreatedTorrent {
        var id: Int?
        var revision: Int?
        var detailURL: String?
        var duplicate: String?
    }

    private func createTorrent(_ data: Data) throws -> CreatedTorrent {
        do {
            let obj = try json("POST", "/torrents", raw: data, contentType: "application/x-bittorrent")
            return CreatedTorrent(id: ColaFields.intOf(obj["id"]),
                                  revision: ColaFields.intOf(obj["revision"]),
                                  detailURL: nil, duplicate: nil)
        } catch BoxSendError.http(let status, _, let body) {
            // 409 = 这份 info_hash 站内已经有了：算重复，不算失败
            if status == 409 {
                return CreatedTorrent(id: nil, revision: nil, detailURL: nil,
                                      duplicate: body.isEmpty ? "站点回 409（同一份种子已存在）" : body)
            }
            throw BoxSendError.http(status: status, url: site.url, body: "\(site.name) 挂种子失败：\(body)")
        }
    }

    private func submit(torrentID: Int, revision: Int, mediaID: String) throws -> String {
        var payload: [String: Any] = ["expected_revision": revision]
        // MediaReference 只认 rc… / tt… / 豆瓣条目 URL，不认的就别硬提交
        if ColaFields.isMediaReference(mediaID) { payload["media_id"] = mediaID }
        do {
            let obj = try json("POST", "/torrents/\(torrentID)/submit", object: payload)
            return (obj["publication_stage"] as? String)
                ?? ((obj["status"] as? String).map { $0 == "approved" ? "已发布" : "待审核"} ?? "待审核")
        } catch {
            // 元信息已经落库，提交失败要说清去哪儿手动点一下
            throw BoxSendError.badInput("\(site.name) 种子已挂上并填好元信息，但提交审核没成："
                + "\(error.localizedDescription)；可到 \(site.url)uploads/\(torrentID)/edit 手动提交")
        }
    }

    /// 查重：按豆瓣 / IMDb 号找作品，再比作品下各版本的发布名（大小、名称两条都过才算同一种子）。
    /// 查重只是提前打招呼，站点真有了挂种子那步也会回 409，所以查不动就安静放过，别把整站转种判死。
    func searchExists(_ info: ReleaseInfo, relaxed: Bool) throws -> String? {
        var groups: [[String: Any]] = []
        for candidate in mediaCandidates(info) {
            let q = candidate.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? candidate.value
            guard let obj = try? json("GET", "/media?\(candidate.key)=\(q)", automation: false)
            else { continue }
            groups.append(contentsOf: (obj["items"] as? [[String: Any]]) ?? [])
            if !groups.isEmpty { break }
        }
        if groups.isEmpty, let q = ColaFields.searchKey(from: info.name),
           let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let obj = try? json("GET", "/media?q=\(encoded)&page_size=20", automation: false) {
            groups = (obj["items"] as? [[String: Any]]) ?? []
        }
        let want = ColaFields.normalize(ColaFields.title(from: info))
        for g in groups {
            let versions = (g["versions"] as? [[String: Any]]) ?? []
            for v in versions {
                guard let name = v["release_name"] as? String else { continue }
                if ColaFields.normalize(name) == want,
                   ColaFields.sameSize(ColaFields.intOf(v["size_bytes"]), info.size) {
                    lastDuplicateTitle = name
                    if let id = ColaFields.intOf(v["id"]) { return site.url + "torrents/\(id)" }
                }
            }
        }
        return nil
    }

    func searchExists(_ info: ReleaseInfo) throws -> String? { try searchExists(info, relaxed: false) }

    var canPrecheckDuplicate: Bool { true }
    var duplicateHitTitle: String? { lastDuplicateTitle }
    private var lastDuplicateTitle: String?

    /// 站内那条是不是本账号发的：站点直接给 viewer_is_owner，其次比发布人名
    func torrentOwnership(detailURL: String, uploadedAt: Date?) -> TorrentOwnership {
        guard let id = ColaFields.intOf(detailURL.split(separator: "/").last.map(String.init)),
              let obj = try? json("GET", "/torrents/\(id)"),
              obj["id"] != nil else { return .unknown }
        if let mine = obj["viewer_is_owner"] as? Bool { return mine ? .ours : .theirs }
        let publisher = (obj["publisher"] as? [String: Any])?["username"] as? String ?? ""
        guard !publisher.isEmpty, let me = username() else { return .unknown }
        return publisher.caseInsensitiveCompare(me) == .orderedSame ? .ours : .theirs
    }

    private func username() -> String? {
        guard let obj = try? json("GET", "/me") else { return nil }
        return obj["username"] as? String
    }

    func fetchTorrentList() throws -> [ReleaseInfo] { [] }

    /// 可乐当源站用（少境）：从接口取详情，简介取媒体简介
    func fetchDetail(detailURL: String) throws -> ReleaseInfo {
        guard let id = ColaFields.intOf(detailURL.split(separator: "/").last.map(String.init)) else {
            throw BoxSendError.badInput("\(site.name) 详情页链接里认不出种子 id：\(detailURL)")
        }
        let obj = try json("GET", "/torrents/\(id)")
        var info = ReleaseInfo(siteID: site.id, detailURL: detailURL,
                               name: (obj["release_name"] as? String) ?? "")
        info.descr = (obj["description"] as? String) ?? ""
        info.mediainfo = (obj["media_info"] as? String) ?? ""
        info.subtitle = (obj["subtitle"] as? String) ?? ""
        if let size = ColaFields.intOf(obj["size_bytes"]) { info.size = Int64(size) }
        if let subs = obj["subtitles"] as? [String], subs.contains("zh") {
            info.sourceTags.append("中字")
        }
        if let tags = obj["tags"] as? [String] { info.sourceTags.append(contentsOf: tags) }
        if let media = obj["media"] as? [String: Any] {
            info.douban = ColaFields.doubanURL(media["douban_url"] as? String)
            info.imdb = ColaFields.imdbID(media["imdb_url"] as? String)
            info.tmdb = (media["tmdb_url"] as? String)
            if let cat = media["category"] as? String { info.kind = ColaFields.kind(fromCategory: cat) }
        }
        info.torrentURL = "\(api)/torrents/\(id)/download"
        return info
    }

    func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String) {
        guard let id = ColaFields.intOf(info.detailURL.split(separator: "/").last.map(String.init))
                ?? ColaFields.intOf(info.torrentURL) else {
            throw BoxSendError.badInput("\(site.name) 取种子文件认不出种子 id：\(info.detailURL)")
        }
        // 站点的下载接口要先领一张一次性下载授权（authorization_id），拿不到就直接试裸链接
        var query = ""
        if let auth = try? authorizationID(id) { query = "?authorization_id=\(auth)" }
        let resp = try send("GET", root + "/torrents/\(id)/download" + query,
                            body: nil, contentType: nil, headers: headers())
        guard resp.status < 400, resp.data.count > 20 else {
            throw BoxSendError.badInput("\(site.name) 下载种子失败：HTTP \(resp.status)"
                + "（多半是下载授权没领到）")
        }
        return (resp.data, info.torrentName.isEmpty ? "seed.torrent" : info.torrentName)
    }

    /// POST /torrents/{id}/authorizations -> {id}：下载接口的 authorization_id
    private func authorizationID(_ torrentID: Int) throws -> Int {
        let obj = try json("POST", "/torrents/\(torrentID)/authorizations", object: [:])
        guard let id = ColaFields.intOf(obj["id"]) else {
            throw BoxSendError.badInput("\(site.name) 没领到下载授权 id")
        }
        return id
    }

    func previewUploadFields(_ info: ReleaseInfo) throws -> [(String, String)] {
        let shots = ColaFields.screenshots(from: info, base: site.url)
        let meta = ColaFields.metadata(info: info, site: site, mediaID: "<media_id>",
                                       expectedRevision: 1, screenshots: shots)
        return meta.keys.sorted().map { k in
            (k, ColaFields.text(meta[k]))
        }
    }
}
