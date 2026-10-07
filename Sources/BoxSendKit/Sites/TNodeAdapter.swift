import Foundation

/// TNode 框架适配器（ZHUQUE 等）：SPA + REST API。
/// - GET  /api/torrent/option            选项列表（id 段: 1xx 视频编码 / 3xx 媒介 / 4xx 分辨率 / 5xx 分类 / 6xx 标签）
/// - GET  /api/torrent/info?id=N         详情 {content: TMDB, torrent: {...}}
/// - GET  /api/torrent/download/N/key    .torrent 直链
/// - POST /api/torrent/search            JSON 搜索（查重）
/// - POST /api/torrent/upload            multipart 发种（需 x-csrf-token 头）
final class TNodeAdapter: SiteAdapter {
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

    // MARK: - CSRF / 选项

    private var csrfCache: String?
    private var csrfFetched = false

    func csrfToken() throws -> String {
        if let c = csrfCache { return c }
        guard !csrfFetched else {
            throw BoxSendError.badInput("\(site.id) 无法获取 CSRF token（页面结构异常？）")
        }
        csrfFetched = true
        let html = String(data: try client.get(site.url, referer: site.url).data, encoding: .utf8) ?? ""
        // 取 content 捕获组（firstMatch 返回完整匹配串会带 name= 前缀，导致 API 400）
        guard let m = HTMLUtil.group(html, "name=[\"']x-csrf-token[\"']\\s+content=[\"']([^\"']+)[\"']") else {
            throw BoxSendError.badInput("\(site.id) 页面缺少 x-csrf-token（cookie 失效或页面结构变化）")
        }
        csrfCache = m
        return m
    }

    private func headers() throws -> [String: String] {
        ["x-csrf-token": try csrfToken(), "x-requested-with": "XMLHttpRequest"]
    }

    struct Opt: Decodable { let id: Int; let name: String }
    private struct OptResp: Decodable {
        struct D: Decodable { let option: [Opt] }
        let status: Int
        let data: D
    }

    enum Group: String { case videoCoding, medium, resolution, category, tags }
    private let groupRanges: [(Group, Int, Int)] = [
        (.videoCoding, 100, 200), (.medium, 300, 400), (.resolution, 400, 500),
        (.category, 500, 600), (.tags, 600, 700),
    ]

    var optionsCache: [Group: [Opt]]?   // internal 供测试预置

    func fetchOptions() throws -> [Group: [Opt]] {
        if let c = optionsCache { return c }
        let resp = try client.get(site.url + "api/torrent/option", referer: site.url, extraHeaders: try headers())
        if resp.status == 400 || resp.status == 401 || resp.status == 403 {
            throw BoxSendError.cookieExpired(site.url)
        }
        if resp.status >= 400 {
            throw BoxSendError.http(status: resp.status, url: site.url + "api/torrent/option",
                                    body: String(data: resp.data.prefix(200), encoding: .utf8) ?? "")
        }
        let j = try JSONDecoder().decode(OptResp.self, from: resp.data)
        var groups: [Group: [Opt]] = [:]
        for (g, lo, hi) in groupRanges {
            groups[g] = j.data.option.filter { $0.id > lo && $0.id < hi }
        }
        optionsCache = groups
        return groups
    }

    private func optionID(_ group: Group, names: [String]) throws -> Int? {
        let opts = try fetchOptions()[group] ?? []
        for n in names {
            if let hit = opts.first(where: { $0.name.lowercased() == n.lowercased() }) { return hit.id }
        }
        if let fb = names.last, let hit = opts.first(where: { $0.name.lowercased().contains(fb.lowercased()) }) {
            return hit.id
        }
        return nil
    }

    // MARK: - 字段映射

