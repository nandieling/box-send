import Foundation

/// 与 CryptoJS (OpenSSL 格式) 兼容的解密工具。
/// PT-depiler 的 Gist 备份: AES-256-CBC, 口令派生 = EVP_BytesToKey(MD5)。
/// 实际口令 = MD5(userKey + "|" + gistID) 的前 16 个 hex 字符。
enum CryptoJSCompat {

    // MARK: - MD5

    static func md5(_ data: Data) -> Data {
        let K: [UInt32] = [
            0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
            0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
            0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
            0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
            0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
            0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
            0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
            0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
            0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
            0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
            0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
            0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
            0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
            0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
            0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
            0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
        ]
        let s: [Int] = [
            7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
            5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
            4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
            6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
        ]

        func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

        var msg = [UInt8](data)
        let bitLen = UInt64(data.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in 0..<8 { msg.append(UInt8((bitLen >> (8 * i)) & 0xff)) }

        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xefcdab89
        var c0: UInt32 = 0x98badcfe
        var d0: UInt32 = 0x10325476

        for chunkStart in stride(from: 0, to: msg.count, by: 64) {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let o = chunkStart + i * 4
                m[i] = UInt32(msg[o]) | (UInt32(msg[o + 1]) << 8)
                     | (UInt32(msg[o + 2]) << 16) | (UInt32(msg[o + 3]) << 24)
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                let f: UInt32
                let g: Int
                switch i {
                case 0..<16: f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                let tmp = d
                d = c
                c = b
                let x = a &+ f &+ K[i] &+ m[g]
                b = b &+ rotl(x, UInt32(s[i]))
                a = tmp
            }
            a0 &+= a; b0 &+= b; c0 &+= c; d0 &+= d
        }
        var out = Data(capacity: 16)
        for w in [a0, b0, c0, d0] {
            withUnsafeBytes(of: w.littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }

    // MARK: - AES (256-bit)



    /// 标准 AES S-box（独立实现，供测试比对）
    static let aesSbox: [UInt8] = {
        let std: [UInt8] = [
            0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
            0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
            0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
            0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
            0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
            0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
            0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
            0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
            0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
            0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
            0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
            0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
            0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
            0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
            0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
            0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
        ]
        return std
    }()

    private static func invSboxFrom(_ s: [UInt8]) -> [UInt8] {
        var inv = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 { inv[Int(s[i])] = UInt8(i) }
        return inv
    }
    private static let isbox: [UInt8] = invSboxFrom(aesSbox)
    private static let gfMul2: [UInt8] = {
        var t = [UInt8](repeating: 0, count: 256)
        for x in 0..<256 {
            let c = UInt8(x)
            t[x] = (c << 1) ^ ((c & 0x80) != 0 ? 0x1b : 0)
        }
        return t
    }()

    private static func gfMul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var p: UInt8 = 0
        var bb = b
        var aa = a
        while bb > 0 {
            if bb & 1 == 1 { p ^= aa }
            let hi = aa & 0x80
            aa = (aa << 1) ^ ((hi != 0) ? 0x1b : 0)
            bb >>= 1
        }
        return p
    }

    /// AES-256 密钥扩展
    private static func expandKey(_ key: [UInt8]) -> [[UInt8]] {
        precondition(key.count == 32)
        var w = [[UInt8]]()
        for i in 0..<8 { w.append(Array(key[i * 4..<(i + 1) * 4])) }
        for i in 8..<60 {
            var temp = w[i - 1]
            if i % 8 == 0 {
                temp = [temp[1], temp[2], temp[3], temp[0]]
                temp = temp.map { aesSbox[Int($0)] }
                temp[0] ^= rcon[i / 8 - 1]
            } else if i % 8 == 4 {
                temp = temp.map { aesSbox[Int($0)] }
            }
            w.append([w[i - 8][0] ^ temp[0], w[i - 8][1] ^ temp[1], w[i - 8][2] ^ temp[2], w[i - 8][3] ^ temp[3]])
        }
        return w
    }

    private static let rcon: [UInt8] = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36]

    private static func blockDecrypt(_ block: [UInt8], w: [[UInt8]]) -> [UInt8] {
        // state: 列优先
        var st = [UInt8](repeating: 0, count: 16)
        for c in 0..<4 { for r in 0..<4 { st[c * 4 + r] = block[c * 4 + r] } }
        // 注意: FIPS 标准 state[r][c] = in[r + 4c]
        func addRoundKey(_ round: Int) {
            for c in 0..<4 {
                for r in 0..<4 {
                    st[c * 4 + r] ^= w[round * 4 + c][r]
                }
            }
        }
        func invShiftRows() {
            for r in 1..<4 {
                let col = (r % 4)
                var rowVals: [UInt8] = []
                for c in 0..<4 { rowVals.append(st[c * 4 + r]) }
                for c in 0..<4 { st[c * 4 + r] = rowVals[(c - col + 4) % 4] }
            }
        }
        func invSubBytes() {
            for i in 0..<16 { st[i] = isbox[Int(st[i])] }
        }
        func invMixColumns() {
            for c in 0..<4 {
                let a0 = st[c * 4 + 0], a1 = st[c * 4 + 1], a2 = st[c * 4 + 2], a3 = st[c * 4 + 3]
                st[c * 4 + 0] = gfMul(a0, 14) ^ gfMul(a1, 11) ^ gfMul(a2, 13) ^ gfMul(a3, 9)
                st[c * 4 + 1] = gfMul(a0, 9) ^ gfMul(a1, 14) ^ gfMul(a2, 11) ^ gfMul(a3, 13)
                st[c * 4 + 2] = gfMul(a0, 13) ^ gfMul(a1, 9) ^ gfMul(a2, 14) ^ gfMul(a3, 11)
                st[c * 4 + 3] = gfMul(a0, 11) ^ gfMul(a1, 13) ^ gfMul(a2, 9) ^ gfMul(a3, 14)
            }
        }
        addRoundKey(14)
        for round in stride(from: 13, through: 1, by: -1) {
            invShiftRows()
            invSubBytes()
            addRoundKey(round)
            invMixColumns()
        }
        invShiftRows()
        invSubBytes()
        addRoundKey(0)
        var out = [UInt8](repeating: 0, count: 16)
        for c in 0..<4 { for r in 0..<4 { out[c * 4 + r] = st[c * 4 + r] } }
        return out
    }

    // 测试用：单块加解密
    static func _blockEnc(_ x: [UInt8], key: [UInt8]) -> [UInt8] { blockEncrypt(x, w: expandKey(key)) }
    static func _blockDec(_ x: [UInt8], key: [UInt8]) -> [UInt8] { blockDecrypt(x, w: expandKey(key)) }

    /// AES-256-CBC 加密（PKCS7），供测试与未来加密用途
    static func aes256CBCEncrypt(data: Data, key: [UInt8], iv: [UInt8]) throws -> Data {
        let w = expandKey(key)
        var padded = Data(data)
        let pad = 16 - (data.count % 16)
        padded.append(contentsOf: [UInt8](repeating: UInt8(pad), count: pad))
        var out = Data(capacity: padded.count)
        var prev = Array(iv)
        let bytes = [UInt8](padded)
        for off in stride(from: 0, to: bytes.count, by: 16) {
            var plain = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 { plain[i] = bytes[off + i] ^ prev[i] }
            let cipher = blockEncrypt(plain, w: w)
            out.append(contentsOf: cipher)
            prev = cipher
        }
        return out
    }

    private static func blockEncrypt(_ block: [UInt8], w: [[UInt8]]) -> [UInt8] {
        var st = [UInt8](repeating: 0, count: 16)
        for c in 0..<4 { for r in 0..<4 { st[c * 4 + r] = block[c * 4 + r] } }
        func addRoundKey(_ round: Int) {
            for c in 0..<4 {
                for r in 0..<4 {
                    st[c * 4 + r] ^= w[round * 4 + c][r]
                }
            }
        }
        func subBytes() {
            for i in 0..<16 { st[i] = aesSbox[Int(st[i])] }
        }
        func shiftRows() {
            for r in 1..<4 {
                var rowVals: [UInt8] = []
                for c in 0..<4 { rowVals.append(st[c * 4 + r]) }
                for c in 0..<4 { st[c * 4 + r] = rowVals[(c + r) % 4] }
            }
        }
        func mixColumns() {
            for c in 0..<4 {
                let a0 = st[c * 4 + 0], a1 = st[c * 4 + 1], a2 = st[c * 4 + 2], a3 = st[c * 4 + 3]
                st[c * 4 + 0] = gfMul(a0, 2) ^ gfMul(a1, 3) ^ a2 ^ a3
                st[c * 4 + 1] = a0 ^ gfMul(a1, 2) ^ gfMul(a2, 3) ^ a3
                st[c * 4 + 2] = a0 ^ a1 ^ gfMul(a2, 2) ^ gfMul(a3, 3)
                st[c * 4 + 3] = gfMul(a0, 3) ^ a1 ^ a2 ^ gfMul(a3, 2)
            }
        }
        addRoundKey(0)
        for round in 1..<14 {
            subBytes()
            shiftRows()
            mixColumns()
            addRoundKey(round)
        }
        subBytes()
        shiftRows()
        addRoundKey(14)
        var out = [UInt8](repeating: 0, count: 16)
        for c in 0..<4 { for r in 0..<4 { out[c * 4 + r] = st[c * 4 + r] } }
        return out
    }

    /// AES-256-CBC 解密（不去 padding，调试用）
    static func aes256CBCDecryptRaw(data: Data, key: [UInt8], iv: Data) throws -> Data {
        precondition(data.count % 16 == 0)
        let w = expandKey(key)
        var out = Data(capacity: data.count)
        var prev = [UInt8](iv)
        let bytes = [UInt8](data)
        for off in stride(from: 0, to: bytes.count, by: 16) {
            let cipher = Array(bytes[off..<(off + 16)])
            let decrypted = blockDecrypt(cipher, w: w)
            var plain = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 { plain[i] = decrypted[i] ^ prev[i] }
            out.append(contentsOf: plain)
            prev = cipher
        }
        return out
    }

    /// AES-256-CBC 解密（输入为去掉 salt 的密文，含 PKCS7 padding）
    static func aes256CBCDecrypt(data: Data, key: [UInt8], iv: [UInt8]) throws -> Data {
        precondition(data.count % 16 == 0)
        let w = expandKey(key)
        var out = Data(capacity: data.count)
        var prev: [UInt8] = Array(iv)
        let bytes = [UInt8](data)
        for off in stride(from: 0, to: bytes.count, by: 16) {
            let cipher = Array(bytes[off..<(off + 16)])
            let decrypted = blockDecrypt(cipher, w: w)
            var plain = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 { plain[i] = decrypted[i] ^ prev[i] }
            out.append(contentsOf: plain)
            prev = cipher
        }
        // 去 PKCS7
        guard let pad = out.last, (1...16).contains(Int(pad)) else {
            throw BoxSendError.badInput("PKCS7 padding 校验失败")
        }
        return out.dropLast(Int(pad))
    }

    // MARK: - OpenSSL EVP 格式 (Salted__ + AES-256-CBC)

    /// 解密 `openssl enc -aes-256-cbc -a -md md5` / CryptoJS.AES.encrypt 的输出。
    /// password 为口令字符串（Gist 场景 = MD5(userKey|gistID) 前 16 位）。
    static func decryptOpenSSL(base64: String, password: String) throws -> Data {
        let b64 = base64.filter { !$0.isWhitespace }
        guard let raw = Data(base64Encoded: b64) else {
            throw BoxSendError.badInput("备份内容不是 base64")
        }
        guard raw.count > 16, raw.prefix(8) == Data("Salted__".utf8) else {
            // 允许明文 JSON（未加密备份）
            if let s = String(data: raw, encoding: .utf8), s.hasPrefix("{") || s.hasPrefix("[") {
                return raw
            }
            throw BoxSendError.badInput("非 OpenSSL Salted 格式")
        }
        let salt = Array(raw[8..<16])
        let cipher = Array(raw[16...])
        let (key, iv) = evpBytesToKey(password: Data(password.utf8), salt: salt, keyLen: 32, ivLen: 16)
        return try aes256CBCDecrypt(data: Data(cipher), key: key, iv: iv)
    }

    static func evpBytesToKey(password: Data, salt: [UInt8], keyLen: Int, ivLen: Int) -> ([UInt8], [UInt8]) {
        var d = Data()
        var prev = Data()
        while d.count < keyLen + ivLen {
            prev = md5(prev + password + Data(salt))
            d.append(prev)
        }
        return (Array(d[0..<keyLen]), Array(d[keyLen..<(keyLen + ivLen)]))
    }

    /// PT-depiler Gist 备份的最终口令
    static func gistPassword(userKey: String, gistID: String) -> String {
        let pass1 = userKey + "|" + gistID
        let hex = md5(Data(pass1.utf8)).hexString
        return String(hex.prefix(16))
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
