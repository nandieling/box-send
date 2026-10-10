import Foundation

/// 导入 PT-depiler「本地备份」导出的加密 zip（PTD_backup_*.zip）。
/// 结构: manifest.json（明文）+ <字段>.json（CryptoJS.AES 加密，口令 = MD5(备份密码) 前 16 位 hex）。
public enum PTDZipImport {
    public static func importZip(url: URL, password: String, into store: CookieStore) throws -> Int {
        let files = try Platform.unzip(url)

        guard let mdata = lookup(files, "manifest.json") else {
            throw BoxSendError.badInput("未找到 manifest.json（不是 PT-depiler 备份 zip？）")
        }
        guard let manifest = (try? JSONSerialization.jsonObject(with: mdata)) as? [String: Any] else {
            throw BoxSendError.badInput("manifest.json 解析失败")
        }
        let encrypted = manifest["encryption"] as? Bool ?? false
        let fileMap = manifest["files"] as? [String: [String: Any]]
        guard let fn = fileMap?["cookies"]?["name"] as? String else {
            throw BoxSendError.badInput("备份中没有 cookies（PT-depiler 备份时请勾选 Cookie 字段）")
        }
        guard let blob = lookup(files, fn), let content = String(data: blob, encoding: .utf8) else {
            throw BoxSendError.badInput("读取 \(fn) 失败")
        }
        let plain: Data
        if encrypted {
            guard !password.isEmpty else {
                throw BoxSendError.badInput("备份已加密，请输入 PT-depiler 设置里的备份密码")
            }
            let pass = String(CryptoJSCompat.md5(Data(password.utf8)).hexString.prefix(16))
            plain = try CryptoJSCompat.decryptOpenSSL(base64: content, password: pass)
        } else {
            plain = Data(content.utf8)
        }
        return try store.replace(from: plain)
    }

    /// 归档里的路径可能带目录前缀（不同解压命令给出的条目名不一致），按最后一段兜底匹配
    private static func lookup(_ files: [String: Data], _ name: String) -> Data? {
        if let d = files[name] { return d }
        for (k, v) in files where k.hasSuffix("/" + name) { return v }
        return nil
    }
}
