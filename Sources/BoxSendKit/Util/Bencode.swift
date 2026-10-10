import Foundation

/// 极简 bencode 读取器：只解析 .torrent 顶层 dict，用于取真实数据量 / 发布名 / info hash
public enum Bencode {
    /// 种子总数据量（bytes）：info 字典内单文件取 `length`，多文件取 `lengths` 之和；解析失败返回 nil
    public static func totalLength(_ data: Data) -> Int64? {
        var i = 0
        guard i < data.count, data[i] == 0x64 else { return nil }   // 'd'
        i += 1
        while i < data.count {
            if data[i] == 0x65 { break }                            // 'e'
            guard let (key, ni) = readString(at: i, data) else { return nil }
            i = ni
            if key == "info" {
                return infoDictLength(at: i, data)
            } else {
                guard let ni2 = skipValue(at: i, data) else { return nil }
                i = ni2
            }
        }
        return nil
    }

    /// info 字典内的 `name`（发布名的权威来源，即 .torrent 内部名）
    public static func infoName(_ data: Data) -> String? {
        var i = 0
        guard i < data.count, data[i] == 0x64 else { return nil }
        i += 1
        while i < data.count {
            if data[i] == 0x65 { break }
            guard let (key, ni) = readString(at: i, data) else { return nil }
            i = ni
            if key == "info" {
                guard i < data.count, data[i] == 0x64 else { return nil }
                var j = i + 1
                while j < data.count {
                    if data[j] == 0x65 { break }
                    guard let (k, nj) = readString(at: j, data) else { return nil }
                    j = nj
                    if k == "name" {
                        return readString(at: j, data)?.0
                    }
                    guard let nj2 = skipValue(at: j, data) else { return nil }
                    j = nj2
                }
                return nil
            }
            guard let ni2 = skipValue(at: i, data) else { return nil }
            i = ni2
        }
        return nil
    }

    /// info 字典原始编码的 SHA1（即种子 hash）
    public static func infoHash(_ data: Data) -> String? {
        guard let (start, end) = infoRange(data) else { return nil }
        return sha1Hex(Data(data[start..<end]))
    }

