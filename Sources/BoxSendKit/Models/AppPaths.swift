import Foundation

/// 应用默认路径（GUI 与 `box-send` CLI 的 `--app` 默认共用）：
///   macOS    ~/Library/Application Support/BoxSend/boxsend.json
///   Windows  %APPDATA%\BoxSend\boxsend.json
///   同目录 cookies.json / state.json / debug/           运行时数据
public enum AppPaths {
    public static var dir: String {
        let fm = FileManager.default
        if let u = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            let base = u.appendingPathComponent("BoxSend", isDirectory: true)
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            return base.path
        }
        let base = Platform.defaultDataDir
        try? fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        return base
    }
    public static var configFile: String { dir + "/boxsend.json" }
}
