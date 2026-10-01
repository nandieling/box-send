import Foundation

/// 从 CookieCloud（easychen/CookieCloud，PT 站 cookie 端对端加密云备份）拉取全部 cookie。
///
/// 协议（服务器只存密文，解密在本地）：
///   GET {host}/get/{key}  →  { "encrypted": "<base64>", "crypto_type": "legacy" | "aes-128-cbc-fixed" }
///   密钥 = MD5(key + "-" + password) 的前 16 个 hex 字符
///   legacy:           CryptoJS AES（EVP_BytesToKey MD5, AES-256-CBC, "Salted__" 包裹）
///   aes-128-cbc-fixed: AES-128-CBC，key = 16 个 hex 字符的 UTF-8 字节，IV = 16 个零字节，PKCS7
///   明文 JSON: { "cookie_data": { "host": [ {name, value, ...}, ... ] }, "local_storage_data": {...} }
public final class CookieCloudSync {
    let config: CookieCloudConfig
    let client: HTTPClient

    public init(config: CookieCloudConfig, client: HTTPClient) {
        self.config = config
        self.client = client
    }

    public struct PullResult {
        public var imported: Int    // 成功导入的站点数
        public var skipped: Int     // 无法匹配已知站点而跳过的 host 数
    }

    /// 密钥材料 = MD5(key + "-" + password) 前 16 个 hex 字符
    public static func deriveKey16(key: String, password: String) -> String {
        let digest = CryptoJSCompat.md5(Data((key + "-" + password).utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// 按 crypto_type 本地解密
    public static func decrypt(encrypted: String, cryptoType: String, key: String, password: String) throws -> Data {
        let key16 = deriveKey16(key: key, password: password)
        switch cryptoType {
        case "aes-128-cbc-fixed":
            let b64 = encrypted.filter { !$0.isWhitespace }
            guard let raw = Data(base64Encoded: b64) else {
                throw BoxSendError.badInput("CookieCloud 密文不是 base64")
            }
            return try CryptoJSCompat.aes128CBCDecrypt(data: raw,
                                                       key: [UInt8](key16.utf8),
                                                       iv: [UInt8](repeating: 0, count: 16))
        case "legacy":
            return try CryptoJSCompat.decryptOpenSSL(base64: encrypted, password: key16)
        default:
            throw BoxSendError.badInput("未知 CookieCloud 加密类型：\(cryptoType)")
        }
    }

    /// 解密后的明文 → cookie_data（host → cookie 对象数组）
    public static func parseCookieData(_ data: Data) throws -> [String: [[String: Any]]] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw BoxSendError.badInput("CookieCloud 解密内容不是 JSON（加密密码或 KEY 可能不正确）")
        }
        guard let map = obj["cookie_data"] as? [String: Any] else {
            throw BoxSendError.badInput("CookieCloud 解密内容缺少 cookie_data（版本或配置可能不匹配）")
        }
        var out: [String: [[String: Any]]] = [:]
        for (host, arr) in map where arr is [[String: Any]] {
            out[host] = arr as? [[String: Any]]
        }
        return out
    }

    /// 归一化 host：去掉前导点与小写化；匹配已知站点（精确或主/子域）后返回站点规范 host
    static func normalize(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix(".") { h.removeFirst() }
        return h
    }

    static func matchSite(_ host: String, knownSites: [(id: String, name: String, host: String)]) -> String? {
        let h = normalize(host)
        for site in knownSites {
            let sh = normalize(site.host)
            if h == sh || h.hasSuffix("." + sh) || sh.hasSuffix("." + h) { return site.host }
        }
        return nil
    }

    /// 拉取并解密（不做导入）；返回 {归一化 host: "k=v; k=v"}，供互补同步在后台线程调用
    @discardableResult
    public func fetch() throws -> [String: String] {
        var base = config.host.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        let key = config.key.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !key.isEmpty else {
            throw BoxSendError.badInput("请先填写 CookieCloud 服务器地址与 KEY")
        }
        let urlStr = base + "/get/" + key
        let resp: HTTPClient.Response
        do {
            resp = try client.get(urlStr)
        } catch let e as BoxSendError {
            throw e
        }
        guard (200..<300).contains(resp.status) else {
            throw BoxSendError.http(status: resp.status, url: urlStr,
                                    body: String(data: resp.data.prefix(300), encoding: .utf8) ?? "")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: resp.data)) as? [String: Any],
              let enc = obj["encrypted"] as? String, !enc.isEmpty else {
            throw BoxSendError.badInput("CookieCloud 响应缺少 encrypted 字段（KEY 可能不正确）")
        }
        let cryptoType = (obj["crypto_type"] as? String) ?? "legacy"
        let plain = try Self.decrypt(encrypted: enc, cryptoType: cryptoType,
                                     key: key, password: config.password)
        let data = try Self.parseCookieData(plain)
        guard !data.isEmpty else {
            throw BoxSendError.badInput("CookieCloud 返回 0 条 cookie（请检查 KEY 与扩展里的备份域名）")
        }
        var out: [String: String] = [:]
        for (host, cookies) in data {
            let raw = cookies.compactMap { c -> String? in
                guard let n = c["name"] as? String, let v = c["value"] as? String else { return nil }
                return n + "=" + v
            }.joined(separator: "; ")
            if !raw.isEmpty { out[Self.normalize(host)] = raw }
        }
        return out
    }

    @discardableResult
    public func pull(into store: CookieStore, knownSites: [(id: String, name: String, host: String)] = []) throws -> PullResult {
        let raws = try fetch()
        var imported = 0
        var skipped = 0
        for (host, raw) in raws {
            let h: String
            if knownSites.isEmpty {
                h = host
            } else if let m = Self.matchSite(host, knownSites: knownSites) {
                h = m
            } else {
                skipped += 1
                continue
            }
            store.importRawString(host: h, raw)
            imported += 1
        }
        guard imported > 0 else {
            throw BoxSendError.badInput("CookieCloud 的条目无法匹配到已添加站点（请在扩展中勾选 PT 站域名后重新同步）")
        }
        return PullResult(imported: imported, skipped: skipped)
    }
}

