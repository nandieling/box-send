import Foundation

/// TMDB 反查配置（「设置 → TMDB 链接」）：个别目标站（杜比）把 TMDB 链接设成必填，
/// 而多数源站简介里根本没有 TMDB，只能拿 IMDb / 豆瓣号去 TMDB 反查。
/// 国内直连 api.themoviedb.org 常常不通，所以允许填一个 API 代理网关地址。
public struct TMDBConfig: Codable, Equatable {
    public static let officialAPIBase = "https://api.themoviedb.org/3"
    /// 目标站要填的规范链接前缀（与 API 网关无关，站点校验的是这个域名）
    public static let siteBase = "https://www.themoviedb.org"

    public var enabled: Bool
    /// API 前缀：官方是 https://api.themoviedb.org/3；用网关时填网关给出的完整前缀
    public var apiBase: String
    /// v3 的 api_key；网关自己代填 key 时留空
    public var apiKey: String

    public init(enabled: Bool = false, apiBase: String = TMDBConfig.officialAPIBase,
                apiKey: String = "") {
        self.enabled = enabled
        self.apiBase = apiBase
        self.apiKey = apiKey
    }

    /// 启用时用的接口前缀：没开开关返回 nil（调用方据此决定要不要反查），
    /// 地址留空则回落到官方接口
    public var resolvedAPIBase: String? {
        guard enabled else { return nil }
        let base = apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return base.isEmpty ? TMDBConfig.officialAPIBase : base
    }
}

/// 用豆瓣 / IMDb 号反查 TMDB 条目链接（目标站的 TMDB 输入框用）
///
/// 路径：有 IMDb 号走 `/find/tt…?external_source=imdb_id`（TMDB 自己核对，最可靠）；
/// 只有豆瓣号时按片名搜（`/search/movie`、`/search/tv`），再取 `/external_ids`
/// 里的豆瓣号比对——TMDB 的 find 不支持豆瓣源，只能这样绕。
public final class TMDBResolver {
    private let client: HTTPClient
    /// 接口前缀候选：先用填的地址，它 404 再试补了版本号的那个
    private var bases: [String]
    private var baseIndex = 0
    private var apiBase: String { bases[min(baseIndex, bases.count - 1)] }
    private let apiKey: String
    /// 取数据出口（单测换成桩响应，跑真实网关时用 HTTPClient）
    var transport: ((String, TimeInterval) throws -> (status: Int, body: Data))?
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private var errors: [String: String] = [:]

