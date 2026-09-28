import Foundation

/// 极简 bencode 读取器：只解析 .torrent 顶层 dict，用于取真实数据量（分组单日量统计用）
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