    private func mediumOptionID(_ info: ReleaseInfo) throws -> Int? {
        let m = QualityTokens.medium(from: info.name, kind: info.kind)
        let diy = QualityTokens.canonicalTags(info).contains("diy")
        switch m {
        case "remux":
            return try optionID(.medium, names: ["Remux", "Other"])
        case "uhdbd", "uhdbd8k":
            return try optionID(.medium, names: diy ? ["UHD Blu-ray DIY", "Other"] : ["UHD Blu-ray", "Other"])
        case "uhd8k", "uhdtv":
            return try optionID(.medium, names: ["UHDTV", "UHD Blu-ray", "Other"])
        case "bluray":
            return try optionID(.medium, names: diy ? ["Blu-ray DIY", "Other"] : ["Blu-ray", "Other"])
        case "webdl", "webrip":
            return try optionID(.medium, names: ["WEB-DL", "Other"])
        case "hdtv":
            return try optionID(.medium, names: ["HDTV", "Other"])
        case "encode":
            return try optionID(.medium, names: ["Encode", "Other"])
        default:
            return try optionID(.medium, names: ["Other"])
        }
    }

    private func videoCodingOptionID(_ info: ReleaseInfo) throws -> Int? {
        switch QualityTokens.codec(from: info.name) {
        case "avc":
            return try optionID(.videoCoding, names: ["H264", "Other"])
        case "hevc":
            return try optionID(.videoCoding, names: ["H265", "Other"])
        default:
            return try optionID(.videoCoding, names: ["Other"])
        }
    }

    private func resolutionOptionID(_ info: ReleaseInfo) throws -> Int? {
        switch QualityTokens.standard(from: info.name) {
        case "720p":
            return try optionID(.resolution, names: ["720p", "Other"])
        case "1080i":
            return try optionID(.resolution, names: ["1080i", "Other"])
        case "1080p":
            return try optionID(.resolution, names: ["1080p", "Other"])
        case "2160p", "8k":
            return try optionID(.resolution, names: ["2160p", "Other"])
        default:
            return try optionID(.resolution, names: ["Other"])
        }
    }

    private func categoryOptionID(_ info: ReleaseInfo) throws -> Int? {
        let opts = try fetchOptions()[.category] ?? []
        let labels: [String]
        switch info.kind ?? .other {
        case .movie: labels = ["电影"]
        case .series: labels = ["剧集"]
        case .anime: labels = ["动漫", "动画"]
        case .tvshow: labels = ["节目", "综艺"]
        default: labels = ["其他", "其它"]
        }
        for l in labels {
            if let hit = opts.first(where: { $0.name.contains(l) }) { return hit.id }
        }
        return opts.first(where: { $0.name.contains("其他") || $0.name.contains("其它") })?.id ?? opts.first?.id
    }

    private func tagIDs(_ info: ReleaseInfo) throws -> [Int] {
        let opts = try fetchOptions()[.tags] ?? []
        func id(_ kw: String) -> Int? {
            opts.first(where: { $0.name.lowercased().contains(kw.lowercased()) })?.id
        }
        var ids: [Int] = []
        let canon = Set(QualityTokens.canonicalTags(info))
        if canon.contains("chinese_sub"), let v = id("中字") { ids.append(v) }
        if canon.contains("forbid") || info.isForbidReseed, let v = id("禁转") { ids.append(v) }
        if canon.contains("dovi"), let v = id("杜比视界") ?? id("dovi") { ids.append(v) }
        if canon.contains("hdr10") || canon.contains("hdr10plus"), let v = id("hdr10") { ids.append(v) }
        // TNode 剧集惯例：整季 -> 完结；单集 -> 分集
        let n = info.name
        if let re = try? NSRegularExpression(pattern: "全\\s*\\d+\\s*集|Full\\s+Season|Complete\\s+Season", options: .caseInsensitive),
           re.firstMatch(in: n, options: [], range: NSRange(n.startIndex..., in: n)) != nil,
           let v = id("完结") {
            ids.append(v)
        }
        if let re = try? NSRegularExpression(pattern: "S\\d{1,2}[ ._-]?E\\d{1,4}|E\\d{2,4}\\b|第\\s*\\d+\\s*集", options: .caseInsensitive),
           re.firstMatch(in: n, options: [], range: NSRange(n.startIndex..., in: n)) != nil,
           let v = id("分集") {
            ids.append(v)
        }
        return ids
    }

