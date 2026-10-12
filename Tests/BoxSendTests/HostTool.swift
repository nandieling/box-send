import Foundation
import XCTest

/// 有几条用例要借本机命令行工具造输入（openssl 造密文、zip 打站点备份包），
/// 被测的是核心库的解密与导入逻辑，不是这三个工具本身。机器上没有（Windows runner
/// 就是）时报「跳过」而不是「失败」，否则整套测试在 Windows 上白挂一片。
enum HostTool
{
    static func path(_ name: String) throws -> String
    {
        let p = "/usr/bin/" + name
        guard FileManager.default.isExecutableFile(atPath: p) else { throw XCTSkip("本机没有 \(p)") }
        return p
    }
}
