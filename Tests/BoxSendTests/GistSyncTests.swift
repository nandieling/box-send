import XCTest
@testable import BoxSendKit

final class GistSyncTests: XCTestCase {

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

    /// 构造 gist API 响应：_manifest.json + openssl 加密的 cookies.txt
    private func gistResponse(userKey: String, gistID: String) throws -> Data {
        let cookieJSON = """
        {"hdsky.me": [{"name": "id", "value": "abc123"}], "ttg.wiki": [{"name": "id", "value": "t7"}, {"name": "pw", "value": "z9"}]}
        """
        let pass = CryptoJSCompat.gistPassword(userKey: userKey, gistID: gistID)
        let b64 = try runOpenSSL(["enc", "-aes-256-cbc", "-a", "-md", "md5", "-pass", "pass:\(pass)"],
                                 stdin: Data(cookieJSON.utf8))
        let b64Str = String(data: b64, encoding: .utf8)!.filter { !$0.isNewline }
        let manifest = #"{"time":1700000000000,"files":{"cookies":{"name":"cookies.txt"}}}"#
        let files: [String: [String: String]] = [
            "_manifest.json": ["content": manifest],
            "cookies.txt": ["content": b64Str],
        ]
        return try JSONSerialization.data(withJSONObject: ["files": files])
    }

    func testFetchDecryptsAndParses() throws {
        let userKey = "k1", gistID = "gist123"
        let client = HTTPClient(cookies: CookieStore(), userAgent: "t")
        client.performOverride = { req in
            XCTAssertEqual(req.url?.absoluteString, "https://api.github.com/gists/gist123")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            return HTTPClient.Response(status: 200,
                                       data: try self.gistResponse(userKey: userKey, gistID: gistID),
                                       headers: [:],
                                       finalURL: req.url!.absoluteString)
        }
        let f = try GistSync(config: GistSyncConfig(gistID: gistID, token: "tok",
                                                    encryptionKey: userKey, pollMinutes: 30),
                             client: client).fetch()
        XCTAssertTrue(f.backupTime.hasPrefix("2023-11-1"), "got \(f.backupTime)")
        let obj = try JSONSerialization.jsonObject(with: f.data) as? [String: Any]
        let arr = obj?["hdsky.me"] as? [[String: Any]]
        XCTAssertEqual(arr?.count, 1)
        XCTAssertEqual(arr?.first?["name"] as? String, "id")
        XCTAssertEqual(arr?.first?["value"] as? String, "abc123")
        let arr2 = obj?["ttg.wiki"] as? [[String: Any]]
        XCTAssertEqual(arr2?.count, 2)
    }

    func testPullImportsIntoStore() throws {
        let userKey = "k1", gistID = "gist123"
        let client = HTTPClient(cookies: CookieStore(), userAgent: "t")
        client.performOverride = { req in
            HTTPClient.Response(status: 200,
                                data: try self.gistResponse(userKey: userKey, gistID: gistID),
                                headers: [:],
                                finalURL: req.url!.absoluteString)
        }
        let store = CookieStore()
        let stateDir = (NSTemporaryDirectory() + "boxesend-gist-test-\(UUID().uuidString)")
        let state = StateStore(dataDir: stateDir)
        let r = try GistSync(config: GistSyncConfig(gistID: gistID, token: "tok",
                                                    encryptionKey: userKey, pollMinutes: 30),
                             client: client).pull(into: store, state: state)
        XCTAssertEqual(r.cookieCount, 3)
        XCTAssertNotNil(store.cookieHeader(forHost: "hdsky.me"))
        XCTAssertNotNil(store.cookieHeader(forHost: "ttg.wiki"))
        XCTAssertGreaterThan(state.lastGistSync ?? 0, 0)
        try? FileManager.default.removeItem(atPath: stateDir)
    }
}