    /// 从简介 HTML 提取截图 URL（相对路径按 base 绝对化）
    static func imageURLs(fromHTML html: String, base: URL?, limit: Int = 10) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for tag in HTMLUtil.allMatches(html, "<img[^>]*src=[\"'][^\"']+[\"]", options: .caseInsensitive) {
            guard let src = HTMLUtil.group(tag, #"src=["']([^"']+)["']"#, group: 1) else { continue }
            var u = src
            if !u.lowercased().hasPrefix("http") {
                if let base { u = HTMLUtil.resolveURL(u, against: base) }
            }
            if seen.insert(u).inserted { out.append(u) }
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: - TMDB

    private struct TmdbResp: Decodable {
        struct Item: Decodable { let id: Int; let media_type: String? }
        let status: Int
        let data: [Item]
    }

    func findTmdb(imdb: String) throws -> (type: String, id: Int)? {
        let resp = try client.get(site.url + "api/tmdb/findByImdb/\(imdb)",
                                  referer: site.url, extraHeaders: try headers())
        guard resp.status == 200,
              let j = try? JSONDecoder().decode(TmdbResp.self, from: resp.data),
              let first = j.data.first else { return nil }
        return (first.media_type == "tv" ? "1" : "0", first.id)
    }

    // MARK: - 列表 / 详情 / 下载

    func fetchTorrentList() throws -> [ReleaseInfo] {
        throw BoxSendError.notImplemented("TNode \(site.id) 列表（当前作目标站/源站详情页使用）")
    }

    private struct InfoResp: Decodable {
        struct Content: Decodable { let imdb_id: String? }
        struct Torrent: Decodable {
            let id: Int
            let name: String
            let title: String
            let subtitle: String
            let size: Int64
            let note: String
            let screenshot: String
            let mediainfo: String
            let category: Int
            let tags: [Int]
            let torrentKey: String
        }
        struct D: Decodable { let content: Content; let torrent: Torrent }
        let status: Int
        let data: D
    }

    /// TNode 标签 id 602 = 禁转（TNode 标准段）
    private let forbidTagID = 602

    static func kindFromCategory(_ id: Int, name: String) -> ReleaseKind {
        switch id {
        case 501: return .movie
        case 502: return .series
        case 503: return .anime
        case 504: return .tvshow
        default: return ReleaseKind.infer(from: name)
        }
    }

    func fetchDetail(detailURL: String) throws -> ReleaseInfo {
        guard let id = Self.torrentID(fromDetail: detailURL) else {
            throw BoxSendError.badInput("无法解析 TNode 详情链接: \(detailURL)")
        }
        let resp = try client.get(site.url + "api/torrent/info?id=\(id)",
                                  referer: detailURL, extraHeaders: try headers())
        if resp.status == 400 || resp.status == 401 || resp.status == 403 {
            throw BoxSendError.cookieExpired(site.url)
        }
        guard resp.status == 200 else {
            throw BoxSendError.http(status: resp.status, url: detailURL,
                                    body: String(data: resp.data.prefix(200), encoding: .utf8) ?? "")
        }
        return try parseDetail(resp.data, detailURL: detailURL)
    }

    /// 详情链接里的种子 id（SPA 路由 /torrent/info/<id>）
    static func torrentID(fromDetail detailURL: String) -> String? {
        HTMLUtil.group(detailURL, "/torrent/info/(\\d+)", group: 1)
    }

    /// 纯解析（供测试）
    func parseDetail(_ data: Data, detailURL: String) throws -> ReleaseInfo {
        let j = try JSONDecoder().decode(InfoResp.self, from: data)
        let t = j.data.torrent
        var descr = t.screenshot
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "<img src=\"\($0)\" />" }
            .joined(separator: "<br />")
        if !t.note.isEmpty {
            descr += "<br /><br />" + t.note
        }
        return ReleaseInfo(siteID: site.id, detailURL: detailURL, name: t.title, descr: descr,
                           imdb: j.data.content.imdb_id, douban: nil, size: t.size,
                           kind: Self.kindFromCategory(t.category, name: t.title),
                           torrentName: t.name,
                           torrentURL: site.url + "api/torrent/download/\(t.id)/\(t.torrentKey)",
                           isForbidReseed: t.tags.contains(forbidTagID),
                           subtitle: t.subtitle, genre: "", mediainfo: t.mediainfo, region: "")
    }

    func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String) {
        let resp = try client.get(info.torrentURL, referer: info.detailURL)
        if resp.status == 404 || resp.status == 403 {
            throw BoxSendError.cookieExpired(site.url)
        }
        if resp.status >= 400 {
            throw BoxSendError.http(status: resp.status, url: info.torrentURL,
                                    body: String(data: resp.data.prefix(200), encoding: .utf8) ?? "")
        }
        guard Bencode.infoHash(resp.data) != nil else {
            let head = String(data: resp.data.prefix(80), encoding: .utf8) ?? ""
            throw BoxSendError.badInput(".torrent 不是有效 bencode（\(resp.data.count) bytes，开头: \(head)），可能 cookie 失效或下载链接错误: \(info.torrentURL)")
        }
        return (resp.data, info.torrentName)
    }

