import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// 极简 HTTP/1.1 服务器：纯 socket 实现，macOS/Linux/Windows 通用，Connection: close，线程每连接。
final class HTTPServer {
    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]   // 小写 key
        var body: Data
    }

    struct Response {
        var status: Int
        var contentType: String
        var body: Data

        init(_ status: Int, _ contentType: String, _ body: Data) {
            self.status = status
            self.contentType = contentType
            self.body = body
        }

        static func json(_ obj: Any, status: Int = 200) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]))
                ?? Data("{\"ok\":false}".utf8)
            return Response(status, "application/json; charset=utf-8", data)
        }

        static var notFound: Response { .json(["ok": false, "error": "not found"], status: 404) }
        static var unauthorized: Response { .json(["ok": false, "error": "unauthorized"], status: 401) }
    }

    typealias Handler = (Request) -> Response

    private var serverFD: SocketFD = invalidSocket
    private var handler: Handler = { _ in .notFound }
    /// bind 后的实际端口（port=0 时由系统分配）
    var assignedPort: Int = 0

    func start(host: String, port: Int, handler: @escaping Handler) throws {
        self.handler = handler
        platformSocketStartup()

        #if os(Windows)
        // WinSDK 把 SOCK_STREAM 导成带枚举包装的类型，跨 SDK 取字面值最稳（1 = 流式）
        let fd = socket(AF_INET, Int32(1), 0)
        #else
        #if canImport(Glibc)
        let type = Int32(SOCK_STREAM.rawValue)
        #else
        let type = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, type, 0)
        #endif
        guard fd != invalidSocket else {
            throw BoxSendError.badInput("socket() 失败（errno \(platformSocketErrno())）")
        }
        platformSetReuseAddr(fd)

        var addr = sockaddr_in()          // 全零 = INADDR_ANY
        #if os(Windows)
        // WinSDK 里 sa_family_t 只是 ADDRESS_FAMILY 的 #define 别名，没被导入；字段本身是 ushort，
        // 直接给 AF_INET 的字面值让类型自己推
        addr.sin_family = 2
        #else
        addr.sin_family = sa_family_t(AF_INET)
        #endif
        addr.sin_port = UInt16(port).bigEndian
        if host != "0.0.0.0" && host != "::" {
            guard let v4 = Self.parseIPv4(host) else {
                throw BoxSendError.badInput("非法 host: \(host)")
            }
            #if os(Windows)
            // Windows 的 in_addr 是带 union 的结构，直接按 4 字节写入网络序
            withUnsafeMutableBytes(of: &addr.sin_addr) { $0.storeBytes(of: v4, as: UInt32.self) }
            #else
            addr.sin_addr = in_addr(s_addr: v4)
            #endif
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            platformSocketClose(fd)
            throw BoxSendError.badInput("bind \(host):\(port) 失败（端口被占用?）")
        }
        var sa = addr
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        assignedPort = Int(UInt16(bigEndian: sa.sin_port))
        guard listen(fd, 32) == 0 else {
            platformSocketClose(fd)
            throw BoxSendError.badInput("listen 失败")
        }
        serverFD = fd
    }

    /// 阻塞 accept 循环（在独立线程调用）
    func run() {
        while serverFD != invalidSocket {
            var caddr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let cfd = accept(serverFD, &caddr, &len)
            guard cfd != invalidSocket else { continue }
            let h = handler
            Thread.detachNewThread { self.serve(cfd, handler: h) }
        }
    }

    private func serve(_ fd: SocketFD, handler: Handler) {
        defer { platformSocketClose(fd) }
        let data = readRequest(fd)
        guard let data else { return }
        guard let req = parse(data) else {
            platformSendAll(fd, Data(Response.json(["ok": false, "error": "bad request"], status: 400).head()))
            return
        }
        let resp = handler(req)
        platformSendAll(fd, resp.head() + resp.body)
    }

    private func readRequest(_ fd: SocketFD) -> [UInt8]? {
        var data = [UInt8]()
        var tmp = [UInt8](repeating: 0, count: 4096)
        let marker: [UInt8] = [0x0d, 0x0a, 0x0d, 0x0a]
        while true {
            let n = tmp.withUnsafeMutableBufferPointer { platformRecv(fd, $0.baseAddress!, $0.count) }
            guard n > 0 else { return data.isEmpty ? nil : data }
            data.append(contentsOf: tmp[0..<n])
            guard let hEnd = Self.find(marker, in: data) else {
                if data.count > 1_048_576 { return nil }   // 头部超限
                continue
            }
            let head = String(bytes: data[0..<hEnd], encoding: .utf8) ?? ""
            let cl = head.lowercased()
                .split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
            if data.count >= hEnd + 4 + cl { return data }
            if cl > 2_097_152 { return nil }
        }
    }

    private func parse(_ data: [UInt8]) -> Request? {
        guard let hEnd = Self.find([0x0d, 0x0a, 0x0d, 0x0a], in: data) else { return nil }
        guard let head = String(bytes: data[0..<hEnd], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])
        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let k = kv.first?.urlDecoded ?? ""
                let v = kv.count > 1 ? kv[1].urlDecoded : ""
                if !k.isEmpty { query[k] = v }
            }
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where line.contains(":") {
            let kv = line.split(separator: ":", maxSplits: 1)
            headers[String(kv[0]).trimmingCharacters(in: .whitespaces).lowercased()] =
                String(kv[1]).trimmingCharacters(in: .whitespaces)
        }
        let body = Data(data[(hEnd + 4)...])
        return Request(method: String(parts[0]).uppercased(), path: path,
                       query: query, headers: headers, body: body)
    }

    /// 点分十进制 IPv4 -> 网络字节序。不用 inet_pton：它在 Windows 的 SDK 里符号导入不稳定。
    static func parseIPv4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: UInt32 = 0
        for p in parts {
            guard p.count <= 3, let n = Int(p), (0...255).contains(n) else { return nil }
            out = (out << 8) | UInt32(n)
        }
        return out.bigEndian
    }

    private static func find(_ seq: [UInt8], in data: [UInt8]) -> Int? {
        guard data.count >= seq.count else { return nil }
        outer: for i in 0...(data.count - seq.count) {
            for j in 0..<seq.count where data[i + j] != seq[j] { continue outer }
            return i
        }
        return nil
    }
}

