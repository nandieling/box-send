import Foundation

/// Unit3D 家族 API 适配器（当前服务 M-Team 馒头）。
///
/// 馒头现网是 Spring 网关（api.m-team.cc）：一律 POST + `x-api-key` 头鉴权，
/// 响应 {code, message, data}，成功码是字符串 "0"（message=SUCCESS）；
/// 无效 Key -> {"code":1,"message":"key無效"}，缺凭证 -> {"code":401,...}。
/// 查询参数 `?api_key=` 已不被接受（一律 code=401），旧写法因此拿不到任何数据。
/// - 详情: POST /api/torrent/detail     （multipart: id）
/// - 种子: POST /api/torrent/genDlToken （multipart: id -> data 为一次性下载地址）
/// - 查重: POST /api/torrent/search     （json: pageNumber/pageSize/keyword）
/// - 发种: POST /api/torrent/createOredit  （multipart：file + 各字段；动画分类需 bangumi）
/// - Bangumi: POST /api/media/bangumi/search（multipart: keyword，站方代理的番组计划检索）
/// 注意：站方有频控（code=4「請求過於頻繁」），写入接口命中后会自动等待重试一次。
class Unit3DAdapter: SiteAdapter {
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

    // MARK: - API 基础

    private var apiBase: String {
        (override?.apiBase ?? site.url).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private var apiKey: String {
        site.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    /// 站方要求带 Origin（缺了会被 CORS 网关拒），x-api-key 为唯一鉴权方式
    private var apiHeaders: [String: String] {
        ["x-api-key": apiKey, "Accept": "application/json", "Origin": site.url]
    }
    private func guardKey() throws {
        guard !apiKey.isEmpty else {
            throw BoxSendError.badInput("\(site.name) 需配置 API Key（站点页「API Key」输入框，个人主页 -> 设置 -> API 中获取）")
        }
    }

    /// multipart 表单 POST：detail / genDlToken / createOredit 只吃 form-data，JSON 会返回「參數錯誤」
    @discardableResult
    private func apiFormRaw(_ path: String, _ fields: [HTTPClient.MultipartField],
                            files: [(name: String, filename: String, data: Data, mime: String)] = [],
                            referer: String? = nil) throws -> HTTPClient.Response {
        try guardKey()
        return try client.postMultipart(apiBase + path, fields: fields, files: files,
                                        referer: referer ?? site.url, extraHeaders: apiHeaders)
    }

    private func apiForm(_ path: String, _ fields: [String: String]) throws -> Any {
        let resp = try apiFormRaw(path, fields.map { HTTPClient.MultipartField($0.key, $0.value) })
        return try Self.unwrap(resp, url: apiBase + path, siteURL: site.url)
    }

    /// 站方频控（code=4「請求過於頻繁」）：等一会儿再试一次，别让批量任务白失败
    private func withThrottleRetry(_ body: () throws -> HTTPClient.Response) throws -> HTTPClient.Response {
        let first = try body()
        guard Self.isThrottled(first) else { return first }
        Thread.sleep(forTimeInterval: 5)
        return try body()
    }

    static func isThrottled(_ resp: HTTPClient.Response) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
              let msg = obj["message"] as? String else { return false }
        return msg.contains("過於頻繁") || msg.contains("过于频繁")
    }

    /// JSON POST
    private func apiJSON(_ path: String, _ object: [String: Any]) throws -> Any {
        try guardKey()
        let resp = try client.postJSON(apiBase + path, object: object, referer: site.url, extraHeaders: apiHeaders)
        return try Self.unwrap(resp, url: apiBase + path, siteURL: site.url)
    }

    private static func unwrap(_ resp: HTTPClient.Response, url: String, siteURL: String) throws -> Any {
        guard let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any] else {
            throw BoxSendError.http(status: resp.status, url: url,
                                    body: String(data: resp.data.prefix(200), encoding: .utf8) ?? "")
        }
        let code = CookieCheck.apiCode(obj) ?? resp.status
        let msg = (obj["message"] as? String) ?? ""
        // 只把「鉴权类」失败判成 API Key 失效：401/403、"key無效"、网关的"無效的請求"；
        // 业务报错（如"Bangumi 條目無效"）不能算在 Key 头上，否则会把用户引到错误的排查方向
        let keyIssue = resp.status == 401 || resp.status == 403 || code == 401 || code == 403
            || msg.contains("key無效") || msg.contains("key无效")
            || msg == "無效的請求" || msg == "无效的请求"
        if keyIssue { throw BoxSendError.apiKeyInvalid(siteURL) }
        guard code == 0 || msg.uppercased() == "SUCCESS" else {
            throw BoxSendError.http(status: code, url: url, body: msg.isEmpty ? "HTTP \(resp.status)" : msg)
        }
        return obj["data"] ?? NSNull()
    }

