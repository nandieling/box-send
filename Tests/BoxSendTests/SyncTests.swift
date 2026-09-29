import XCTest
@testable import BoxSendKit

final class SyncTests: XCTestCase {
    /// 用系统 zip 命令生成一个最小可用的 PT-depiler 明文备份 zip
    private func makeBackupZip(in dir: String, name: String) throws {
        let src = dir + "/src-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
        let manifest = #"{"encryption": false, "files": {"cookies": {"name": "cookies.json"}}}"#
        try manifest.write(toFile: src + "/manifest.json", atomically: true, encoding: .utf8)
        let cookies = #"{"cookies": {"hdsky.me": [{"name": "uid", "value": "42"}]}}"#
        try cookies.write(toFile: src + "/cookies.json", atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-q", dir + "/" + name, "manifest.json", "cookies.json"]
        p.currentDirectoryPath = src
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        try? FileManager.default.removeItem(atPath: src)
    }

    func testZipWatcherImportAndDedup() throws {
        let dir = NSTemporaryDirectory() + "zipwatch-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try makeBackupZip(in: dir, name: "PTD_backup_2026-09-29.zip")
        // 非匹配文件应被忽略
        try "x".write(toFile: dir + "/notes.txt", atomically: true, encoding: .utf8)

        let store = CookieStore()
        let st = StateStore(dataDir: dir + "/state")
        let imported = ZipWatcher.scanOnce(dir: dir, password: "", store: store, state: st)
        XCTAssertEqual(imported, ["PTD_backup_2026-09-29.zip"])
        XCTAssertEqual(store.snapshot()["hdsky.me"]?.count, 1)
        // 第二次扫描不重复导入
        XCTAssertTrue(ZipWatcher.scanOnce(dir: dir, password: "", store: store, state: st).isEmpty)
        // 无效 zip：不崩溃、不标记（下次重试）
        let bad = dir + "/PTD_backup_bad.zip"
        try Data("not a zip".utf8).write(to: URL(fileURLWithPath: bad))
        XCTAssertTrue(ZipWatcher.scanOnce(dir: dir, password: "", store: store, state: st).isEmpty)
        XCTAssertFalse(st.isZipImported(name: "PTD_backup_bad.zip"))
        // 持久化：重启后仍记得已导入
        let st2 = StateStore(dataDir: dir + "/state")
        XCTAssertTrue(st2.isZipImported(name: "PTD_backup_2026-09-29.zip"))
    }
}
