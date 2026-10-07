import Foundation

/// YemaPT 框架适配器（www.yemapt.org）：umi.js SPA + REST API。
/// - GET  /api/torrent/fetchUploadOptions          选项列表（分类树 / 媒介 / 分辨率 / 编码 / 音轨 / 地区 / 制作组 / 标签）
/// - GET  /api/torrent/fetchTorrentDetail?id=N     详情（longDesc 为 Markdown）
/// - GET  /api/torrent/download?id=N               .torrent 直链
/// - GET  /api/torrent/findImdbTorrentList?imdbId=ttN   IMDb 种子列表（查重）
/// - POST /api/torrent/existTorrentWithPiecesHash  {piecesHash: 40位hex} -> 已存在种子 id
/// - POST /api/torrent/addTorrent                  multipart 发种（字段名与 SPA 表单一致）
final class YemaPTAdapter: SiteAdapter {
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

    // MARK: - 选项

    struct UpOpt: Decodable { let label: String; let value: String }
    struct CatOpt: Decodable {
        let key: String?
        let label: String
        let value: Int
        let options: [CatOpt]?
    }
    struct UploadConfig: Decodable {
        let dayUploadMax: Int?
        let uploadUserAnonymousEnable: Bool?
        let defaultUploadUserAnonymous: String?
        let hrSetPunishEnable: Bool?
    }
    struct OptResp: Decodable {
        struct D: Decodable {
            let categoryOptions: [CatOpt]?
            let mediumOptions: [UpOpt]?
            let standardOptions: [UpOpt]?
            let codecOptions: [UpOpt]?
            let audioCodecOptions: [UpOpt]?
            let regionOptions: [UpOpt]?
            let teamOptions: [UpOpt]?
            let tagOptions: [UpOpt]?
            let uploadConfig: UploadConfig?
        }
        let success: Bool
        let data: D
    }

    var optionsCache: OptResp.D?   // internal 供测试预置

    func fetchOptions() throws -> OptResp.D {
        if let c = optionsCache { return c }
        let resp = try client.get(site.url + "api/torrent/fetchUploadOptions", referer: site.url)
        if resp.status == 401 || resp.status == 403 {
            throw BoxSendError.cookieExpired(site.url)
        }
        if resp.status >= 400 {
            throw BoxSendError.http(status: resp.status, url: site.url + "api/torrent/fetchUploadOptions",
                                    body: String(data: resp.data.prefix(200), encoding: .utf8) ?? "")
        }
        guard let j = try? JSONDecoder().decode(OptResp.self, from: resp.data), j.success else {
            throw BoxSendError.badInput("\(site.id) fetchUploadOptions 返回异常: \(String(data: resp.data.prefix(200), encoding: .utf8) ?? "")")
        }
        optionsCache = j.data
        return j.data
    }

    private func flattenCategories(_ cats: [CatOpt]) -> [CatOpt] {
        var out: [CatOpt] = []
        for c in cats {
            if let sub = c.options, !sub.isEmpty { out.append(contentsOf: sub) }
        }
        return out
    }

    private func optValue(_ opts: [UpOpt], names: [String]) -> String? {
        for n in names {
            if let hit = opts.first(where: { $0.label.lowercased() == n.lowercased() }) { return hit.value }
        }
        if let fb = names.last, let hit = opts.first(where: { $0.label.lowercased().contains(fb.lowercased()) }) {
            return hit.value
        }
        return nil
    }

    // MARK: - 字段映射

    private func categoryId(_ info: ReleaseInfo) throws -> Int? {
        let cats = flattenCategories(try fetchOptions().categoryOptions ?? [])
        let labels: [String]
        switch info.kind ?? .other {
        case .movie: labels = ["电影"]
        case .series: labels = ["剧集"]
        case .anime: labels = ["动漫"]
        case .tvshow: labels = ["综艺"]
        case .documentary: labels = ["纪录片"]
        case .music: labels = ["音乐", "其他", "其它"]
        case .sports: labels = ["体育"]
        case .other: labels = ["其他", "其它"]
        }
        for l in labels {
            if let hit = cats.first(where: { $0.label == l || $0.label.contains(l) }) { return hit.value }
        }
        return cats.first(where: { $0.label.contains("其他") || $0.label.contains("其它") })?.value
    }

