import Foundation

/// 启动路标。设了环境变量 `BOXSEND_TRACE`（值是文件路径）就往那个文件追加一行，
/// 没设就什么都不做——正常跑起来一分钱开销都没有（环境变量只在第一次调用时读一次）。
///
/// 存在的理由：Windows 界面是双击启动的 WinExe，核心库要是卡在初始化里，界面上
/// 既没窗口也没报错，什么也看不见。有这些行才能知道停在第几步。
public enum Trace
{
    private static let path: String? = ProcessInfo.processInfo.environment["BOXSEND_TRACE"]

    public static func mark(_ what: String)
    {
        guard let path, !path.isEmpty else { return }
        let line = "core: \(what)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
