import XCTest
@testable import BoxSendKit

final class CookieCloudTests: XCTestCase {

    private let known: [(id: String, name: String, host: String)] = [
        (id: "hdhome", name: "家园", host: "hdhome.org"),
        (id: "hdsky", name: "天空", host: "hdsky.me"),
    ]

    private let cookieJSON = """
    {"cookie_data": {"hdhome.org": [{"name": "uid", "value": "42"}], "hdsky.me": [{"name": "uid", "value": "7"}, {"name": "pass", "value": "x"}]}}
    """

    /// MD5("k1-pw2") 前 16 hex
    private let key16 = "0606e05327294f9f"

    private func runOpenSSL(_ args: [String], stdin: Data) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Pipe()
        try p.run()
        inPipe.fileHandleForWriting.write(stdin)
        inPipe.fileHandleForWriting.closeFile()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return out
    }

    private func fixedCipher(_ plain: Data) throws -> String {
        let hexKey = Array(key16.utf8).map { String(format: "%02x", $0) }.joined()
        let enc = try runOpenSSL(["enc", "-aes-128-cbc", "-K", hexKey,
                                  "-iv", String(repeating: "0", count: 32)], stdin: plain)
        return enc.base64EncodedString()
    }

    func testDeriveKey16() {
        XCTAssertEqual(CookieCloudSync.deriveKey16(key: "abc", password: "test"), "9bc648bcafbcf965")
        XCTAssertEqual(CookieCloudSync.deriveKey16(key: "k1", password: "pw2"), key16)
    }

    func testDecryptLegacyCryptoJS() throws {
        // legacy = CryptoJS.AES / openssl enc -aes-256-cbc -md md5（口令 = key16）
        let enc = try runOpenSSL(["enc", "-aes-256-cbc", "-a", "-md", "md5",
                                  "-pass", "pass:\(key16)"], stdin: Data(cookieJSON.utf8))
        let plain = try CookieCloudSync.decrypt(encrypted: String(data: enc, encoding: .utf8) ?? "",
                                                cryptoType: "legacy", key: "k1", password: "pw2")
        XCTAssertEqual(String(data: plain, encoding: .utf8), cookieJSON)
    }

    func testDecryptFixedIV() throws {
        let b64 = try fixedCipher(Data(cookieJSON.utf8))
        let plain = try CookieCloudSync.decrypt(encrypted: b64, cryptoType: "aes-128-cbc-fixed",
                                                key: "k1", password: "pw2")
        XCTAssertEqual(String(data: plain, encoding: .utf8), cookieJSON)
    }

    func testDecryptWrongPassword() throws {
        let b64 = try fixedCipher(Data(cookieJSON.utf8))
        // 错误密码：PKCS7 校验可能碰巧通过，但结果一定不是合法 JSON
        do {
            let plain = try CookieCloudSync.decrypt(encrypted: b64, cryptoType: "aes-128-cbc-fixed",
                                                    key: "k1", password: "wrong")
            XCTAssertThrowsError(try CookieCloudSync.parseCookieData(plain))
        } catch {
            // 解密阶段直接抛错也算通过
        }
        XCTAssertThrowsError(try CookieCloudSync.decrypt(encrypted: "???", cryptoType: "weird",
                                                         key: "k1", password: "pw2"))
    }

    func testParseCookieData() throws {
        let data = try CookieCloudSync.parseCookieData(Data(cookieJSON.utf8))
        XCTAssertEqual(data["hdhome.org"]?.count, 1)
        XCTAssertEqual(data["hdsky.me"]?.first?["name"] as? String, "uid")
        XCTAssertThrowsError(try CookieCloudSync.parseCookieData(Data("[]".utf8)))
    }

    func testMatchSite() {
        XCTAssertEqual(CookieCloudSync.matchSite("hdhome.org", knownSites: known), "hdhome.org")
        XCTAssertEqual(CookieCloudSync.matchSite(".hdsky.me", knownSites: known), "hdsky.me")
        XCTAssertEqual(CookieCloudSync.matchSite("forum.hdhome.org", knownSites: known), "hdhome.org")
        XCTAssertNil(CookieCloudSync.matchSite("example.com", knownSites: known))
    }

    func testPullImportsIntoStore() throws {
        let withUnknown = """
        {"cookie_data": {"hdhome.org": [{"name": "uid", "value": "42"}], "hdsky.me": [{"name": "uid", "value": "7"}, {"name": "pass", "value": "x"}], "example.com": [{"name": "a", "value": "1"}]}}
        """
        let body = "{\"encrypted\": \"\(try fixedCipher(Data(withUnknown.utf8)))\", \"crypto_type\": \"aes-128-cbc-fixed\"}"
        let client = HTTPClient(cookies: CookieStore(), userAgent: "t")
        var seenURL = ""
        client.performOverride = { req in
            seenURL = req.url?.absoluteString ?? ""
            return .init(status: 200, data: Data(body.utf8), headers: [:], finalURL: "")
        }
        let store = CookieStore()
        let r = try CookieCloudSync(config: .init(host: "http://127.0.0.1:8088/", key: "k1", password: "pw2"),
                                    client: client)
            .pull(into: store, knownSites: known)
        XCTAssertEqual(seenURL, "http://127.0.0.1:8088/get/k1")
        XCTAssertEqual(r.imported, 2)
        XCTAssertEqual(r.skipped, 1)
        XCTAssertEqual(store.cookieHeader(forHost: "hdhome.org"), "uid=42")
        XCTAssertEqual(store.cookieHeader(forHost: "hdsky.me"), "uid=7; pass=x")
    }

    func testPullEmptyThrows() throws {
        let body = "{\"encrypted\": \"\(try fixedCipher(Data(#"{"cookie_data": {}}"#.utf8)))\", \"crypto_type\": \"aes-128-cbc-fixed\"}"
        let client = HTTPClient(cookies: CookieStore(), userAgent: "t")
        client.performOverride = { _ in
            .init(status: 200, data: Data(body.utf8), headers: [:], finalURL: "")
        }
        XCTAssertThrowsError(try CookieCloudSync(config: .init(host: "http://h:8088", key: "k1", password: "pw2"),
                                                 client: client)
            .pull(into: CookieStore(), knownSites: known))
        // 响应缺 encrypted 字段
        let client2 = HTTPClient(cookies: CookieStore(), userAgent: "t")
        client2.performOverride = { _ in
            .init(status: 200, data: Data("{}".utf8), headers: [:], finalURL: "")
        }
        XCTAssertThrowsError(try CookieCloudSync(config: .init(host: "http://h:8088", key: "k1", password: "pw2"),
                                                 client: client2)
            .pull(into: CookieStore(), knownSites: known))
    }
}