    private func mediumValue(_ info: ReleaseInfo) throws -> String? {
        let opts = try fetchOptions().mediumOptions ?? []
        let m = QualityTokens.medium(from: info.name, kind: info.kind) ?? "encode"
        switch m {
        case "remux": return optValue(opts, names: ["Remux"])
        case "uhdbd", "uhd": return optValue(opts, names: ["Blu-ray UHD (4K Complete)", "Blu-ray UHD"])
        case "uhdbd8k", "uhd8k": return optValue(opts, names: ["Blu-ray UHD (4K Complete)", "Other"])
        case "bluray": return optValue(opts, names: ["Blu-ray (1080p Complete)", "Blu-ray"])
        case "webdl", "webrip": return optValue(opts, names: ["Web-DL/WebRip", "Web-DL"])
        case "hdtv": return optValue(opts, names: ["HDTV/TV Cap", "HDTV"])
        case "dvd": return optValue(opts, names: ["DVD (Complete/ISO)", "DVD"])
        case "track": return optValue(opts, names: ["Audio CD/Vinyl", "AudioCD"])
        default: return optValue(opts, names: ["Rip/Encode", "Encode"])
        }
    }

    private func standardValue(_ info: ReleaseInfo) throws -> String? {
        let opts = try fetchOptions().standardOptions ?? []
        switch QualityTokens.standard(from: info.name) {
        case "720p": return optValue(opts, names: ["720p"])
        case "1080i": return optValue(opts, names: ["1080i"])
        case "1080p": return optValue(opts, names: ["1080p"])
        case "2160p": return optValue(opts, names: ["4K", "2160p"])
        case "8k": return optValue(opts, names: ["8K", "8k"])
        case "sd": return optValue(opts, names: ["SD"])
        default: return nil
        }
    }

    private func codecValue(_ info: ReleaseInfo) throws -> String? {
        let opts = try fetchOptions().codecOptions ?? []
        switch QualityTokens.codec(from: info.name) {
        case "avc": return optValue(opts, names: ["H.264/AVC", "H264", "H.264"])
        case "hevc": return optValue(opts, names: ["H.265/HEVC", "H265", "H.265"])
        case "vc1": return optValue(opts, names: ["VC-1"])
        case "xvid": return optValue(opts, names: ["Xvid"])
        case "mpeg2": return optValue(opts, names: ["MPEG-2", "MPEG2"])
        case "av1": return optValue(opts, names: ["AV1"])
        default: return nil
        }
    }

    private func audioCodecValue(_ info: ReleaseInfo) throws -> String? {
        let opts = try fetchOptions().audioCodecOptions ?? []
        switch QualityTokens.audio(from: info.name) {
        case "dtsma": return optValue(opts, names: ["DTS-HDMA", "DTS-HD MA"])
        case "dtsbr": return optValue(opts, names: ["DTS"])
        case "dtsc": return optValue(opts, names: ["DTS-X", "Other"])
        case "truehd atmos": return optValue(opts, names: ["TrueHD Atmos", "TrueHDAtmos"])
        case "truehd": return optValue(opts, names: ["TrueHD"])
        case "eac3 atmos": return optValue(opts, names: ["E-AC3 Atmos", "EAC3Atmos"])
        case "eac3": return optValue(opts, names: ["EAC3", "E-AC3"])
        case "ac3": return optValue(opts, names: ["AC3", "AC-3"])
        case "dts": return optValue(opts, names: ["DTS"])
        case "flac": return optValue(opts, names: ["FLAC"])
        case "ape": return optValue(opts, names: ["APE"])
        case "aac", "m4a": return optValue(opts, names: ["AAC"])
        case "mp3": return optValue(opts, names: ["MP3"])
        case "opus": return optValue(opts, names: ["Opus"])
        case "pcm", "wav": return optValue(opts, names: ["LPCM"])
        default: return nil
        }
    }

