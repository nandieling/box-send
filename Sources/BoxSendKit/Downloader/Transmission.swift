import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transmission RPC (JSON over HTTP)。
/// 需求 3: torrent-add 后用 torrent-set 设置 upload-limit / upload-limit-enabled。
final class Transmission: Downloader {
    let client: HTTPClient
    let rpcURL: String
    let username: String
    let password: String
    var sessionID = ""

    init(client: HTTPClient, baseURL: String, username: String, password: String) {
        self.client = client
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.rpcURL = base + "/transmission/rpc"
        self.username = username
        self.password = password
    }

    func testConnection() throws -> String {
        let r = try rpc("session-get", [:])
        let version = (r["version"] as? String) ?? "未知版本"   // rpc 已剥掉外层，这里直接读
        let name = (r["name"] as? String) ?? "Transmission"
        return "\(name) \(version)，登录成功"
    }

    /// 发一次 RPC，只把 `arguments` 那一层交出去。
    /// 站方回的是 `{"arguments":{…},"result":"success","tag":n}`，整包直接给上层会让人
    /// 把 `arguments` 当成种子数组读（辅种扫描一直返回 0 条就是这么来的），
    /// 也让「连不上 / 超时」静默变成空清单。
    private func rpc(_ method: String, _ arguments: [String: Any]) throws -> [String: Any] {
        var attempt = 0
        while true {
            attempt += 1
            let (obj, status, newSID) = try sendOnce(method, arguments)
            if let newSID { sessionID = newSID }
            if status == 409 && attempt == 1 { continue }
            return try Self.arguments(of: obj, method: method, status: status)
        }
    }

    /// 整包响应 → `arguments` 那一层。传输失败（obj 为 nil）必须报出来：
    /// 静默返回空表会让「连不上」看起来像「下载器里没有种子」。
    static func arguments(of obj: [String: Any]?, method: String, status: Int) throws
        -> [String: Any] {
        guard let obj else {
            throw BoxSendError.badInput(status == -1
                ? "transmission \(method): 连不上或超时（检查地址、账号与隧道）"
                : "transmission \(method): 响应不是预期的 JSON（HTTP \(status)）")
        }
        if let r = obj["result"] as? String, r != "success" {
            throw BoxSendError.badInput("transmission \(method): \(r) \(obj["argument-error"] as? String ?? "")")
        }
        return obj["arguments"] as? [String: Any] ?? [:]
    }

