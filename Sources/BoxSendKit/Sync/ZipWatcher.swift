import Foundation

/// PT-depiler 备份目录监控：扫描目录下新增的 PTD_backup*.zip 并自动导入。
/// 已导入的文件名记录在 state.importedZips，避免重复导入（失败的不标记，下次重试）。
public enum ZipWatcher {
    public static func scanOnce(dir: String, password: String, store: CookieStore, state: StateStore) -> [String] {
        let path = Platform.expandPath(dir)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return []
        }
        var imported: [String] = []
        for name in items.sorted() where name.hasPrefix("PTD_backup") && name.hasSuffix(".zip") {
            if state.isZipImported(name: name) { continue }
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            do {
                let n = try PTDZipImport.importZip(url: url, password: password, into: store)
                state.markZipImported(name: name)
                state.note("zipwatch: 导入 \(name) -> \(n) 条 cookie")
                imported.append(name)
            } catch {
                state.note("zipwatch: \(name) 导入失败: \(error.localizedDescription)")
            }
        }
        return imported
    }
}