    /// 最近一次失败原因（给转种日志用）
    public var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return Array(errors.values).last
    }

    /// 填上了但没能用 IMDb/豆瓣号核对时的说明（日志用，不算失败）
    public private(set) var lastWarning: String?

    public init(client: HTTPClient, config: TMDBConfig) {
        self.client = client
        self.bases = Self.baseCandidates(from: config.resolvedAPIBase ?? TMDBConfig.officialAPIBase)
        self.apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 接口前缀候选：镜像常把 TMDB 挂在站点子路径下（…/tmdb0512），少写版本号会整站 404，
    /// 所以地址没以 /1 /3 /4 结尾时自动补一个 /3 候选
    public static func baseCandidates(from base: String) -> [String] {
        let clean = base.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.hasSuffix("/1"), !clean.hasSuffix("/3"), !clean.hasSuffix("/4") else {
            return [clean]
        }
        return [clean, clean + "/3"]
    }

    /// 按配置建反查器：没开开关就不建（返回 nil，调用方也就不注入回调）
    public static func make(client: HTTPClient, config: TMDBConfig?) -> TMDBResolver? {
        guard let cfg = config, cfg.resolvedAPIBase != nil else { return nil }
        return TMDBResolver(client: client, config: cfg)
    }

    /// 反查规范链接（https://www.themoviedb.org/movie/12345）；查不到返回 nil
    public func resolve(imdb: String?, douban: String?, name: String, altName: String? = nil) -> String? {
        let key = "imdb:\(imdb ?? "")|db:\(douban ?? "")"
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        if let hit { return hit }
        matched = 0
        transportFailed = false
        lastWarning = nil
        let found = lookup(imdb: imdb, douban: douban, name: name, altName: altName)
        lock.lock()
        if let found { cache[key] = found } else { errors[key] = lastReason }
        lock.unlock()
        return found
    }

    private var lastReason = ""
    /// 最后一次真正发出去的请求（排查网关用）
    private(set) var requested: String?

    private func lookup(imdb: String?, douban: String?, name: String,
                        altName: String?) -> String? {
        let imdbID = imdb?.isEmpty == true ? nil : imdb
        let doubanID = douban?.isEmpty == true ? nil : douban
        if let tt = imdbID, let link = linkByIMDb(tt) { return link }
        // 检索词候选：片名（剔掉季/集标记）→ 同词加年份 → 源站中文译名。
        // 年份不能当硬过滤：整季包/番剧发布名里的年份是这一季的首播年，
        // TMDB 条目按系列首播年算（寒蝉·煌写 2011，条目 first_air_date 是 2006，一加过滤就 0 条）
        var queries: [(query: String, year: Int?)] = []
        let (title, year) = Self.searchQuery(fromName: name)
        if !title.isEmpty {
            queries.append((title, nil))
            if let year { queries.append((title, year)) }
        }
        if let altName {                       // 源站中文译名：国产/番剧条目常只有中文名对得上
            let alt = Self.searchQuery(fromName: altName).query
            if !alt.isEmpty, !queries.contains(where: { $0.query == alt }) { queries.append((alt, nil)) }
        }
        guard !queries.isEmpty else {
            lastReason = "发布名里取不出可用于搜索的片名"
            return nil
        }
        // 整季/多集先发 tv 检索，单片先发 movie：兜底候选取第一个类型，避免被另一类型的噪声抢走
        let typeOrder = QualityTokens.releaseShape(from: name) == "series"
            ? ["tv", "movie"] : ["movie", "tv"]
        var unverified: String?       // 只搜到一个候选、但外部号核对不上：留作兜底
        var sawResults = false
        for attempt in queries {
            for type in typeOrder {
                // 网关连不通/鉴权失败就别再试下一轮，日志里留第一条原因
                if transportFailed { break }
                guard let ids = try? search(type: type, query: attempt.query, year: attempt.year) else { continue }
                if !ids.isEmpty { sawResults = true }
                for id in ids.prefix(5) {
                    if transportFailed { break }
                    guard let ext = try? externalIDs(type: type, id: id) else { continue }
                    matched += 1
                    if let tt = imdbID, ext.imdb == tt { return Self.link(type: type, id: id) }
                    if let db = doubanID, let got = ext.douban, got == db { return Self.link(type: type, id: id) }
                }
                if ids.count == 1, unverified == nil { unverified = Self.link(type: type, id: ids[0]) }
            }
            if transportFailed { break }
        }
        // 番剧/OVA 的 IMDb 号常常挂在季或篇上，和 TMDB 系列条目那条号天然对不上；
        // 整轮检索只剩一个候选时按它填，至少比让整单打回强，日志里说明没核对过
        if let unverified {
            lastWarning = "按片名检索只匹配到唯一候选，未能用 IMDb/豆瓣号核对"
            return unverified
        }
        if !transportFailed {
            lastReason = !sawResults
                ? "TMDB 按片名（含中文译名）没搜到任何候选条目"
                : (matched == 0
                    ? "TMDB 搜到候选但取不到外部条目号（网关可能没代理 external_ids 接口）"
                    : "TMDB 搜到多个候选，豆瓣/IMDb 号都没对上，不敢瞎填")
        }
        return nil
    }

    private var matched = 0
    private var transportFailed = false

    private func linkByIMDb(_ tt: String) -> String? {
        guard let data = try? fetchData(Self.findPath(imdb: tt)) else { return nil }
        guard let hit = Self.findResult(data) else {
            lastReason = "TMDB find(\(tt)) 没有结果"
            return nil
        }
        return Self.link(type: hit.type, id: hit.id)
    }

    private func search(type: String, query: String, year: Int?) throws -> [Int] {
        Self.searchResults(try fetchData(Self.searchPath(type: type, query: query, year: year)))
    }

    private func externalIDs(type: String, id: Int) throws -> (imdb: String?, douban: String?) {
        Self.parseExternalIDs(try fetchData(Self.externalIDsPath(type: type, id: id)))
    }

    /// 取接口：404 说明前缀不对（多半是网关地址漏了 /3），换下一个候选再试，
    /// 并把能通的前缀记下来，后面的请求不再白跑
    private func fetchData(_ path: String) throws -> Data {
        var lastMessage = "TMDB 接口不通"
        var attempt = baseIndex
        while attempt < bases.count {
            do {
                let url = Self.withKey(bases[attempt] + path, apiKey)
                let fetched: (status: Int, body: Data)
                if let transport {
                    fetched = try transport(url, 15)
                } else {
                    let resp = try client.get(url, timeout: 15)
                    fetched = (resp.status, resp.data)
                }
                requested = url
                if fetched.status == 200, let apiErr = Self.apiError(fetched.body) {
                    // 镜像/网关常见：条目不存在也回 200，正文里才是 status_message
                    lastMessage = apiErr
                } else if fetched.status == 200 {
                    baseIndex = attempt
                    transportFailed = false
                    return fetched.body
                } else {
                    let body = HTMLUtil.stripTags(String(data: fetched.body, encoding: .utf8) ?? "")
                    lastMessage = "TMDB 接口返回 \(fetched.status)：\(body.prefix(80))"
                }
                if fetched.status == 404 {
                    lastMessage += "（接口地址要写到版本号那一层，如 https://网关/路径/3）"
                    if attempt + 1 < bases.count { attempt += 1; transportFailed = true; continue }
                }
            } catch let e as BoxSendError {
                lastMessage = e.localizedDescription
            } catch {
                lastMessage = "TMDB 请求失败：\(error.localizedDescription)"
            }
            break
        }
        transportFailed = true
        lastReason = lastMessage
        throw BoxSendError.badInput(lastMessage)
    }

    // MARK: - 纯函数（便于单测：URL、查询词、响应解析）

    /// 发布名 -> 搜索词 + 年份：以第一个 19xx/20xx 为界，年份之后都是画质/编码噪声；
    /// 组名方括号段整段丢掉（"[VCB-Studio] 摇曳百合 [S03][1080p]" -> "摇曳百合"）
    public static func searchQuery(fromName name: String) -> (query: String, year: Int?) {
        var text = name.replacingOccurrences(
            of: #"[\[【(（][^\]】)）]*[\]】)）]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[._\[\]【】/\\]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ("", nil) }
        if let m = text.range(of: #"(?<!\d)(19\d{2}|20\d{2})(?!\d)"#, options: .regularExpression) {
            let year = Int(text[m.lowerBound..<m.upperBound])
            let head = Self.stripSeasonMarkers(text[..<m.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
            if head.count >= 2 { return (head, year) }
        }
        // 没有年份：截到第一个像画质标记或文件后缀的 token（1080p / S03 / WEB-DL / mkv）之前
        let tokens = text.components(separatedBy: " ")
        var kept: [String] = []
        for t in tokens {
            if t.range(of: #"^(\d{3,4}[ip]?\d?|s\d{1,2}|ep?\d{1,3}|x26[45]|hevc|h\.?26[45]|dts.*|ac3|e-?ac3|web-?dl|webrip|hdtv|bdrip|dvd9?|blu-?ray|remux|hdr\d*|dovi|60fps|10bit|bit|mkv|mp4|avi|wmv|mov|flv|rmvb|m4v|ts|m2ts|iso|ape|flac)\b"#,
                       options: [.regularExpression, .caseInsensitive]) != nil { break }
            kept.append(t)
        }
        let q = Self.stripSeasonMarkers(kept.joined(separator: " "))
        return (q.count >= 2 ? q : text, nil)
    }

    /// 季/集标记（S04、S03E05、EP03、4x03、第12集、全24话）：留着会让 TMDB 检索直接 0 条
    public static func stripSeasonMarkers(_ text: String) -> String {
        let noise = #"^(s\d{1,2}([.\-_]?e?\d{1,3})?|ep?\d{1,3}|\d{1,2}x\d{1,3}|第\s*\d+\s*[集话話季卷]|全\s*\d+\s*[集话話])$"#
        let kept = text.components(separatedBy: " ").filter {
            $0.range(of: noise, options: [.regularExpression, .caseInsensitive]) == nil
        }
        return kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 200 响应体里的接口级错误（网关/镜像对不存在的资源也回 200）
    public static func apiError(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let failed = (obj["success"] as? Bool).map { !$0 } ?? false
        guard failed || (obj["status_code"] as? Int).map({ $0 != 0 }) == true else { return nil }
        if !failed, obj["results"] != nil || obj["movie_results"] != nil || obj["tv_results"] != nil {
            return nil      // 正常检索响应里也可能带 status_code: 0 之外的字段，有结果就不当错误
        }
        let code = (obj["status_code"] as? Int).map { " \($0)" } ?? ""
        let msg = (obj["status_message"] as? String) ?? ""
        return "TMDB 接口报错\(code)：\(msg)"
    }

    public static func findPath(imdb: String) -> String {
        "/find/\(imdb.urlEncoded)?external_source=imdb_id"
    }

    public static func findURL(base: String, key: String, imdb: String) -> String {
        withKey(base + findPath(imdb: imdb), key)
    }

    public static func searchPath(type: String, query: String, year: Int?) -> String {
        var p = "/search/\(type)?query=\(query.urlEncoded)"
        if let year { p += "&year=\(year)&first_air_date_year=\(year)" }
        return p
    }

    public static func searchURL(base: String, key: String, type: String,
                                query: String, year: Int?) -> String {
        withKey(base + searchPath(type: type, query: query, year: year), key)
    }

    public static func externalIDsPath(type: String, id: Int) -> String {
        "/\(type)/\(id)/external_ids"
    }

    public static func externalIDsURL(base: String, key: String, type: String, id: Int) -> String {
        withKey(base + externalIDsPath(type: type, id: id), key)
    }

    private static func withKey(_ url: String, _ key: String) -> String {
        key.isEmpty ? url : url + "&api_key=\(key.urlEncoded)"
    }

    public static func link(type: String, id: Int) -> String {
        "\(TMDBConfig.siteBase)/\(type)/\(id)"
    }

    /// /find 响应：电影优先，其次剧集
    public static func findResult(_ data: Data) -> (type: String, id: Int)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for type in ["movie_results", "tv_results"] {
            if let arr = obj[type] as? [[String: Any]], let first = arr.first,
               let id = first["id"] as? Int {
                return (String(type.split(separator: "_")[0]), id)
            }
        }
        return nil
    }

    /// /search 响应：按 TMDB 给的相关度顺序取条目号
    public static func searchResults(_ data: Data) -> [Int] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["results"] as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["id"] as? Int }
    }

    /// /external_ids 响应：豆瓣号字段 movie / tv 写法不同，按包含 douban 的键取
    public static func parseExternalIDs(_ data: Data) -> (imdb: String?, douban: String?) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        var imdb: String?
        var douban: String?
        for (k, v) in obj {
            let value = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? (v as? Int).map(String.init)
            guard let value, !value.isEmpty else { continue }
            if k.lowercased() == "imdb_id" { imdb = value }
            if k.lowercased().contains("douban") { douban = value }
        }
        return (imdb, douban)
    }
}
