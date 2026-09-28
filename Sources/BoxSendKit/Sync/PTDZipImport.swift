import Foundation

/// 导入 PT-depiler「本地备份」导出的加密 zip（PTD_backup_*.zip）。
/// 结构: manifest.json（明文）+ <字段>.json（CryptoJS.AES 加密，口令 = MD5(备份密码) 前 16 位 hex）。
public enum PTDZipImport {
    public static func importZip(url: URL, password: String, into store: CookieStore) throws -> Int {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("boxsend-ptd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-o", "-q", url.path, "-d", tmp.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw BoxSendError.badInput("解压失败（不是有效的 zip 文件？）")
        }

        guard let mdata = try? Data(contentsOf: tmp.appendingPathComponent("manifest.json")) else {
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
        guard let content = try? String(data: Data(contentsOf: tmp.appendingPathComponent(fn)), encoding: .utf8) else {
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
}
