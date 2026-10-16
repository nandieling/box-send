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
        let version = (r["version"] as? String) ?? "未知版本"
        let name = (r["name"] as? String) ?? "Transmission"
        return "\(name) \(version)，登录成功"
    }

    private func rpc(_ method: String, _ arguments: [String: Any]) throws -> [String: Any] {
        var attempt = 0
        while true {
            attempt += 1
            let (obj, status, newSID) = try sendOnce(method, arguments)
            if let newSID { sessionID = newSID }
            if status == 409 && attempt == 1 { continue }
            if let r = obj?["result"] as? String, r != "success" {
                throw BoxSendError.badInput("transmission \(method): \(r) \(obj?["argument-error"] as? String ?? "")")
            }
            return obj ?? [:]
        }
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
        let list = (r["arguments"] as? [[String: Any]]) ?? []
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
                totalSize: t["totalSize"] as? Int64 ?? Int64(t["totalSize"] as? Int ?? 0),
                progress: t["percentDone"] as? Double ?? 0,
                trackerHosts: hosts)
        }
    }

    /// files 字段：{name, bytes, length}；新版叫 sizeBytes
    func torrentFiles(hash: String) throws -> [(path: String, size: Int64)] {
        let r = try rpc("torrent-get", ["ids": [hash], "fields": ["files"]])
        guard let first = (r["arguments"] as? [[String: Any]])?.first,
              let files = first["files"] as? [[String: Any]] else { return [] }
        return files.compactMap { f in
            guard let path = f["name"] as? String else { return nil }
            let size = (f["sizeBytes"] as? Int64) ?? (f["length"] as? Int64)
                ?? Int64(f["bytes"] as? Int ?? 0)
            return (path, size)
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
        guard let first = (resp["arguments"] as? [[Any]])?.first,
              let id = first.first as? Int else {
            throw BoxSendError.badInput("transmission: 无法获取 torrent id")
        }
        // 需求 3: 按源站点限速
        if upLimit > 0 {
            _ = try rpc("torrent-set", ["ids": [id], "upload-limit": upLimit, "upload-limit-enabled": 1])
        }
        return AddTorrentResult(id: "torrent-#\(id)")
    }
}
