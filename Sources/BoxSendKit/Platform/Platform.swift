import Foundation

/// 平台能力接缝。
///
/// 核心库只依赖 Foundation。图片转码、验证码 OCR、zip 解压这三件事要用操作系统自带的
/// 图形/压缩能力（macOS 走 ImageIO/Vision，Windows 得换一套实现），统一从 `Platform.hooks`
/// 进出：宿主（macOS GUI、Windows WPF、CLI）按需注入等价实现；没注入就退回平台默认实现，
/// 再退回「不做这件事」。宁可少一张截图、少一次自动识别，也不让整条转种流水线失败。
public enum Platform {

    /// 宿主注入的平台能力（全部可选，未注入项各自退回默认实现）
    public struct Hooks {
        /// 截图重编码：缩到 maxPixel 以内并转 JPEG；返回 nil 表示不转，调用方用原图
        public var jpegReencode: ((Data, Int, Float) -> Data?)?
        /// 图片文字识别：返回按可信度从高到低排列的候选原文；
        /// 西里尔形近字转写由核心统一做（见 SeccodeOCR.normalize），宿主只管认字
        public var ocr: ((Data) -> [String])?
        /// zip 解压：返回「归档内路径 -> 内容」，路径用 `/` 分隔
        public var unzip: ((URL) throws -> [String: Data])?
        public init() {}
    }
    public static var hooks = Hooks()

    /// 平台标识（诊断、更新包选择用）
    public static var osName: String {
        #if os(Windows)
        return "windows"
        #elseif os(macOS)
        return "macos"
        #elseif os(Linux)
        return "linux"
        #else
        return "other"
        #endif
    }

    /// 配置与运行时数据的默认目录
    /// （macOS: ~/Library/Application Support/BoxSend，Windows: %APPDATA%\BoxSend）
    public static var defaultDataDir: String {
        #if os(Windows)
        let env = ProcessInfo.processInfo.environment
        if let a = env["APPDATA"], !a.isEmpty { return a + "\\BoxSend" }
        if let h = env["USERPROFILE"], !h.isEmpty { return h + "\\AppData\\Roaming\\BoxSend" }
        return "BoxSend"
        #else
        return NSHomeDirectory() + "/Library/Application Support/BoxSend"
        #endif
    }

    /// 路径展开：`~` 开头按家目录展开；Windows 上另外展开 `%VAR%` 形式的环境变量，
    /// 用户在配置里写 `%APPDATA%\...` 也能用。
    public static func expandPath(_ path: String) -> String {
        var p = path
        if p == "~" {
            p = NSHomeDirectory()
        } else if p.hasPrefix("~/") || p.hasPrefix("~\\") {
            p = NSHomeDirectory() + String(p.dropFirst())
        }
        #if os(Windows)
        if let re = try? NSRegularExpression(pattern: "%([A-Za-z_][A-Za-z0-9_]*)%") {
            let env = ProcessInfo.processInfo.environment
            for _ in 0..<3 {
                let ns = p as NSString
                let hits = re.matches(in: p, range: NSRange(location: 0, length: ns.length))
                guard let m = hits.last else { break }
                let name = ns.substring(with: m.range(at: 1))
                guard let v = env[name], !v.isEmpty else { break }
                p = p.replacingOccurrences(of: "%\(name)%", with: v)
            }
        }
        #endif
        return p
    }

    // MARK: - 默认实现

    /// 解压 zip：优先宿主注入，其次调系统解压命令
    public static func unzip(_ url: URL) throws -> [String: Data] {
        if let h = hooks.unzip { return try h(url) }
        return try commandUnzip(url)
    }

    /// 系统命令行解压：macOS/Linux 用 /usr/bin/unzip，Windows 用系统自带的 tar.exe（Win10+ 内置）
    static func commandUnzip(_ url: URL) throws -> [String: Data] {
        #if os(Windows)
        let prog = "C:/Windows/System32/tar.exe"
        let args = ["-xf", url.path, "-C"]
        #else
        let prog = "/usr/bin/unzip"
        let args = ["-o", "-q", url.path, "-d"]
        #endif
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("boxsend-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: prog)
        p.arguments = args + [tmp.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            throw BoxSendError.badInput("解压失败（找不到 \(prog)？）")
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw BoxSendError.badInput("解压失败（不是有效的 zip 文件？）")
        }

        var out = [String: Data]()
        let base = tmp.standardizedFileURL.path
        guard let en = FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: nil) else {
            return out
        }
        for case let f as URL in en {
            let full = f.standardizedFileURL.path
            guard full.hasPrefix(base) else { continue }
            var key = String(full.dropFirst(base.count))
            while key.hasPrefix("/") || key.hasPrefix("\\") { key.removeFirst() }
            key = key.replacingOccurrences(of: "\\", with: "/")
            if let d = try? Data(contentsOf: f) { out[key] = d }
        }
        return out
    }
}