extension HTTPServer.Response {
    func head() -> Data {
        let reason: [Int: String] = [200: "OK", 201: "Created", 400: "Bad Request", 401: "Unauthorized",
                                     404: "Not Found", 405: "Method Not Allowed", 500: "Internal Server Error"]
        let lines = [
            "HTTP/1.1 \(status) \(reason[status] ?? "")",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "Cache-Control: no-store",
            "",
            "",
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }
}

extension StringProtocol {
    var urlDecoded: String {
        let s = String(self).replacingOccurrences(of: "+", with: " ")
        return s.removingPercentEncoding ?? s
    }
}

// MARK: - socket 平台差异

#if os(Windows)
private typealias SocketFD = SOCKET
private let invalidSocket: SocketFD = INVALID_SOCKET

/// Windows 用 socket 前必须初始化 Winsock（重复调用无副作用，进程退出不必 Cleanup）
private func platformSocketStartup() {
    var wsa = WSADATA()
    _ = WSAStartup(0x0202, &wsa)
}
private func platformSocketErrno() -> Int { Int(WSAGetLastError()) }
private func platformSocketClose(_ fd: SocketFD) { closesocket(fd) }
private func platformSetReuseAddr(_ fd: SocketFD) {
    var one: Int32 = 1
    // optval 要 const char *：按原始字节转一次，避开跨 SDK 的 withMemoryRebound 签名差异
    withUnsafeBytes(of: &one) {
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0.bindMemory(to: CChar.self).baseAddress,
                       Int32(MemoryLayout<Int32>.size))
    }
}
private func platformRecv(_ fd: SocketFD, _ buf: UnsafeMutableRawPointer, _ len: Int) -> Int {
    Int(recv(fd, buf.bindMemory(to: CChar.self, capacity: len), Int32(len), 0))
}
private func platformSend(_ fd: SocketFD, _ p: UnsafeRawPointer, _ len: Int) -> Int {
    Int(send(fd, p.bindMemory(to: CChar.self, capacity: len), Int32(len), 0))
}
#else
private typealias SocketFD = Int32
private let invalidSocket: SocketFD = -1

private func platformSocketStartup() {}
private func platformSocketErrno() -> Int { Int(errno) }
private func platformSocketClose(_ fd: SocketFD) { close(fd) }
private func platformSetReuseAddr(_ fd: SocketFD) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
}
private func platformRecv(_ fd: SocketFD, _ buf: UnsafeMutableRawPointer, _ len: Int) -> Int {
    Int(recv(fd, buf, len, 0))
}
private func platformSend(_ fd: SocketFD, _ p: UnsafeRawPointer, _ len: Int) -> Int {
    Int(send(fd, p, len, 0))
}
#endif

private func platformSendAll(_ fd: SocketFD, _ data: Data) {
    var sent = 0
    while sent < data.count {
        let n = data.withUnsafeBytes { platformSend(fd, $0.baseAddress!.advanced(by: sent), data.count - sent) }
        if n <= 0 { return }
        sent += n
    }
}
