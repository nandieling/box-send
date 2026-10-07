import Foundation

/// PeerGo 引擎站点（肉丝 rousi.pro）：发种不是 HTML 表单，而是 JSON API + multipart。
/// 2026-10-06 实站实测：
///   GET  /api/v1/categories?include_disabled=1  -> [{id,name}]，发种用字符串 id（如 anime）
///   GET  /api/v1/categories/{id}/facets         -> 分类属性（facet id / 选项 key / 是否必填）
///   GET  /api/v1/session                        -> csrf_token
///   POST /api/v1/torrents                       -> 201 {id,state}，state=pending_review 为待审
/// 写接口要求同源 Origin，且只接受「会话 cookie + X-CSRF-Token」；
/// API Key 能读接口（用于检测 cookie/api key 是否有效），写接口一律回 4001 上传参数错误。
final class PeerGoAdapter: SiteAdapter {
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

    private var api: String {
        let base = (override?.apiBase?.isEmpty == false ? override?.apiBase : site.url) ?? site.url
        return base.hasSuffix("/") ? String(base.dropLast()) : base
    }

    /// 同源 Origin/Referer：PeerGo 对所有写请求做来源校验
    private var originHeaders: [String: String] {
        var h = ["Accept": "application/json"]
        let origin = URL(string: site.url)?.scheme != nil
            ? (URL(string: site.url)?.scheme ?? "https") + "://" + (URL(string: site.url)?.host ?? "")
            : site.url
        h["Origin"] = origin
        h["Referer"] = site.url
        return h
    }

    // MARK: - 接口模型

    private struct Category: Decodable { let id: String; let name: String? }
    private struct Option: Decodable { let key: String; let label: String? }
    private struct Facet: Decodable {
        let id: String
        let name: String?
        let required: Bool?
        let selection_mode: String?
        let requirement_group: String?
        let options: [Option]?
    }
    private struct Torrent: Decodable {
        let id: Int?
        let state: String?
        let title: String?
        let download_url: String?
    }