    /// 地区多选（站点上限 3）
    private func regionValues(_ info: ReleaseInfo) throws -> [String] {
        let opts = try fetchOptions().regionOptions ?? []
        let r = info.region
        guard !r.isEmpty else { return [] }
        var out: [String] = []
        func add(_ kw: String, _ label: String) {
            guard out.count < 3, !out.contains(label) else { return }
            if let v = opts.first(where: { $0.label.lowercased().hasPrefix(kw.lowercased()) })?.value {
                out.append(v)
            }
        }
        if r.contains("中国") && !r.contains("香港") && !r.contains("台湾") { add("CN", "CN") }
        if r.contains("香港") || r.contains("HK") { add("HK", "HK/CN") }
        if r.contains("台湾") || r.contains("TW") { add("TW", "TW/CN") }
        if r.contains("美国") || r.contains("USA") || r.contains(" US") || r.hasSuffix("US") { add("US", "US") }
        if r.contains("日本") || r.contains("Japan") { add("JP", "JP") }
        if r.contains("韩国") || r.contains("Korea") { add("KR", "KR") }
        if r.contains("英国") || r.contains("欧洲") || r.contains("Germany") || r.contains("France") { add("EU", "EU") }
        if out.isEmpty { add("Other", "Other") }
        return out
    }

    private func teamValue(_ info: ReleaseInfo) throws -> String? {
        let opts = try fetchOptions().teamOptions ?? []
        return opts.first(where: { $0.label.lowercased().contains("other") })?.value
    }

    private func tagValues(_ info: ReleaseInfo) throws -> [String] {
        let opts = try fetchOptions().tagOptions ?? []
        func v(_ kw: String) -> String? {
            opts.first(where: { $0.label.lowercased().contains(kw.lowercased()) })?.value
        }
        var out: [String] = []
        let canon = Set(QualityTokens.canonicalTags(info))
        if canon.contains("forbid") || info.isForbidReseed, let x = v("禁转") { out.append(x) }
        if canon.contains("chinese_sub"), let x = v("中字") { out.append(x) }
        if canon.contains("dovi"), let x = v("杜比视界") { out.append(x) }
        if canon.contains("hdr10") || canon.contains("hdr10plus"), let x = v("HDR10") { out.append(x) }
        if canon.contains("diy"), let x = v("DIY") { out.append(x) }
        if canon.contains("atmos"), let x = v("Atmos") { out.append(x) }
        if canon.contains("dtsx"), let x = v("DTS-X") { out.append(x) }
        // 剧集整季 -> 完结
        let n = info.name
        if info.kind == .series,
           let re = try? NSRegularExpression(pattern: "全\\s*\\d+\\s*集|Full\\s+Season|Complete\\s+Season", options: .caseInsensitive),
           re.firstMatch(in: n, options: [], range: NSRange(n.startIndex..., in: n)) != nil,
           let x = v("完结") {
            out.append(x)
        }
        return out
    }