    // MARK: - 查重

    func searchExists(_ info: ReleaseInfo) throws -> String? {
        // 朱雀检索按中文名命中，用发布名查通常为空，再用中文段查一次
        for kw in Self.searchKeywords(info) {
            if let hit = try searchExists(info, keyword: kw) { return hit }
        }
        return nil
    }

    /// 检索词：发布名 + 副标题/简介里的中文段（取最长的几段）
    static func searchKeywords(_ info: ReleaseInfo) -> [String] {
        var out: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count >= 3, !out.contains(t) { out.append(t) }
        }
        add(info.name)
        let cjk = CharacterSet(charactersIn: "\u{4e00}"..."\u{9fff}")
        func runs(_ text: String, maxLen: Int) -> [String] {
            text.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.rangeOfCharacter(from: cjk) != nil && $0.count <= maxLen }
        }
        // 副标题就是中文片名；简介里只取短词段（长段落检索不命中）
        for r in runs(info.subtitle, maxLen: 20) { add(r) }
        for r in Array(runs(HTMLUtil.stripTags(info.descr), maxLen: 12).prefix(3)) { add(r) }
        return out
    }

    private func searchExists(_ info: ReleaseInfo, keyword: String) throws -> String? {
        let resp = try client.postJSON(site.url + "api/torrent/search",
                                       object: ["keyword": keyword, "page": 0, "size": 20],
                                       referer: site.url, extraHeaders: try headers())
        guard resp.status == 200 else {
            if resp.status == 400 || resp.status == 401 || resp.status == 403 {
                throw BoxSendError.cookieExpired(site.url)
            }
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
              let data = obj["data"] as? [String: Any],
              let tmdbs = data["tmdbs"] as? [[String: Any]] else { return nil }
        let target = NexusPHPAdapter.normalizeSearchName(info.name)
        guard target.count >= 8 else { return nil }
        for tm in tmdbs {
            guard let torrents = tm["torrents"] as? [[String: Any]] else { continue }
            for t in torrents {
                guard let title = t["title"] as? String, let id = t["id"] as? Int else { continue }
                // 归一化后相等或互相包含（对方标题常多带季号/年份等零碎）
                let n = NexusPHPAdapter.normalizeSearchName(title)
                let shorter = min(n.count, target.count), longer = max(n.count, target.count)
                if n == target || (shorter >= 8 && shorter * 10 >= longer * 7
                                    && (target.contains(n) || n.contains(target))) {
                    return site.url + "torrent/info/\(id)"
                }
            }
        }
        return nil
    }

    // MARK: - 上传

    /// TNode 副标题必填且要求含中文名；源站无副标题时取简介首行兜底
    static func fallbackSubtitle(_ info: ReleaseInfo) -> String {
        let plain = HTMLUtil.stripTags(info.descr)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .first ?? ""
        let t = String(plain.prefix(120))
        return t.isEmpty ? info.name : t
    }

    func buildUploadFields(_ info: ReleaseInfo) throws -> [HTTPClient.MultipartField] {
        var fields: [HTTPClient.MultipartField] = []
        func setField(_ name: String, _ value: String) {
            fields.removeAll { $0.name == name }
            fields.append(.init(name, value))
        }
        setField("title", info.name)
        setField("subtitle", info.subtitle.isEmpty ? Self.fallbackSubtitle(info) : info.subtitle)
        if let v = try categoryOptionID(info) { setField("category", String(v)) }
        if let v = try mediumOptionID(info) { setField("medium", String(v)) }
        if let v = try videoCodingOptionID(info) { setField("videoCoding", String(v)) }
        if let v = try resolutionOptionID(info) { setField("resolution", String(v)) }
        setField("tags", try tagIDs(info).map(String.init).joined(separator: ","))
        setField("anonymous", "true")
        setField("confirm", "true")
        setField("zwex", "0")
        if let imdb = info.imdb, !imdb.isEmpty, let tmdb = try findTmdb(imdb: imdb) {
            setField("tmdbtype", tmdb.type)
            setField("tmdbid", String(tmdb.id))
        }
        setField("screenshot",
                 Self.imageURLs(fromHTML: info.descr, base: URL(string: info.detailURL))
                     .joined(separator: "\n"))
        setField("mediainfo", info.mediainfo)
        var note = (info.extraQuoteText.isEmpty ? "" : info.extraQuoteText + "\n")
            + "转载自: \(info.detailURL)"
        if let imdb = info.imdb { note += "\nIMDb: https://www.imdb.com/title/\(imdb)/" }
        setField("note", note)
        return fields
    }

    func previewUploadFields(_ info: ReleaseInfo) throws -> [(String, String)] {
        try buildUploadFields(info).map { ($0.name, $0.value) }
    }

    private func extractErrorMessage(body: String, status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: body.data(using: .utf8) ?? Data()) as? [String: Any] {
            if let msg = obj["message"] as? String, !msg.isEmpty { return "HTTP \(status): \(msg)" }
            if let code = obj["code"] as? String, !code.isEmpty { return "HTTP \(status) [\(code)]" }
        }
        return "HTTP \(status) 未识别的返回: \(String(body.prefix(160)))"
    }

    private func dumpDebugBody(_ body: String) -> String? {
        guard let root = debugDir else { return nil }
        let dir = (root as NSString).appendingPathComponent("debug")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("upload-\(site.id)-\(Int(Date().timeIntervalSince1970)).json")
        if let data = body.data(using: .utf8), (try? data.write(to: URL(fileURLWithPath: path))) != nil {
            return path
        }
        return nil
    }

    /// 站点自行判定「该种子已上传」（HTTP 400 TORRENT_ALREADY_UPLOAD）：算已存在，不算失败
    static func isAlreadyUploaded(status: Int, body: String) -> Bool {
        status == 400 && body.contains("TORRENT_ALREADY_UPLOAD")
    }

    func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
        let createAction = site.url + "torrent/upload"
        let fields = try buildUploadFields(info)
        let resp = try client.postMultipart(
            site.url + "api/torrent/upload",
            fields: fields,
            files: [(name: "torrent", filename: filename, data: torrentData, mime: "application/x-bittorrent")],
            referer: createAction,
            extraHeaders: (try? headers()) ?? [:]
        )
        let body = String(data: resp.data, encoding: .utf8) ?? ""
        // 站点自己判定「该种子已上传」（HTTP 400 TORRENT_ALREADY_UPLOAD）：
        // 算已存在，回填已有种子链接以便照常推送本站 .torrent
        if Self.isAlreadyUploaded(status: resp.status, body: body) {
            return UploadOutcome(success: true, message: "站点已存在该种子（查重兜底命中）",
                                 detailURL: nil, alreadyExists: true)
        }
        if let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
           (obj["status"] as? Int) == 200,
           let data = obj["data"] as? [String: Any],
           let id = data["id"] as? Int {
            let code = ((data["code"] as? String) ?? (obj["code"] as? String) ?? "").lowercased()
            if code.contains("exist") {
                return UploadOutcome(success: true, message: "站点已存在该种子（查重兜底命中）", detailURL: nil)
            }
            return UploadOutcome(success: true, message: "发布成功",
                                 detailURL: site.url + "torrent/info/\(id)")
        }
        var errMsg = extractErrorMessage(body: body, status: resp.status)
        if let p = dumpDebugBody(body) { errMsg += "（响应已存 \(p)）" }
        return UploadOutcome(success: false, message: errMsg, detailURL: nil)
    }
}