    /// GET JSON。默认匿名：分类/属性端点在匿名下返回公开 schema（裸数组）。
    /// 种子列表端点必须 `auth: true`：匿名下 keyword 参数被忽略（会把全站列表当结果返回），
    /// 带上 API Key 才是 {code,data:{torrents:[…]}} 且按关键词过滤。
    private func json(_ url: String, headers: [String: String] = [:], auth: Bool = false) throws -> Data {
        var merged = originHeaders
        if auth, let key = site.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            merged["Authorization"] = "Bearer " + key
        }
        for (k, v) in headers { merged[k] = v }
        let resp = try client.get(url, referer: site.url, extraHeaders: merged)
        guard resp.status < 400 else {
            throw BoxSendError.badInput("HTTP \(resp.status) \(PeerGoAdapter.errorMessage(resp.data) ?? "")")
        }
        return resp.data
    }

    /// 错误体既可能是 problem+json（title/detail/code），也可能是 {code,message}
    static func errorMessage(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let parts = ["title", "detail", "message"].compactMap { obj[$0] as? String }
        if let code = obj["code"] as? String { return ([code] + parts).joined(separator: "：") }
        return parts.isEmpty ? nil : parts.joined(separator: "：")
    }

    // MARK: - 列表 / 详情 / 下载

    func fetchTorrentList() throws -> [ReleaseInfo] {
        let data = try json("\(api)/api/v1/torrents")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = obj["data"] as? [String: Any],
              let list = inner["torrents"] as? [[String: Any]] else { return [] }
        return list.compactMap { t in
            guard let id = t["id"] as? Int, let title = t["title"] as? String else { return nil }
            return ReleaseInfo(siteID: site.id, detailURL: "\(api)/torrents/\(id)", name: title,
                               kind: ReleaseKind.infer(from: title),
                               torrentName: title + ".torrent")
        }
    }

    /// 详情页是 SPA，用接口取标题与种子下载地址
    func fetchDetail(detailURL: String) throws -> ReleaseInfo {
        guard let id = HTMLUtil.group(detailURL, "(\\d+)/?(?:\\?|$)") ?? HTMLUtil.group(detailURL, "(\\d+)$") else {
            throw BoxSendError.badInput("无法从链接取种子 id: \(detailURL)")
        }
        let data = try json("\(api)/api/v1/torrents/\(id)")
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any]
            ?? (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let title = (obj["title"] as? String) ?? ""
        let dl = (obj["download_url"] as? String) ?? "\(api)/api/v1/torrents/\(id)/download"
        guard !title.isEmpty else { throw BoxSendError.badInput("未解析到种子标题: \(detailURL)") }
        return ReleaseInfo(siteID: site.id, detailURL: detailURL, name: title,
                           kind: ReleaseKind.infer(from: title),
                           torrentName: title + ".torrent", torrentURL: dl)
    }

    func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String) {
        let resp = try client.get(info.torrentURL, referer: site.url, extraHeaders: originHeaders)
        guard resp.status < 400, resp.data.count > 20 else {
            throw BoxSendError.badInput("下载种子失败 HTTP \(resp.status)")
        }
        return (resp.data, info.torrentName.isEmpty ? "release.torrent" : info.torrentName)
    }

    /// 站内查重：`GET /api/v1/torrents?keyword=<单词>`（多词会被当整短语匹配不到，只给一个词）
    func searchExists(_ info: ReleaseInfo) throws -> String? {
        if case .found(let url) = try checkExisting(info) { return url }
        return nil
    }

    enum ExistingCheck {
        case found(url: String)     // 站内确有同名种子
        case absent                 // 检索成功且没有
        case unknown                // 检索没做成（接口异常等），不作判定
    }

    func checkExisting(_ info: ReleaseInfo) throws -> ExistingCheck {
        guard let kw = Self.searchKeyword(info.name) else { return .unknown }
        let base = (override?.searchURL?.isEmpty == false)
            ? (override!.searchURL!.replacingOccurrences(of: "{name}", with: kw.urlEncoded))
            : "api/v1/torrents?keyword=" + kw.urlEncoded
        let url = base.hasPrefix("http") ? base : api + "/" + base
        guard let data = try? json(url, auth: true),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unknown }
        // 带 API Key：{code, data:{torrents:[…]}}；匿名公开接口：{items:[…]}
        let list = ((obj["data"] as? [String: Any])?["torrents"] as? [[String: Any]])
            ?? (obj["items"] as? [[String: Any]])
        guard let list else { return .unknown }
        let target = NexusPHPAdapter.normalizeSearchName(info.name)
        guard target.count >= 8 else { return .unknown }
        for t in list {
            guard let title = (t["title"] as? String) ?? (t["name"] as? String) else { continue }
            let cand = NexusPHPAdapter.normalizeSearchName(title)
            guard cand.count >= 8 else { continue }
            if cand.contains(target) || (target.count >= 15 && target.contains(cand)),
               let id = t["id"] {
                return .found(url: "\(api)/torrents/\(id)")
            }
        }
        return .absent
    }

    /// 站点搜索词：取发布名里第一个长度 >= 3 的词
    static let keywordSeparators: Set<Character> = [" ", "\t", ".", "_", "-", "(", "[", "{", "、", "|", "/", ":"]

    static func searchKeyword(_ name: String) -> String? {
        let words = name.split(whereSeparator: { $0.isWhitespace || keywordSeparators.contains($0) })
        if let w = words.first(where: { $0.count >= 3 && $0.contains { $0.isLetter } }) { return String(w) }
        if let w = words.first(where: { $0.count >= 3 }) { return String(w) }
        let t = name.trimmingCharacters(in: .whitespaces)
        return t.count >= 3 ? String(t.prefix(6)) : nil
    }

    func previewUploadFields(_ info: ReleaseInfo) throws -> [(String, String)] {
        let cats = try categories()
        return [("categories", cats.map { $0.id }.joined(separator: ",")),
                ("category", try categoryID(cats, info: info))]
    }

    // MARK: - 发种

    func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
        let cats = try categories()
        let cid = try categoryID(cats, info: info)
        let facets = try facets(for: cid)
        let csrf = try csrfToken()

        var fields: [HTTPClient.MultipartField] = [
            .init("category_id", cid),
            .init("title", info.name),
            .init("subtitle", info.subtitle),
            .init("description", description(info)),
            .init("media_info", info.mediainfo),
            .init("anonymous", "false"),
        ]
        if let d = info.douban { fields.append(.init("douban_id", d)) }
        if let i = info.imdb { fields.append(.init("imdb_id", i)) }

        var files: [(name: String, filename: String, data: Data, mime: String)] = []
        var n = 0
        for sel in selections(facets: facets, info: info) {
            n += 1
            guard let data = try? JSONSerialization.data(withJSONObject: sel) else { continue }
            files.append(("facet_selections", "facet-selection-\(n).json", data, "application/json"))
        }
        let shots = try screenshotFiles(info)
        for (i, s) in shots.enumerated() {
            files.append(("screenshots", "shot-\(i + 1).\(s.ext)", s.data, s.mime))
        }
        files.append(("torrent_file", filename, torrentData, "application/x-bittorrent"))

        var headers = originHeaders
        headers["X-CSRF-Token"] = csrf
        headers["Idempotency-Key"] = UUID().uuidString.lowercased()
        let resp = try client.postMultipart("\(api)/api/v1/torrents", fields: fields, files: files,
                                            referer: site.url, extraHeaders: headers)
        let body = resp.data
        if resp.status == 201 || resp.status == 200 {
            let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["data"] as? [String: Any]
                ?? (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            if let id = obj["id"] as? Int {
                let state = (obj["state"] as? String) ?? ""
                return UploadOutcome(success: true,
                                     message: state.contains("review") ? "发布成功（待审核）" : "发布成功",
                                     detailURL: "\(api)/torrents/\(id)")
            }
            return UploadOutcome(success: true, message: "发布成功", detailURL: nil)
        }
        let msg = PeerGoAdapter.errorMessage(body) ?? "HTTP \(resp.status) 未识别的返回"
        if msg.contains("已存在") || msg.contains("已经存在") || msg.lowercased().contains("exist")
            || msg.lowercased().contains("duplicate") {
            // 站点说「已存在」未必真有一条能在列表里看到的种子：
            // 肉丝此前提交但被审核驳回的记录会一直占用 info hash（实测 404 种子不存在 + 再传 409），
            // 直接记成功会让人以为转种完成了。所以回查一次站内。
            switch (try? checkExisting(info)) ?? .unknown {
            case .found(let url):
                return UploadOutcome(success: true, message: "站点已存在该种子（\(url)）",
                                     detailURL: url, alreadyExists: true)
            case .absent:
                return UploadOutcome(
                    success: false,
                    message: "站点判为「种子已存在」但按标题在站内查不到：可能是他人用不同标题发过，"
                        + "也可能是此前提交的同名种子被审核驳回后仍占用该 info hash（实测肉丝：/api/v1/torrents/<id> 已 404，重传仍回 409）",
                    detailURL: nil)
            case .unknown:
                return UploadOutcome(success: true, message: "站点已存在该种子（未能回查站内链接）",
                                     detailURL: nil, alreadyExists: true)
            }
        }
        save("upload", String(data: body, encoding: .utf8) ?? "")
        return UploadOutcome(success: false, message: msg, detailURL: nil)
    }

    private func csrfToken() throws -> String {
        let data = try json("\(api)/api/v1/session")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["csrf_token"] as? String, !t.isEmpty else {
            throw BoxSendError.badInput("\(site.name) 发种需要登录会话（同步该站 cookie 后重试）")
        }
        return t
    }

    private func categories() throws -> [Category] {
        let data = try json("\(api)/api/v1/categories?include_disabled=1")
        if let list = try? JSONDecoder().decode([Category].self, from: data) { return list }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = obj["data"] as? [Any] {
            return inner.compactMap { item in
                guard let d = try? JSONSerialization.data(withJSONObject: item) else { return nil }
                return try? JSONDecoder().decode(Category.self, from: d)
            }
        }
        return []
    }

    private func facets(for cid: String) throws -> [Facet] {
        let data = try json("\(api)/api/v1/categories/\(cid)/facets")
        if let list = try? JSONDecoder().decode([Facet].self, from: data) { return list }
        return []
    }

    /// 分类：优先按中文分类名匹配源站类别，其次按 kind 的常见 id
    private func categoryID(_ cats: [Category], info: ReleaseInfo) throws -> String {
        let text = QualityMatcher.normalize([info.genre, info.kind?.rawValue ?? ""].joined(separator: " "))
        let kindKeys: [String: [String]] = [
            "movie": ["电影", "movie"], "series": ["电视剧", "剧集", "tv", "series"],
            "tvshow": ["综艺", "variety", "show"], "anime": ["动漫", "动画", "anime", "animation"],
            "documentary": ["纪录片", "documentary"], "music": ["音乐", "music"],
            "sports": ["体育", "sports"], "other": ["其它", "其他", "other"],
        ]
        let keys = kindKeys[info.kind?.rawValue ?? "other"] ?? []
        for k in keys where text.contains(k) {
            if let c = cats.first(where: { QualityMatcher.normalize($0.name ?? "").contains(k)
                || QualityMatcher.normalize($0.id).contains(k) }) { return c.id }
        }
        for k in keys {
            if let c = cats.first(where: { QualityMatcher.normalize($0.id) == k }) { return c.id }
        }
        if let other = cats.first(where: { $0.id == "other" }) { return other.id }
        guard let first = cats.first else { throw BoxSendError.badInput("\(site.name) 没有可用分类") }
        return first.id
    }

    /// 属性取值：按 facet id / 名称分派，缺值时尽量落到「其它」，必填项绝不空着
    private func selections(facets: [Facet], info: ReleaseInfo) -> [[String: Any]] {
        let plain = QualityMatcher.normalize(HTMLUtil.stripTags(HTMLUtil.decodeEntities(info.descr))
                                            + " " + info.name + " " + info.genre + " " + info.region)
        var out: [[String: Any]] = []
        for f in facets {
            let opts = f.options ?? []
            guard !opts.isEmpty else { continue }
            let fid = f.id.lowercased()
            let fname = QualityMatcher.normalize(f.name ?? "")
            var keys: [String] = []
            func firstMatching(_ candidates: [String]) -> String? {
                for c in candidates {
                    if let o = opts.first(where: { QualityMatcher.normalize($0.label ?? "") == c }) { return o.key }
                }
                for c in candidates {
                    if let o = opts.first(where: { QualityMatcher.normalize($0.label ?? "").contains(c)
                        || QualityMatcher.normalize($0.key) == c }) { return o.key }
                }
                return nil
            }
            func other() -> String? {
                opts.first { let t = QualityMatcher.normalize($0.label ?? ""); return t == "其它" || t == "其他" || t == "other" }?.key
            }
            if fid.contains("region") || fname.contains("地区") || fname.contains("国家") {
                let labels = opts.map { (value: $0.key, label: $0.label ?? "") }
                keys = RegionMatch.option(forRegion: info.region, in: labels).map { [$0] } ?? []
                if keys.isEmpty { keys = other().map { [$0] } ?? [] }
            } else if fid.contains("resolution") || fname.contains("分辨率") || fname.contains("清晰度") {
                let want = QualityTokens.standard(from: info.name).map { [$0] } ?? []
                keys = firstMatching(want + ["其它"]).map { [$0] } ?? []
            } else if fid.contains("genre") || fname.contains("类型") {
                keys = opts.filter { !$0.key.isEmpty && plain.contains(QualityMatcher.normalize($0.label ?? "")) }
                    .prefix(5).map { $0.key }
                if keys.isEmpty {
                    let guess = info.kind == .anime ? ["动画"] : (info.kind == .documentary ? ["纪录片"] : ["其它"])
                    keys = firstMatching(guess).map { [$0] } ?? (other().map { [$0] } ?? [])
                }
            } else if fid.contains("source") || fname.contains("来源") || fname.contains("介质") {
                keys = firstMatching(Self.sourceMediumTokens(QualityTokens.catProfile(from: info.name, kind: info.kind))
                    + ["其它"]).map { [$0] } ?? []
            } else if fid.contains("release") || fname.contains("发布类型") {
                keys = firstMatching(Self.releaseTypeTokens(QualityTokens.catProfile(from: info.name, kind: info.kind))
                    + ["其它"]).map { [$0] } ?? []
            } else {
                keys = opts.filter { plain.contains(QualityMatcher.normalize($0.label ?? "")) }.prefix(3).map { $0.key }
            }
            if keys.isEmpty, f.required == true || f.requirement_group != nil {
                keys = other().map { [$0] } ?? []
            }
            if !keys.isEmpty { out.append(["facet_id": f.id, "option_keys": keys]) }
        }
        return out
    }

    /// 质量档案 -> PeerGo「来源」选项 key
    static func sourceMediumTokens(_ profile: String?) -> [String] {
        switch profile {
        case "remux", "bluray", "uhdbd", "uhd8k", "8k", "8kbd": return ["blu-ray", "蓝光", "其它"]
        case "webdl", "webrip", "encode": return ["web", "网络", "其它"]
        case "hdtv": return ["broadcast", "广播", "电视", "其它"]
        case "dvd": return ["dvd", "其它"]
        default: return ["其它"]
        }
    }

    /// 质量档案 -> PeerGo「发布类型」选项 key
    static func releaseTypeTokens(_ profile: String?) -> [String] {
        switch profile {
        case "remux": return ["remux", "其它"]
        case "bluray", "uhdbd", "uhd8k", "8k", "8kbd": return ["full-disc", "remux", "其它"]
        case "webdl": return ["web-dl", "其它"]
        case "webrip": return ["webrip", "web-dl", "其它"]
        case "encode": return ["encode", "其它"]
        case "hdtv": return ["hdtv", "其它"]
        case "dvd": return ["dvdrip", "其它"]
        default: return ["其它"]
        }
    }

    /// 截图：源简介里的图片（不含海报），站点要求至少一张
    private func screenshotFiles(_ info: ReleaseInfo) throws
        -> [(data: Data, ext: String, mime: String)] {
        var urls = NexusPHPAdapter.screenshotURLs(from: info.descr, base: site.url)
        if urls.isEmpty, let p = NexusPHPAdapter.posterURL(from: info.descr, base: site.url) { urls = [p] }
        var out: [(Data, String, String)] = []
        for u in urls.prefix(4) {
            guard let resp = try? client.get(u, referer: site.url), resp.status < 400, resp.data.count > 1024 else { continue }
            let lower = u.lowercased()
            let ext = lower.contains(".png") ? "png" : (lower.contains(".webp") ? "webp" : "jpg")
            out.append((resp.data, ext, "image/" + (ext == "jpg" ? "jpeg" : ext)))
        }
        guard !out.isEmpty else {
            throw BoxSendError.badInput("\(site.name) 发种需要至少一张截图（源简介里没有可用图片）")
        }
        return out
    }

    private func description(_ info: ReleaseInfo) -> String {
        let html = NexusPHPAdapter.preprocessDescription(info.descr, base: site.url, dropScreenshots: false)
        var out = BBCode.fromHTML(html, base: URL(string: site.url))
        if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out = NexusPHPAdapter.fallbackDescr(info) }
        // 来源引用只认「批量转种」页手填的源站引用（可选项），官种不再自动加致谢
        return info.extraQuoteBBCode + out
    }

    private func save(_ kind: String, _ text: String) {
        guard let dir = debugDir else { return }
        let f = URL(fileURLWithPath: dir).appendingPathComponent("\(kind)-\(site.id)-\(Int(Date().timeIntervalSince1970)).html")
        try? text.data(using: .utf8)?.write(to: f)
    }
}