    /// 剧集季数（Sxx）
    static func season(from name: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: "S(\\d{1,2})(?![0-9])", options: .caseInsensitive) else { return nil }
        let m = re.firstMatch(in: name, options: [], range: NSRange(name.startIndex..., in: name))
        guard let m, let r = Range(m.range(at: 1), in: name) else { return nil }
        guard let v = Int(String(name[r])), v <= 100 else { return nil }
        return v
    }

    // MARK: - 列表 / 详情 / 下载

    func fetchTorrentList() throws -> [ReleaseInfo] {
        throw BoxSendError.notImplemented("YemaPT \(site.id) 列表（当前作目标站/源站详情页使用）")
    }

    private struct DetailResp: Decodable {
        struct D: Decodable {
            let id: Int
            let showName: String
            let shortDesc: String?
            let categoryId: Int?
            let categoryName: String?
            let longDesc: String?
            let mediaInfo: String?
            let imdb: String?
            let douban: String?
            let fileSize: Int64?
            let screenshotList: [String]?
            let picture: String?
            let regionNameList: [String]?
            let piecesHash: String?
            let tagList: [String]?
        }
        let success: Bool
        let data: D
    }

    static func kindFromCategory(_ name: String?) -> ReleaseKind {
        guard let n = name else { return .other }
        if n.contains("电影") { return .movie }
        if n.contains("剧集") { return .series }
        if n.contains("动漫") { return .anime }
        if n.contains("综艺") { return .tvshow }
        if n.contains("纪录片") { return .documentary }
        if n.contains("体育") { return .sports }
        return .other
    }

    /// 内部 HTML -> YemaPT 的 Markdown 简介（图片独立行、去标签、解码实体）
    static func htmlToMarkdown(_ html: String) -> String {
        var out = html
        // 引用框的 <legend>（"引用""代码"）不是内容，去掉后简介才不会被顶上一行标签
        out = out.replacingOccurrences(of: "(?s)<legend[^>]*>.*?</legend>", with: "",
                                       options: [.regularExpression, .caseInsensitive])
        // 换行语义
        for tag in ["<br />", "<br>", "<br/>", "</p>", "</div>", "</li>", "</tr>", "</h1>", "</h2>", "</h3>", "</h4>", "</blockquote>", "</pre>"] {
            out = out.replacingOccurrences(of: tag, with: "\n")
        }
        // 图片 -> ![](url)（独立行，与站点真实 longDesc 格式一致）
        out = HTMLUtil.replaceMatches(out, #"<img[^>]*src=["']([^"']+)["'][^>]*>"#) { m in
            guard let r = Range(m.range(at: 1), in: out) else { return "\n" }
            return "\n![](\(String(out[r])))\n"
        }
        // 链接 <a href="u">text</a> -> text(u)
        out = HTMLUtil.replaceMatches(out, #"<a[^>]*href=["']([^"']+)["'][^>]*>([^<]*)</a>"#) { m in
            guard let r1 = Range(m.range(at: 1), in: out), let r2 = Range(m.range(at: 2), in: out) else { return "" }
            let text = String(out[r2]).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? String(out[r1]) : text + "(" + String(out[r1]) + ")"
        }
        // 去标签 + 实体解码
        out = HTMLUtil.replaceMatches(out, "</?[a-zA-Z][^>]*>", options: []) { _ in "" }
        out = HTMLUtil.decodeEntities(out)
        // 压缩空行
        let lines = out.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var md: [String] = []
        var blank = false
        for l in lines {
            if l.isEmpty {
                if !blank && !md.isEmpty { md.append(""); blank = true }
            } else {
                md.append(l); blank = false
            }
        }
        while let last = md.last, last.isEmpty { md.removeLast() }
        return md.joined(separator: "\n")
    }

    /// Markdown -> 内部 HTML（img / 换行；简介保留纯文本）
    static func markdownToHTML(_ md: String) -> String {
        var out = md
        // 图片 ![alt](url) -> <img src="url">（换行由末尾统一 <br /> 拼接负责）
        out = HTMLUtil.replaceMatches(out, "!\\[[^\\]]*\\]\\(([^)\\s]+)\\)", options: []) { m in
            guard let r = Range(m.range(at: 1), in: out) else { return "" }
            return "<img src=\"\(String(out[r]))\">"
        }
        // 链接 [text](url) -> text (url)
        out = HTMLUtil.replaceMatches(out, "(?<![\\(\\w@])\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", options: []) { m in
            guard let r1 = Range(m.range(at: 1), in: out), let r2 = Range(m.range(at: 2), in: out) else { return "" }
            return "\(String(out[r1])) (\(String(out[r2])))"
        }
        // 标题行 / 强调符号
        out = out.replacingOccurrences(of: "**", with: "")
        out = HTMLUtil.replaceMatches(out, "^#{1,6}\\s+", options: []) { _ in "" }
        // 换行 -> <br />
        let lines = out.components(separatedBy: "\n")
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "<br />")
    }

    func fetchDetail(detailURL: String) throws -> ReleaseInfo {
        guard let m = HTMLUtil.group(detailURL,
                                     #"(?:torrent/detail/|detail%2F|detail\?id=|id=)(\d+)"#),
              let id = Int(m) else {
            throw BoxSendError.badInput("无法解析 YemaPT 详情链接: \(detailURL)")
        }
        let resp = try client.get(site.url + "api/torrent/fetchTorrentDetail?id=\(id)", referer: detailURL)
        if resp.status == 401 || resp.status == 403 {
            throw BoxSendError.cookieExpired(site.url)
        }
        guard resp.status == 200 else {
            throw BoxSendError.http(status: resp.status, url: detailURL,
                                    body: String(data: resp.data.prefix(200), encoding: .utf8) ?? "")
        }
        return try parseDetail(resp.data, detailURL: detailURL, id: id)
    }

    /// 纯解析（供测试）
    func parseDetail(_ data: Data, detailURL: String, id: Int? = nil) throws -> ReleaseInfo {
        let j = try JSONDecoder().decode(DetailResp.self, from: data)
        let d = j.data
        let tid = id ?? d.id
        let imdb = d.imdb.flatMap { $0.isEmpty ? nil : ($0.hasPrefix("tt") ? $0 : "tt" + $0) }
        var descr = Self.markdownToHTML(d.longDesc ?? "")
        if !descr.isEmpty, let pics = d.screenshotList, !pics.isEmpty {
            // 详情页未内嵌截图时补上
            let imgs = pics.map { "<img src=\"\($0)\" /><br />" }.joined()
            if !descr.contains("img src=") { descr = imgs + "<br />" + descr }
        }
        let region = (d.regionNameList ?? [])
            .map { e -> String in
                var t = e
                if let re = try? NSRegularExpression(pattern: #"^[A-Z]{2}\("#) {
                    t = re.stringByReplacingMatches(in: t, options: [], range: NSRange(t.startIndex..., in: t), withTemplate: "")
                }
                if let re = try? NSRegularExpression(pattern: #"\)$"#) {
                    t = re.stringByReplacingMatches(in: t, options: [], range: NSRange(t.startIndex..., in: t), withTemplate: "")
                }
                return t
            }
            .joined(separator: " / ")
        let evidence = (d.shortDesc ?? "") + "\n" + (d.longDesc ?? "")
        return ReleaseInfo(siteID: site.id, detailURL: detailURL, name: d.showName, descr: descr,
                           imdb: imdb, douban: d.douban, size: d.fileSize,
                           kind: Self.kindFromCategory(d.categoryName),
                           torrentName: d.showName + ".torrent",
                           torrentURL: site.url + "api/torrent/download?id=\(tid)",
                           isForbidReseed: evidence.contains("禁转"),
                           subtitle: Self.subtitleFromShortDesc(d.shortDesc ?? ""), genre: d.categoryName ?? "",
                           mediainfo: d.mediaInfo ?? "", region: region)
    }

    func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String) {
        let resp = try client.get(info.torrentURL, referer: info.detailURL)
        if resp.status == 401 || resp.status == 403 || resp.status == 404 {
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

    private struct FindImdbResp: Decodable {
        struct Item: Decodable { let id: Int; let showName: String }
        let success: Bool
        let data: [Item]?
    }

    func searchExists(_ info: ReleaseInfo) throws -> String? {
        guard let imdb = info.imdb, !imdb.isEmpty else { return nil }
        let resp = try client.get(site.url + "api/torrent/findImdbTorrentList?imdbId=\(imdb)", referer: site.url)
        guard resp.status == 200 else {
            if resp.status == 401 || resp.status == 403 { throw BoxSendError.cookieExpired(site.url) }
            return nil
        }
        guard let j = try? JSONDecoder().decode(FindImdbResp.self, from: resp.data), j.success else { return nil }
        let target = info.name.lowercased()
        if let hit = (j.data ?? []).first(where: { $0.showName.lowercased() == target }) {
            return Self.detailLink(id: hit.id, base: site.url)
        }
        return nil
    }

    /// 站点提示"已存在"（不同站文案不一）
    static func isDuplicateMessage(_ msg: String) -> Bool {
        let m = msg.lowercased()
        return ["已存在", "已经存在", "已经上传", "上传过了", "重复", "same torrent", "already exist", "duplicate"]
            .contains(where: { m.contains($0) })
    }

    /// 站点返回的种子 id：兼容 data 为整数/字符串，以及 data.id / data.torrentId
    static func torrentID(from node: Any?) -> Int? {
        if let i = node as? Int { return i }
        if let i = node as? Int64 { return Int(i) }
        if let s = node as? String, let i = Int(s) { return i }
        guard let d = node as? [String: Any] else { return nil }
        for k in ["id", "torrentId", "torrentID", "tid"] {
            if let v = torrentID(from: d[k]) { return v }
        }
        return torrentID(from: d["data"])
    }

    static func detailLink(id: Int, base: String) -> String {
        base + "#/torrent/detail/\(id)"
    }

    /// piecesHash 精确查重（上传前兜底，需要 .torrent 数据）
    func existsByPiecesHash(_ torrentData: Data) throws -> Int? {
        guard let hex = Bencode.piecesHashHex(torrentData) else { return nil }
        let resp = try client.postJSON(site.url + "api/torrent/existTorrentWithPiecesHash",
                                       object: ["piecesHash": hex], referer: site.url)
        guard resp.status == 200,
              let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
              obj["success"] as? Bool == true else { return nil }
        return (obj["data"] as? Int).flatMap { $0 > 0 ? $0 : nil }
    }

    // MARK: - 上传

    /// 站点 shortDesc 形如 “中文名 | 4K | 类型: … | 导演: …”，取首段作副标题
    static func subtitleFromShortDesc(_ shortDesc: String) -> String {
        let t = shortDesc.split(separator: " | ", omittingEmptySubsequences: true).first.map(String.init) ?? shortDesc
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// 副标题必填且建议含中文名；源站无副标题时取简介首行兜底
    static func fallbackSubtitle(_ info: ReleaseInfo) -> String {
        let plain = HTMLUtil.stripTags(info.descr)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .first ?? ""
        let t = String(plain.prefix(120))
        return t.isEmpty ? info.name : t
    }

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

    func buildUploadFields(_ info: ReleaseInfo) throws -> [HTTPClient.MultipartField] {
        var fields: [HTTPClient.MultipartField] = []
        func setField(_ name: String, _ value: String) {
            fields.removeAll { $0.name == name }
            if !value.isEmpty { fields.append(.init(name, value)) }
        }
        func setFields(_ name: String, _ values: [String]) {
            for v in values where !v.isEmpty { fields.append(.init(name, v)) }
        }
        setField("showName", info.name)
        setField("shortDesc", info.subtitle.isEmpty ? Self.fallbackSubtitle(info) : info.subtitle)
        if let v = try categoryId(info) { setField("categoryId", String(v)) }
        if let v = try mediumValue(info) { setField("medium", v) }
        if let v = try standardValue(info) { setField("standard", v) }
        if let v = try codecValue(info) { setField("codec", v) }
        if let v = try audioCodecValue(info) { setField("audiocodec", v) }
        setFields("regionList", try regionValues(info))
        if let v = try teamValue(info) { setField("team", v) }
        setFields("tagList", try tagValues(info))
        if let imdb = info.imdb, !imdb.isEmpty {
            // 站点只收数字（页面里 "tt" 前缀是固定展示）
            var digits = imdb
            while let f = digits.first, f.isLetter { digits.removeFirst() }
            setField("imdb", digits)
        }
        if let douban = info.douban, !douban.isEmpty { setField("douban", douban) }
        if info.kind == .series, let s = Self.season(from: info.name) {
            setField("season", String(s))
        }
        setField("longDesc", info.extraQuoteMarkdown + Self.htmlToMarkdown(info.descr))
        setField("mediaInfo", info.mediainfo)
        let pics = Self.imageURLs(fromHTML: info.descr, base: URL(string: info.detailURL))
        setFields("screenshotList", pics)
        if let p = pics.first { setField("picture", p) }
        // 站点配置：匿名上传默认值
        if let cfg = try fetchOptions().uploadConfig {
            if cfg.uploadUserAnonymousEnable == true {
                setField("uploadUserAnonymous", cfg.defaultUploadUserAnonymous ?? "y")
            }
        }
        setField("hrPunishEnable", "false")
        return fields
    }

    func previewUploadFields(_ info: ReleaseInfo) throws -> [(String, String)] {
        try buildUploadFields(info).map { ($0.name, $0.value) }
    }

    private func extractErrorMessage(body: String, status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: body.data(using: .utf8) ?? Data()) as? [String: Any] {
            if let msg = obj["errorMessage"] as? String, !msg.isEmpty {
                let code = (obj["errorCode"] as? Int).map { " [\($0)]" } ?? ""
                return "HTTP \(status)\(code): \(msg)"
            }
            if let msg = obj["message"] as? String, !msg.isEmpty { return "HTTP \(status): \(msg)" }
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

    func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
        // piecesHash 精确查重兜底
        if let id = try? existsByPiecesHash(torrentData) {
            return UploadOutcome(success: true, message: "站点已存在该种子（piecesHash 查重命中）",
                                 detailURL: Self.detailLink(id: id, base: site.url),
                                 alreadyExists: true)
        }
        let fields = try buildUploadFields(info)
        let resp = try client.postMultipart(
            site.url + "api/torrent/addTorrent",
            fields: fields,
            files: [(name: "file", filename: filename, data: torrentData, mime: "application/x-bittorrent")],
            referer: site.url + "#/torrent/add"
        )
        let body = String(data: resp.data, encoding: .utf8) ?? ""
        if let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
           obj["success"] as? Bool == true {
            let msg = (obj["message"] as? String) ?? (obj["msg"] as? String) ?? ""
            let id = Self.torrentID(from: obj["data"]) ?? Self.torrentID(from: obj)
            // 站点接受请求但提示同名/同 hash 种子已存在：按"已存在"处理，并尽量带上已有种子链接
            if Self.isDuplicateMessage(msg) {
                return UploadOutcome(success: true, message: "站点提示已存在（\(msg)）",
                                     detailURL: id.map { Self.detailLink(id: $0, base: site.url) },
                                     alreadyExists: true)
            }
            if let id {
                return UploadOutcome(success: true, message: msg.isEmpty ? "发布成功" : "发布成功（\(msg)）",
                                     detailURL: Self.detailLink(id: id, base: site.url))
            }
            return UploadOutcome(success: true, message: "发布成功（未返回种子 id）", detailURL: nil)
        }
        if resp.status == 401 || resp.status == 403 {
            throw BoxSendError.cookieExpired(site.url)
        }
        var errMsg = extractErrorMessage(body: body, status: resp.status)
        if let p = dumpDebugBody(body) { errMsg += "（响应已存 \(p)）" }
        return UploadOutcome(success: false, message: errMsg, detailURL: nil)
    }
}