    /// 从详情页链接/下载地址取种子 id（/detail/123、/torrents/123、?id=123）
    static func torrentID(_ url: String) -> String? {
        for pat in ["/detail/(\\d+)", "/torrents/(\\d+)", "[?&]id=(\\d+)"] {
            if let v = HTMLUtil.group(url, pat, options: []) { return v }
        }
        return nil
    }

    /// 站方结构化字段（imdb/豆瓣为完整链接）中提取 id
    private static func idFromLink(_ link: Any?, _ pattern: String) -> String? {
        guard let link = link as? String, !link.isEmpty else { return nil }
        return HTMLUtil.group(link, pattern)
    }

    private static func rowID(_ row: [String: Any]) -> String? {
        if let s = row["id"] as? String, !s.isEmpty { return s }
        if let i = row["id"] as? Int { return String(i) }
        if let d = row["id"] as? Double { return String(Int(d)) }
        return nil
    }

    // MARK: - 详情解析

    func fetchDetail(detailURL: String) throws -> ReleaseInfo {
        guard let id = Self.torrentID(detailURL), Int(id) != nil else {
            throw BoxSendError.badInput("无法解析 \(site.name) 详情链接: \(detailURL)")
        }
        let data = try apiForm("/api/torrent/detail", ["id": id])
        guard let t = data as? [String: Any] else {
            throw BoxSendError.badInput("torrent/detail 无数据（种子不存在或已删除？id=\(id)）")
        }
        let name = (t["name"] as? String) ?? ""
        let smallDescr = (t["smallDescr"] as? String) ?? ""
        let descr = (t["descr"] as? String) ?? ""
        let mediaInfo = (t["mediainfo"] as? String) ?? ""
        var size: Int64? = nil
        if let s = t["size"] as? Int64 { size = s }
        else if let s = t["size"] as? Double { size = Int64(s) }
        else if let s = t["size"] as? String, let v = Int64(s) { size = v }
        // imdb / 豆瓣优先用站方结构化字段，回落到名称与正文
        let imdb = Self.idFromLink(t["imdb"], "(tt\\d{5,13})")
            ?? HTMLUtil.firstMatch(name + " " + descr, "tt\\d{5,13}")
        let douban = Self.idFromLink(t["douban"], "subject/(\\d+)")
            ?? HTMLUtil.group(descr, "douban\\.com/subject/(\\d+)")
        let catID = (t["category"] as? Int) ?? Int((t["category"] as? String) ?? "")
        let kind = Self.categoryKind(catID) ?? ReleaseKind.infer(from: name)
        // 站方标签（labelsNew: ["中字"]）比正文猜词可靠；副标题优先站方 smallDescr
        let labels = ((t["labelsNew"] as? [String]) ?? []).filter { !$0.isEmpty }
        let subtitleText = !smallDescr.isEmpty ? smallDescr
            : (labels.isEmpty ? Self.subtitle(from: descr) : labels.joined(separator: " "))
        var info = ReleaseInfo(
            siteID: site.id, detailURL: detailURL, name: name, descr: descr,
            imdb: imdb, douban: douban, size: size, kind: kind,
            torrentName: name + ".torrent",
            // 下载地址一次性有效，占位记录 id，下载时现取 genDlToken
            torrentURL: apiBase + "/api/torrent/genDlToken?id=" + id,
            isForbidReseed: false, subtitle: subtitleText,
            genre: "", mediainfo: mediaInfo, region: "",
            bangumi: (t["bangumi"] as? String) ?? "")
        if ["禁转", "禁止转载", "JZ"].contains(where: { name.contains($0) || descr.contains($0) }) {
            info.isForbidReseed = true
        }
        return info
    }

