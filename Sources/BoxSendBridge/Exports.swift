import Foundation
import BoxSendKit

/// 给宿主界面（Windows WPF，或任何能 P/Invoke 的语言）用的 C ABI。
///
/// 全部字符串走 UTF-8、NUL 结尾；返回的字符串由本模块分配，宿主必须用 `boxsend_free` 归还
/// （分配和释放都走 Swift 分配器，见 `dupString`：跨 CRT 堆释放会直接搞坏堆）。
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

/// 宿主注入的 SSH 执行器（Windows 的密码登录用）。约定：返回 0 = 连上并跑完了，
/// 缓冲区里是命令输出（stdout+stderr 合流）；返回负数 = `SSHSpeedTest.HostFailure` 的类别码，
/// 缓冲区里是原始报错，翻成人话由核心做。实现方最多写 capacity 字节，
/// 缓冲区调用前已整块清零，所以不必自己补结尾 NUL。
public typealias SSHExecCallback = @convention(c) (
    UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32,
    UnsafeMutablePointer<CChar>?, Int32) -> Int32

/// 复制一份 C 字符串，交出去的所有权由 `boxsend_free` 归还。
///
/// 为什么不调 CRT 的复制函数：那是 CRT 的 malloc，而 `boxsend_free` 里的 `deallocate()`
/// 走的是 Swift 分配器。macOS 上两边都是 libSystem 的同一个堆，没事；Windows 上不是
/// 同一个堆，把 CRT 的块交给 Swift 释放（反之亦然）就是 0xC0000374 堆损坏——进程闷声
/// 崩掉，界面上既没窗口也没报错，正是用户看到的那个现象。
private func dupString(_ s: String) -> UnsafeMutablePointer<CChar>?
{
    let bytes = Array(s.utf8)
    let buf = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
    if !bytes.isEmpty {
        bytes.withUnsafeBytes { raw in
            UnsafeMutableRawPointer(buf).copyMemory(from: raw.baseAddress!, byteCount: raw.count)
        }
    }
    buf[bytes.count] = 0
    return buf
}

private var lastError = ""

@_cdecl("boxsend_last_error")
public func boxsend_last_error() -> UnsafePointer<CChar>? {
    UnsafePointer(dupString(lastError))
}

/// 入参：`{"method":"snapshot","params":{...}}`；返回：`{"ok":true,"result":{...}}`
@_cdecl("boxsend_invoke")
public func boxsend_invoke(_ handle: UnsafeMutableRawPointer?,
                          _ requestJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let handle else { return dupString(#"{"ok":false,"error":"句柄无效"}"#) }
    let holder = Unmanaged<Holder>.fromOpaque(handle).takeUnretainedValue()
    let req = requestJSON.map { String(cString: $0) } ?? "{}"
    Trace.mark("invoke 进来：\(req.prefix(48))")
    let answer = holder.service.invokeJSON(req)
    Trace.mark("invoke 答了 \(answer.utf8.count) 字节")
    return dupString(answer)
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

/// 注入宿主的 SSH 执行器（Windows 用 SSH.NET 做密码登录）。传 null 撤销注入。
@_cdecl("boxsend_set_ssh_exec")
public func boxsend_set_ssh_exec(_ handle: UnsafeMutableRawPointer?, _ fn: SSHExecCallback?) {
    guard let handle else { return }
    let holder = Unmanaged<Holder>.fromOpaque(handle).takeUnretainedValue()
    guard let fn else {
        Platform.hooks.sshExec = nil
        return
    }
    Platform.hooks.sshExec = { req in
        let cap = 16_384
        var buf = [CChar](repeating: 0, count: cap)
        let code = req.host.withCString { h in
            req.user.withCString { u in
                req.password.withCString { pw in
                    req.keyPath.withCString { key in
                        req.script.withCString { script in
                            fn(h, Int32(req.port), u, pw, key, script,
                               Int32(req.timeoutSeconds), &buf, Int32(cap - 1))
                        }
                    }
                }
            }
        }
        let text = String(cString: buf)
        guard code != 0 else { return text }
        throw BoxSendError.badInput(
            (SSHSpeedTest.HostFailure(rawValue: Int(code)) ?? .other).message(text))
    }
}

@_cdecl("boxsend_version")
public func boxsend_version() -> UnsafeMutablePointer<CChar>? {
    dupString(BoxSendVersion.version)
}

@_cdecl("boxsend_destroy")
public func boxsend_destroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    Unmanaged<Holder>.fromOpaque(handle).release()
}