    /// 顶层 announce / announce-list 里的 tracker URL（按出现顺序去重）。
    /// 推送时用来把目标站的 tracker 补挂到下载器里已有的同 hash 种子上。
    public static func announceURLs(_ data: Data) -> [String] {
        var out: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !out.contains(t) { out.append(t) }
        }
        guard data.count > 1, data[data.startIndex] == 0x64 else { return [] }   // 'd'
        var i = data.startIndex + 1
        while i < data.endIndex {
            if data[i] == 0x65 { break }                                        // 'e'
            guard let (key, ni) = readString(at: i, data) else { return out }
            i = ni
            if key == "announce", let (v, ni2) = readString(at: i, data) {
                add(v)
                i = ni2
            } else if key == "announce-list", i < data.endIndex, data[i] == 0x6C {
                // l l <url> e ... e ：每档一个 tracker 层
                var j = i + 1
                while j < data.endIndex, data[j] != 0x65 {
                    if data[j] == 0x6C {
                        var k = j + 1
                        while k < data.endIndex, data[k] != 0x65 {
                            guard let (v, nk) = readString(at: k, data) else { break }
                            add(v)
                            k = nk
                        }
                        j = k < data.endIndex ? k + 1 : data.endIndex
                    } else if let nj = skipValue(at: j, data) {
                        j = nj
                    } else {
                        break
                    }
                }
                i = j < data.endIndex ? j + 1 : data.endIndex
            } else if let ni2 = skipValue(at: i, data) {
                i = ni2
            } else {
                return out
            }
        }
        return out
    }

    /// YemaPT piecesHash：info 字典内 `pieces` 整个 bencoded 值（含 `<len>:` 前缀）的 SHA-1，40 位 hex
    public static func piecesHashHex(_ data: Data) -> String? {
        var i = 0
        guard i < data.count, data[i] == 0x64 else { return nil }   // 'd'
        i += 1
        while i < data.count {
            if data[i] == 0x65 { break }
            guard let (key, ni) = readString(at: i, data) else { return nil }
            i = ni
            if key == "info" {
                guard i < data.count, data[i] == 0x64 else { return nil }
                var j = i + 1
                while j < data.count {
                    if data[j] == 0x65 { break }
                    guard let (k, nj) = readString(at: j, data) else { return nil }
                    j = nj
                    if k == "pieces" {
                        // 值形如 <len>:<bytes>；站点 piecesHash = 整个 bencoded 值的 sha1
                        var p = j
                        while p < data.count, data[p] >= 0x30, data[p] <= 0x39 { p += 1 }
                        guard p < data.count, p > j, data[p] == 0x3a else { return nil }
                        guard let n = Int(String(bytes: data.subdata(in: j..<p), encoding: .ascii)!) else { return nil }
                        let s = p + 1
                        guard s + n <= data.count else { return nil }
                        return sha1Hex(data.subdata(in: j..<(s + n)))
                    }
                    guard let nj2 = skipValue(at: j, data) else { return nil }
                    j = nj2
                }
                return nil
            }
            guard let ni2 = skipValue(at: i, data) else { return nil }
            i = ni2
        }
        return nil
    }

    /// info 值在原始数据中的区间 [start, end)
    static func infoRange(_ data: Data) -> (Int, Int)? {
        var i = 0
        guard i < data.count, data[i] == 0x64 else { return nil }
        i += 1
        while i < data.count {
            if data[i] == 0x65 { break }
            guard let (key, ni) = readString(at: i, data) else { return nil }
            i = ni
            if key == "info" {
                guard let end = skipValue(at: i, data) else { return nil }
                return (i, end)
            }
            guard let ni2 = skipValue(at: i, data) else { return nil }
            i = ni2
        }
        return nil
    }
    private static func infoDictLength(at i0: Int, _ data: Data) -> Int64? {
        var i = i0
        guard i < data.count, data[i] == 0x64 else { return nil }   // 'd'
        i += 1
        var total: Int64?
        while i < data.count {
            if data[i] == 0x65 { break }                            // 'e'
            guard let (key, ni) = readString(at: i, data) else { return nil }
            i = ni
            if key == "length" {
                guard let (v, ni2) = readInt(at: i, data) else { return nil }
                i = ni2
                // 小值多半不是文件长度，避免误判
                if v > 65536 { total = v }
            } else if key == "lengths" {
                guard let (list, ni2) = readIntList(at: i, data) else { return nil }
                i = ni2
                let sum = list.reduce(Int64(0)) { $0 + $1 }
                if sum > 0 { total = sum }
            } else if key == "files" {
                // 旧式多文件: files = [ {length: n, path: [...]}, ... ]
                guard let (sum, ni2) = filesTotal(at: i, data) else { return nil }
                i = ni2
                if sum > 0 { total = sum }
            } else {
                guard let ni2 = skipValue(at: i, data) else { return nil }
                i = ni2
            }
        }
        return total
    }


    private static func filesTotal(at i0: Int, _ data: Data) -> (Int64, Int)? {
        guard i0 < data.count, data[i0] == 0x6C else { return nil } // 'l'
        var i = i0 + 1
        var sum: Int64 = 0
        while i < data.count, data[i] != 0x65 {
            guard i < data.count, data[i] == 0x64 else { return nil } // 每项是 dict
            var j = i + 1
            while j < data.count {
                if data[j] == 0x65 { break }
                guard let (k, nj) = readString(at: j, data) else { return nil }
                j = nj
                if k == "length" {
                    guard let (v, nj2) = readInt(at: j, data) else { return nil }
                    j = nj2
                    sum += v
                } else {
                    guard let nj2 = skipValue(at: j, data) else { return nil }
                    j = nj2
                }
            }
            guard j < data.count else { return nil }
            i = j + 1
        }
        guard i < data.count else { return nil }
        return (sum, i + 1)
    }
    // <len>:<bytes>
    private static func readString(at i0: Int, _ data: Data) -> (String, Int)? {
        var i = i0
        while i < data.count, data[i] >= 0x30, data[i] <= 0x39 { i += 1 }
        guard i < data.count, i > i0, data[i] == 0x3a else { return nil }
        guard let n = Int(String(bytes: data.subdata(in: i0..<i), encoding: .ascii)!) else { return nil }
        let s = i + 1
        guard s + n <= data.count else { return nil }
        let str = String(bytes: data.subdata(in: s..<(s + n)), encoding: .utf8) ?? ""
        return (str, s + n)
    }

    // i<int>e
    private static func readInt(at i0: Int, _ data: Data) -> (Int64, Int)? {
        guard i0 < data.count, data[i0] == 0x69 else { return nil } // 'i'
        var i = i0 + 1
        while i < data.count, data[i] != 0x65 { i += 1 }            // 'e'
        guard i < data.count else { return nil }
        guard let v = Int64(String(bytes: data.subdata(in: (i0 + 1)..<i), encoding: .ascii)!) else { return nil }
        return (v, i + 1)
    }

    // l ... e
    private static func readIntList(at i0: Int, _ data: Data) -> ([Int64], Int)? {
        guard i0 < data.count, data[i0] == 0x6C else { return nil } // 'l' (108)
        var i = i0 + 1
        var out: [Int64] = []
        while i < data.count, data[i] != 0x65 {
            guard let (v, ni) = readInt(at: i, data) else { return nil }
            out.append(v)
            i = ni
        }
        guard i < data.count else { return nil }
        return (out, i + 1)
    }

    private static func skipValue(at i0: Int, _ data: Data) -> Int? {
        guard i0 < data.count else { return nil }
        let c = data[i0]
        switch c {
        case 0x64: // dict
            var i = i0 + 1
            while i < data.count {
                if data[i] == 0x65 { return i + 1 }
                guard let (_, ni) = readString(at: i, data) else { return nil }
                guard let ni2 = skipValue(at: ni, data) else { return nil }
                i = ni2
            }
            return nil
        case 0x6C: // list 'l'
            var i = i0 + 1
            while i < data.count {
                if data[i] == 0x65 { return i + 1 }
                guard let ni = skipValue(at: i, data) else { return nil }
                i = ni
            }
            return nil
        case 0x69:
            return readInt(at: i0, data)?.1
        default:
            return readString(at: i0, data)?.1
        }
    }
}



