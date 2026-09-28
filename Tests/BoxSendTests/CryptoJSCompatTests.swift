import XCTest
@testable import BoxSend

final class CryptoJSCompatTests: XCTestCase {

    func testMD5KnownVector() {
        XCTAssertEqual(CryptoJSCompat.md5(Data("abc".utf8)).hexString,
                       "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(CryptoJSCompat.md5(Data()).hexString,
                       "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(CryptoJSCompat.md5(Data("The quick brown fox jumps over the lazy dog".utf8)).hexString,
                       "9e107d9d372bb6826bd81d3542a419d6")
    }

    /// 向量: pass1 = "|TESTGISTID123" -> MD5 前16位 = eaea2c06e5cd6ee5
    func testGistPasswordDerivation() {
        XCTAssertEqual(CryptoJSCompat.gistPassword(userKey: "", gistID: "TESTGISTID123"),
                       "eaea2c06e5cd6ee5")
    }

    /// 向量由 `openssl enc -aes-256-cbc -a -md md5 -pass pass:eaea2c06e5cd6ee5` 生成
    func testDecryptOpenSSLVector() throws {
        let b64 = """
        U2FsdGVkX18k5tzzG/7X48O7mSPXgwcMg5kV6LYmbzmvjPoST9FPvWRl9PTNipEc
        OqBFCnPRx2ChkD12X2k6+ZquOnbgWB4l4nK8Y8bipn7B4TEWjbHguPkkywwOy8Bu
        iH5YlMqqIGpAFqtp7GxMqw==
        """
        let plain = try CryptoJSCompat.decryptOpenSSL(base64: b64, password: "eaea2c06e5cd6ee5")
        let s = String(data: plain, encoding: .utf8)
        XCTAssertEqual(s, #"{"cookies":{"example.org":[{"name":"uid","value":"12345","domain":"example.org","path":"/"}]}}"#)
    }

    func testDecryptPlainJSONPassthrough() throws {
        let s = #"{"a":1}"#
        let plain = try CryptoJSCompat.decryptOpenSSL(base64: Data(s.utf8).base64EncodedString(), password: "x")
        XCTAssertEqual(String(data: plain, encoding: .utf8), s)
    }

    /// FIPS-197 C.3: AES-256 单块已知向量
    func testAESSingleBlock() throws {
        let key = Data((0..<32).map { UInt8($0) })            // 000102..1f
        let plain = Data([0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,
                          0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff])
        let expected = "8ea2b7ca516745bfeafc49904b496089"
        // 加密方向: CBC with iv=0 的单块 == ECB 单块
        let iv = Data(repeating: 0, count: 16)
        let encrypted = try CryptoJSCompat.aes256CBCEncrypt(data: plain, key: [UInt8](key), iv: [UInt8](iv))
        XCTAssertEqual(encrypted.hexString, "8ea2b7ca516745bfeafc49904b49608956423350859cf424d4459534a8f5aaf2")
        // 解密回来
        let decrypted = try CryptoJSCompat.aes256CBCDecrypt(data: encrypted, key: [UInt8](key), iv: [UInt8](iv))
        XCTAssertEqual(decrypted, plain)
    }


    func testAESBlockRoundtrip() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let pt = Data((0..<16).map { UInt8($0 &* 7) })
        let enc = try CryptoJSCompat.aes256CBCEncrypt(data: pt, key: [UInt8](key), iv: [UInt8](repeating: 0, count: 16))
        let raw = try CryptoJSCompat.aes256CBCDecryptRaw(data: enc, key: [UInt8](key), iv: Data(repeating: 0, count: 16))
        XCTAssertEqual(Data(raw.prefix(16)), pt)
        XCTAssertEqual(Data(raw.suffix(16)), Data(repeating: 0x10, count: 16))
    }



    func testAESBlockInverse() {
        let key = [UInt8](0..<32)
        // FIPS-197 C.3: key=000102..1f, pt=00112233..eeff -> ct=8ea2b7ca..
        let x: [UInt8] = [0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff]
        let e = CryptoJSCompat._blockEnc(x, key: key)
        let d = CryptoJSCompat._blockDec(e, key: key)
        XCTAssertEqual(Data(e).hexString, "8ea2b7ca516745bfeafc49904b496089")
        XCTAssertEqual(d, x)
        // 第二个随机块
        let y = [UInt8](0..<16).map { ($0 &* 33) ^ 0x5a }
        let ey = CryptoJSCompat._blockEnc(y, key: key)
        let dy = CryptoJSCompat._blockDec(ey, key: key)
        XCTAssertEqual(dy, y)
    }


}
