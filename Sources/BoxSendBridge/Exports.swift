import Foundation
import BoxSendKit

/// 给宿主界面（Windows WPF，或任何能 P/Invoke 的语言）用的 C ABI。
///
/// 全部字符串走 UTF-8、NUL 结尾；返回的字符串由本模块分配，宿主必须用 `boxsend_free` 归还
/// （由同一模块分配并释放，避免跨模块 CRT 堆不一致）。
/// 识别器回调用「宿主往给定缓冲区里写」的形式，跨边界不传所有权，少一类内存泄漏。
///
/// 用法：`boxsend_create` 拿句柄 -> 反复 `boxsend_invoke` -> `boxsend_destroy`。
/// 所有耗时动作在服务内部后台线程执行，宿主轮询 `snapshot` / `events` 取进度。

/// (种子图片字节, 长度, 输出缓冲区, 缓冲区容量) -> 写入字节数；写 0 表示没认出来。
/// 多个候选用换行分隔，形近字转写由核心做。
public typealias OcrCallback = @convention(c) (
    UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<CChar>?, Int) -> Int32

private final class Holder {
    let service: AppService
    init(_ service: AppService) { self.service = service }
}

@_cdecl("boxsend_create")
public func boxsend_create(_ configPath: UnsafePointer<CChar>?,
                          _ dataDir: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    Trace.mark("create 进来")
    let path = configPath.map { String(cString: $0) }
    let dir = dataDir.map { String(cString: $0) }
    do {
        let cfgPath = path ?? AppPaths.configFile
        // 数据目录以宿主给的为准：配置里可能留着历史相对值（".boxsend"），那样 state.json、
        // cookies.json 会掉到进程工作目录里去——装在 Program Files 下就写不进去。
        // macOS 版 GUI 也是这么做的（AppModel 里同一句注释）
        let dataDir = dir ?? AppPaths.dir
        Trace.mark("要读的配置：\(cfgPath)，数据目录：\(dataDir)")
        let svc = try AppService(configPath: cfgPath, dataDir: dataDir)
        Trace.mark("服务建好了")
        return Unmanaged.passRetained(Holder(svc)).toOpaque()
    } catch {
        lastError = "\(error)"
        Trace.mark("建服务抛错：\(error)")
        return nil
    }
}

private var lastError = ""

@_cdecl("boxsend_last_error")
public func boxsend_last_error() -> UnsafePointer<CChar>? {
    UnsafePointer(strdup(lastError))
}

/// 入参：`{"method":"snapshot","params":{...}}`；返回：`{"ok":true,"result":{...}}`
@_cdecl("boxsend_invoke")
public func boxsend_invoke(_ handle: UnsafeMutableRawPointer?,
                          _ requestJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let handle else { return strdup(#"{"ok":false,"error":"句柄无效"}"#) }
    let holder = Unmanaged<Holder>.fromOpaque(handle).takeUnretainedValue()
    let req = requestJSON.map { String(cString: $0) } ?? "{}"
    Trace.mark("invoke 进来：\(req.prefix(48))")
    let answer = holder.service.invokeJSON(req)
    Trace.mark("invoke 答了 \(answer.utf8.count) 字节")
    return strdup(answer)
}

/// 释放 boxsend_invoke / boxsend_last_error 返回的字符串
@_cdecl("boxsend_free")
public func boxsend_free(_ ptr: UnsafeMutablePointer<CChar>?) {
    guard let ptr else { return }
    ptr.deallocate()
}

/// 注入宿主的验证码识别器（Windows 用 Windows.Media.Ocr）。传 null 撤销注入。
@_cdecl("boxsend_set_ocr")
public func boxsend_set_ocr(_ handle: UnsafeMutableRawPointer?, _ fn: OcrCallback?) {
    guard let handle else { return }
    let holder = Unmanaged<Holder>.fromOpaque(handle).takeUnretainedValue()
    guard let fn else {
        Platform.hooks.ocr = nil
        return
    }
    Platform.hooks.ocr = { data in
        let outCap = 512
        var buf = [CChar](repeating: 0, count: outCap)
        let n = data.withUnsafeBytes { raw -> Int32 in
            fn(raw.bindMemory(to: UInt8.self).baseAddress, data.count,
               &buf, outCap - 1)
        }
        guard n > 0 else { return [] }
        buf[Int(min(n, Int32(outCap - 1)))] = 0
        return String(cString: buf).split(separator: "\n").map(String.init)
    }
}

@_cdecl("boxsend_version")
public func boxsend_version() -> UnsafeMutablePointer<CChar>? {
    strdup(BoxSendVersion.version)
}

@_cdecl("boxsend_destroy")
public func boxsend_destroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    Unmanaged<Holder>.fromOpaque(handle).release()
}