    // MARK: - 下载

    func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String) {
        try guardKey()
        guard let id = Self.torrentID(info.detailURL) ?? Self.torrentID(info.torrentURL) else {
            throw BoxSendError.badInput("无法解析 \(site.name) 种子 id：\(info.detailURL)")
        }
        guard let link = try apiForm("/api/torrent/genDlToken", ["id": id]) as? String,
              link.hasPrefix("http") else {
            throw BoxSendError.badInput("\(site.name) genDlToken 未返回下载地址（种子可能已被删除）")
        }
        let resp = try client.get(link, referer: info.detailURL)
        if resp.status == 401 || resp.status == 403 { throw BoxSendError.apiKeyInvalid(site.url) }
        if resp.status >= 400 {
            throw BoxSendError.http(status: resp.status, url: link,
                                    body: String(data: resp.data.prefix(200), encoding: .utf8) ?? "")
        }
        guard Bencode.infoHash(resp.data) != nil else {
            let head = String(data: resp.data.prefix(80), encoding: .utf8) ?? ""
            throw BoxSendError.badInput(".torrent 不是有效 bencode（\(resp.data.count) bytes，开头: \(head)），API Key 或种子可能失效")
        }
        return (resp.data, info.torrentName)
    }

    // MARK: - 查重

    func searchExists(_ info: ReleaseInfo) throws -> String? {
        try guardKey()
        // 名称搜索（imdb/豆瓣在馒头不一定录入，名称更可靠）
        let data = try apiJSON("/api/torrent/search",
                               ["pageNumber": 1, "pageSize": 50, "keyword": info.name])
        guard let page = data as? [String: Any], let rows = page["data"] as? [[String: Any]] else { return nil }
        let target = NexusPHPAdapter.normalizeSearchName(info.name)
        guard target.count >= 8 else { return nil }
        for row in rows {
            guard let n = row["name"] as? String else { continue }
            let cand = NexusPHPAdapter.normalizeSearchName(n)
            guard cand.count >= 8 else { continue }
            if cand.contains(target) || target.contains(cand) {
                return site.url + "detail/" + (Self.rowID(row) ?? "")
            }
        }
        return nil
    }

    // MARK: - 上传（转种）

    func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
        let fields = try uploadFields(info)
        let torrentName = Self.uploadFilename(info.name.isEmpty ? filename : info.name)
        let path = "/api/torrent/createOredit"
        let resp: HTTPClient.Response
        do {
            resp = try withThrottleRetry {
                try self.apiFormRaw(path, fields,
                                    files: [(name: "file", filename: torrentName,
                                             data: torrentData, mime: "application/x-bittorrent")],
                                    referer: site.url + "upload")
            }
        }
        // 站方对同 infohash 的兜底查重：算成功，但交给流水线按「已存在」处理
        if let msg = Self.apiMessage(resp), msg.contains("已存在") {
            return UploadOutcome(success: true, message: "站点提示已存在（\(msg)）",
                                 detailURL: try? searchExists(info), alreadyExists: true)
        }
        let data = try Self.unwrap(resp, url: apiBase + path, siteURL: site.url)
        let id = (data as? [String: Any]).flatMap { Self.rowID($0) } ?? ""
        return UploadOutcome(success: true, message: "发布成功",
                             detailURL: id.isEmpty ? nil : site.url + "detail/" + id)
    }

    func previewUploadFields(_ info: ReleaseInfo) throws -> [(String, String)] {
        var out: [(String, String)] = [("file", Self.uploadFilename(info.name))]
        out += try uploadFields(info).map { ($0.name, $0.value) }
        return out
    }

    /// 发种字段：站方必填 file/name/descr/category，动画分类另需 bangumi
    func uploadFields(_ info: ReleaseInfo) throws -> [HTTPClient.MultipartField] {
        try guardKey()
        let cat = Self.uploadCategory(for: info)
        var fields: [HTTPClient.MultipartField] = [
            .init("category", String(cat)),
            .init("name", Self.uploadTitle(info)),
            .init("descr", uploadDescr(info)),
            .init("scope", "NORMAL"),
            .init("anonymous", "false"),
        ]
        if !info.subtitle.isEmpty { fields.append(.init("smallDescr", String(info.subtitle.prefix(250)))) }
        if !info.mediainfo.isEmpty { fields.append(.init("mediainfo", info.mediainfo)) }
        if let imdb = info.imdb { fields.append(.init("imdb", Self.imdbLink(imdb))) }
        if let douban = info.douban { fields.append(.init("douban", Self.doubanLink(douban))) }
        let labels = Self.labels(for: info)
        if !labels.isEmpty { fields.append(.init("labelsNew", labels.joined(separator: ","))) }
        if Self.animeCategories.contains(cat) {
            guard let link = resolveBangumi(info) else {
                throw BoxSendError.badInput("\(site.name) 动画分类必须填 Bangumi 条目链接：按标题"
                    + "\(Bangumi.searchKeywords(from: info).prefix(2).joined(separator: "、"))"
                    + "检索番组计划无匹配条目，请到发种页手动填写")
            }
            fields.append(.init("bangumi", link))
        }
        return fields
    }

    /// 站方 media/bangumi/search 检索（发种页同一个数据源），失败不阻断发种
    func resolveBangumi(_ info: ReleaseInfo) -> String? {
        Bangumi.resolve(info) { keyword in
            guard let data = try? self.apiForm("/api/media/bangumi/search", ["keyword": keyword]),
                  let rows = data as? [[String: Any]] else { return [] }
            return rows.compactMap { Bangumi.Candidate(row: $0) }
        }?.link
    }

    // MARK: - 列表（尽力而为：搜索接口取最新）

    func fetchTorrentList() throws -> [ReleaseInfo] {
        try guardKey()
        let data = try apiJSON("/api/torrent/search", ["pageNumber": 1, "pageSize": 30])
        guard let page = data as? [String: Any], let rows = page["data"] as? [[String: Any]] else { return [] }
        var out: [ReleaseInfo] = []
        for row in rows {
            guard let n = row["name"] as? String, let tid = Self.rowID(row) else { continue }
            out.append(ReleaseInfo(siteID: site.id, detailURL: site.url + "detail/" + tid,
                                   name: n, kind: ReleaseKind.infer(from: n)))
        }
        return out
    }

    // MARK: - 分类映射（馒头站方分类编号；未收录的 id 交回名称推断）

    static func categoryKind(_ id: Int?) -> ReleaseKind? {
        guard let id else { return nil }
        switch id {
        case 401, 419, 420, 421, 439: return .movie             // 电影各档
        case 402, 403, 435, 438: return .series                  // 影剧/综艺
        case 404: return .documentary                            // 纪录
        case 405, 453: return .anime                             // 动画（453 为站方新增动画分类）
        case 406, 434, 442: return .music                        // 演唱/无损音乐/有声书
        case 407: return .sports                                 // 运动
        case 409: return .other                                  // Misc
        default: return nil
        }
    }

    /// 站方动画分类（发种页只有这两类要求 Bangumi 链接）
    static let animeCategories: Set<Int> = [405, 453]

    /// 发种分类：动画按源介质分「动画」/「动画-BluRay」
    static func uploadCategory(for info: ReleaseInfo) -> Int {
        let id = categoryID(for: info.kind)
        if id == 405 {
            let n = info.name.uppercased()
            if ["BLURAY", "BLU-RAY", "BDMV", "REMUX", "BDRIP", "BRRIP"].contains(where: { n.contains($0) }) {
                return 453
            }
        }
        return id
    }

    /// 站方标签（标签为自由文本，只提交能确定的规范标签）
    static func labels(for info: ReleaseInfo) -> [String] {
        let tags = QualityTokens.canonicalTags(info)
        var out: [String] = []
        if tags.contains("chinese_sub") { out.append("中字") }
        if tags.contains("forbid") { out.append("禁转") }
        if tags.contains("limited") { out.append("限转") }
        if tags.contains("diy") { out.append("DIY") }
        return out
    }

    /// 主标题：源站详情页主标题（点分文件名换成空格，站方不允许下划线）
    static func uploadTitle(_ info: ReleaseInfo) -> String {
        info.name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func imdbLink(_ s: String) -> String {
        s.hasPrefix("http") ? s : "https://www.imdb.com/title/\(s)/"
    }

    static func doubanLink(_ s: String) -> String {
        s.hasPrefix("http") ? s : "https://movie.douban.com/subject/\(s)/"
    }

    /// 发种文件名：与种子的 info.name 对齐，去掉站方不接受的字符
    static func uploadFilename(_ base: String) -> String {
        let cleaned = base.replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "boxsend" : cleaned) + ".torrent"
    }

    /// 简介：站方为 Markdown/HTML 混排编辑器，沿用源站 HTML（图片绝对化、去源站链接）
    func uploadDescr(_ info: ReleaseInfo) -> String {
        let html = Self.buildDescr(info.descr, sourceHost: info.detailURL)
        if !html.isEmpty { return info.extraQuoteHTML + html }
        return info.extraQuoteHTML + "转载自\(info.sourceName.isEmpty ? info.siteID : info.sourceName)，感谢发布者。"
    }

    static func apiMessage(_ resp: HTTPClient.Response) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any] else { return nil }
        return obj["message"] as? String
    }

    static func categoryID(for kind: ReleaseKind?) -> Int {
        switch kind {
        case .movie: return 421
        case .series: return 402
        case .anime: return 405
        case .documentary: return 404
        case .music: return 434
        case .tvshow: return 402
        case .sports: return 407
        case .other, nil: return 409
        }
    }

    /// 副标题：简介中"字幕/中字"行（尽力而为）
    static func subtitle(from descr: String) -> String {
        let text = HTMLUtil.stripTags(descr)
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.contains("中字") || l.contains("简中") || l.contains("繁中") || l.contains("中英")
                || l.contains("日字") || l.contains("韩字") || l.contains("字幕") {
                return String(l.prefix(40))
            }
        }
        return ""
    }

    /// 简介清洗：去脚本/样式、源站链接转文本、图片绝对化、压缩空行（Unit3D 用 HTML 简介）
    static func buildDescr(_ html: String, sourceHost: String) -> String {
        var s = html
        s = HTMLUtil.replaceMatches(s, "<(script|style)[^>]*>.*?</\\1>",
                           options: [.dotMatchesLineSeparators, .caseInsensitive]) { _ in "" }
        if let host = try? URL(string: sourceHost)?.host() {
            let hostPat = NSRegularExpression.escapedPattern(for: host.split(separator: ".").joined(separator: "\\.?"))
            let re = try! NSRegularExpression(pattern: "<a\\s[^>]*href=[\"'](?:https?://)?(?:www\\.)?\(hostPat)(?:/[^\"']*)?[\"'][^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators, .caseInsensitive])
            s = HTMLUtil.replaceMatches(s, re.pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) { m in
                HTMLUtil.stripTags(String(s[Range(m.range(at: 1), in: s)!]))
            }
        }
        if let base = URL(string: sourceHost) {
            let imgRe = try! NSRegularExpression(pattern: "<img\\s[^>]*src=[\"']([^\"']+)[\"']", options: .caseInsensitive)
            s = HTMLUtil.replaceMatches(s, imgRe.pattern, options: .caseInsensitive) { m in
                let orig = String(s[Range(m.range, in: s)!])
                let src = String(s[Range(m.range(at: 1), in: s)!])
                guard !src.hasPrefix("http") else { return orig }
                let abs = base.absoluteString + (src.hasPrefix("/") ? src : "/" + src)
                return orig.replacingOccurrences(of: "src=\"\(src)\"", with: "src=\"\(abs)\"")
            }
        }
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
