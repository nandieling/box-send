import Foundation

/// 启动路标。设了环境变量 `BOXSEND_TRACE`（值是文件路径）就往那个文件追加一行，
/// 没设就什么都不做——正常跑起来一分钱开销都没有（环境变量只在第一次调用时读一次）。
///
/// 存在的理由：Windows 界面是双击启动的 WinExe，核心库要是卡在初始化里，界面上
/// 既没窗口也没报错，什么也看不见。有这些行才能知道停在第几步。
public enum Trace
{
    private static let path: String? = ProcessInfo.processInfo.environment["BOXSEND_TRACE"]
    private static let started = Date()

    public static func mark(_ what: String)
    {
        guard let path, !path.isEmpty else { return }
        // 带上相对耗时：只有「慢」和「卡死」得区分开，光看步数看不出来
        let ms = Int(Date().timeIntervalSince(Self.started) * 1_000)
        let line = "core: +\(ms)ms \(what)\n"
        guard let data = line.data(using: .utf8) else { return }
        // 界面那边也在写这个文件，所以拿不开就直接放弃：覆盖写会把前面几步抹掉，
        // 反而把要看的线索弄丢
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data, attributes: nil)
        }
    }
}