// MARK: - SHA1（qBittorrent 种子 hash 校验用；纯 Swift 实现，全平台一致）

@inline(__always) private func bsRotl(_ v: UInt32, _ n: UInt32) -> UInt32 { (v << n) | (v >> (32 - n)) }

func sha1Hex(_ data: Data) -> String {
    let K: [UInt32] = [0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xCA62C1D6]
    var msg = [UInt8](data)
    let bitLen = UInt64(msg.count) * 8
    msg.append(0x80)
    while msg.count % 64 != 56 { msg.append(0) }
    for sh in stride(from: 56, through: 0, by: -8) { msg.append(UInt8((bitLen >> UInt64(sh)) & 0xFF)) }
    var h0: UInt32 = 0x67452301, h1: UInt32 = 0xEFCDAB89, h2: UInt32 = 0x98BADCFE, h3: UInt32 = 0x10325476, h4: UInt32 = 0xC3D2E1F0
    for chunk in stride(from: 0, to: msg.count, by: 64) {
        var w = [UInt32](repeating: 0, count: 80)
        for t in 0..<16 {
            let o = chunk + t * 4
            w[t] = (UInt32(msg[o]) << 24) | (UInt32(msg[o+1]) << 16) | (UInt32(msg[o+2]) << 8) | UInt32(msg[o+3])
        }
        for t in 16..<80 { w[t] = bsRotl(w[t-3] ^ w[t-8] ^ w[t-14] ^ w[t-16], 1) }
        var a = h0, b = h1, c = h2, d = h3, e = h4
        for t in 0..<80 {
            let f: UInt32
            switch t {
            case 0..<20: f = (b & c) | ((~b) & d)
            case 20..<40: f = b ^ c ^ d
            case 40..<60: f = (b & c) | (b & d) | (c & d)
            default: f = b ^ c ^ d
            }
            let temp = bsRotl(a, 5) &+ f &+ e &+ K[t / 20] &+ w[t]
            e = d; d = c; c = bsRotl(b, 30); b = a; a = temp
        }
        h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
    }
    return [h0, h1, h2, h3, h4].map { String(format: "%08x", $0) }.joined()
}