    private func sendOnce(_ method: String, _ arguments: [String: Any]) throws -> ([String: Any]?, Int, String?) {
        let payload: [String: Any] = ["method": method, "arguments": arguments]
        var req = URLRequest(url: URL(string: rpcURL)!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Basic " + Data("\(username):\(password)".utf8).base64EncodedString(),
                     forHTTPHeaderField: "Authorization")
        if !sessionID.isEmpty {
            req.setValue(sessionID, forHTTPHeaderField: "X-Transmission-Session-Id")
        }
        let sem = DispatchSemaphore(value: 0)
        var result: ([String: Any]?, Int, String?)?
        let task = client.session0.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            if error != nil {
                result = (nil, -1, nil)
                return
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            let sid = http?.value(forHTTPHeaderField: "X-Transmission-Session-Id")
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result = (nil, status, sid)
                return
            }
            result = (obj, status, sid)
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 60)
        if let r = result { return r }
        throw BoxSendError.badInput("transmission: 无响应")
    }

    /// 种子清单：TorrentID 当 hash 用不稳，取 hashString
    func listTorrents() throws -> [LocalTorrent] {
        let r = try rpc("torrent-get", ["fields": ["id", "hashString", "name", "totalSize",
                                                   "percentDone", "downloadDir", "labels",
                                                   "trackers"]])
        return Self.localTorrents(r["torrents"] as? [[String: Any]] ?? [])
    }

    /// TR 的分类/标签叫 labels（字符串数组），不是 qB 那种逗号分隔的 tags：
    /// 只取第一个当 category 会让「只辅这些分类」的筛选漏掉后面的标签
    static func labels(_ t: [String: Any]) -> [String] {
        if let arr = t["labels"] as? [String] { return arr.filter { !$0.isEmpty } }
        return ((t["tags"] as? String) ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    /// arguments.torrents → 本地清单（table 格式；object 格式才以 hash 为键）
    static func localTorrents(_ list: [[String: Any]]) -> [LocalTorrent] {
        return list.compactMap { t -> LocalTorrent? in
            guard let hash = (t["hashString"] as? String)?.lowercased() else { return nil }
            let hosts = ((t["trackers"] as? [[String: Any]]) ?? []).compactMap {
                URL(string: ($0["announce"] as? String) ?? "")?.host?.lowercased()
            }
            return LocalTorrent(
                hash: hash,
                name: t["name"] as? String ?? "",
                savePath: t["downloadDir"] as? String ?? "",
                category: ((t["labels"] as? [String])?.first),
                tags: Self.labels(t),
                totalSize: t["totalSize"] as? Int64 ?? Int64(t["totalSize"] as? Int ?? 0),
                progress: t["percentDone"] as? Double ?? 0,
                trackerHosts: hosts)
        }
    }

    /// files 字段：{name, bytes, length}；新版叫 sizeBytes
    func torrentFiles(hash: String) throws -> [(path: String, size: Int64)] {
        let r = try rpc("torrent-get", ["ids": [hash], "fields": ["files"]])
        guard let first = (r["torrents"] as? [[String: Any]])?.first,
              let files = first["files"] as? [[String: Any]] else { return [] }
        return files.compactMap { f in
            guard let path = f["name"] as? String else { return nil }
            let size = (f["sizeBytes"] as? Int64) ?? (f["length"] as? Int64)
                ?? Int64(f["bytes"] as? Int ?? 0)
            return (path, size)
        }
    }

    /// 单条进度（默认实现会拉整份清单：上万条种子时每 10 秒问一次就是几 MB 一趟）。
    /// Transmission 只在种子启动后才校验本地文件，而辅种是「先暂停加进来」的：这里顺手把它
    /// 启动，校验才会真跑起来；校验完仍不满 100% 时流水线自己会删掉这条，不会留下重下一整份。
    func torrentProgress(hash: String) throws -> (progress: Double, state: String)? {
        let r = try rpc("torrent-get", ["ids": [hash], "fields": ["percentDone", "status"]])
        guard let t = (r["torrents"] as? [[String: Any]])?.first else { return nil }
        let progress = t["percentDone"] as? Double ?? 0
        let status = t["status"] as? Int ?? -1
        if status == 0, progress < 0.999 {
            _ = try rpc("torrent-start", ["ids": [hash]])
            return (progress, "checking")
        }
        return (progress, Self.stateName(status))
    }

    /// TR 的 status 码 → 流水线认的那几个状态词（`isChecking` 按 qBittorrent 的写法判）
    static func stateName(_ status: Int) -> String {
        switch status {
        case 2, 3: return "checking"       // 排队校验 / 正在校验
        case 4, 5: return "downloading"    // 排队下载 / 正在下载：文件对不上就会落到这里
        case 6: return "seeding"
        case 0: return "stopped"
        default: return "idle"
        }
    }

    func setPaused(hashes: [String], paused: Bool) throws {
        _ = try rpc(paused ? "torrent-stop" : "torrent-start", ["ids": hashes])
    }

    func removeTorrent(hash: String, keepFiles: Bool) throws {
        _ = try rpc("torrent-remove", ["ids": [hash], "delete-local-data": !keepFiles])
    }

    func addTorrent(data: Data, filename: String,
                    savePath: String?, category: String?,
                    skipChecking: Bool, upLimit: Int64) throws -> AddTorrentResult {
        try addTorrent(data: data, filename: filename, savePath: savePath, category: category,
                       skipChecking: skipChecking, upLimit: upLimit, paused: false)
    }

    func addTorrent(data: Data, filename: String,
                    savePath: String?, category: String?,
                    skipChecking: Bool, upLimit: Int64, paused: Bool) throws -> AddTorrentResult {
        var args: [String: Any] = [
            "metainfo": data.base64EncodedString(),
            "labels": [filename],
            "skip-verify": skipChecking,
            "paused": paused,
        ]
        if let savePath, !savePath.isEmpty { args["download-dir"] = savePath }
        let resp = try rpc("torrent-add", args)
        // 新加的是 torrent-added，同 hash 已存在时回 torrent-duplicate（辅种正撞得上）
        let added = (resp["torrent-added"] as? [String: Any])
            ?? (resp["torrent-duplicate"] as? [String: Any])
        guard let added,
              let id = added["id"] as? Int ?? Int(added["id"] as? String ?? "") else {
            throw BoxSendError.badInput("transmission: 加种子没回 torrent-added（keys: \(resp.keys.sorted())）")
        }
        // 需求 3: 按源站点限速
        if upLimit > 0 {
            _ = try rpc("torrent-set", ["ids": [id], "upload-limit": upLimit, "upload-limit-enabled": 1])
        }
        return AddTorrentResult(id: "torrent-#\(id)")
    }
}
