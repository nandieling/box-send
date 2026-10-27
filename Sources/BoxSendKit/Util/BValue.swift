import Foundation

/// 通用 bencode 值。
///
/// `Bencode` 里那些解析器都是「只取我要的那几个字段」，读完就扔；而改种子内部文件名
/// 要把整份 .torrent 重新编码（改了 info 内容，hash 必须按新字节重算），手上得有一份
/// 完整无损的值树。字符串一律按原始字节存：种子文件名不一定是 UTF-8（GBK 命名的老种很常见），
/// 解码成 String 再编回去就可能变字节，hash 跟着变，白改一次名。
public enum BValue {
    case int(Int64)
    case bytes(Data)
    case list([BValue])
    case dict([(Data, BValue)])

    /// 解码；结构不完整（截断、非 bencode）返回 nil
    public static func decode(_ data: Data) -> BValue? {
        var r = Reader([UInt8](data))
        guard let v = r.value(), r.done else { return nil }
        return v
    }

    /// 编码。字典按键字节序输出（各下载器与站点都按规范序算 hash）
    public func encoded() -> Data {
        switch self {
        case .int(let v): return Data("i\(v)e".utf8)
        case .bytes(let b): return Data("\(b.count):".utf8) + b
        case .list(let xs):
            var out = Data("l".utf8)
            for x in xs { out += x.encoded() }
            out += Data("e".utf8)
            return out
        case .dict(let pairs):
            var out = Data("d".utf8)
            for (k, v) in pairs.sorted(by: { $0.0.lexicographicallyPrecedes($1.0) }) {
                out += Data("\(k.count):".utf8) + k + v.encoded()
            }
            out += Data("e".utf8)
            return out
        }
    }

    // MARK: - 取值

    public var dictPairs: [(Data, BValue)]? {
        if case .dict(let p) = self { return p }
        return nil
    }

    public var listValues: [BValue]? {
        if case .list(let v) = self { return v }
        return nil
    }

    public var bytesValue: Data? {
        if case .bytes(let b) = self { return b }
        return nil
    }

    /// 按键取字典里的值（键按 UTF-8 比）
    public func dict(_ key: String) -> BValue? {
        guard case .dict(let pairs) = self else { return nil }
        return pairs.first { String(decoding: $0.0, as: UTF8.self) == key }?.1
    }

    /// 字典里某个键的值换成 value（nil = 删掉这个键）；不是字典就原样返回
    public func setting(_ key: String, to value: BValue?) -> BValue {
        guard case .dict(let pairs) = self else { return self }
        let k = Data(key.utf8)
        var out: [(Data, BValue)] = []
        for (pk, pv) in pairs where pk != k { out.append((pk, pv)) }
        if let value { out.append((k, value)) }
        return .dict(out)
    }

    private struct Reader {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }
        var done: Bool { i >= b.count }

        mutating func value() -> BValue? {
            guard i < b.count else { return nil }
            let c = b[i]
            if c == 0x64 { return dictValue() }        // 'd'
            if c == 0x6C { return listValue() }        // 'l'
            if c == 0x69 { return intValue() }         // 'i'
            return string().map { BValue.bytes($0) }
        }

        private mutating func dictValue() -> BValue? {
            i += 1
            var pairs: [(Data, BValue)] = []
            while i < b.count, b[i] != 0x65 {          // 'e'
                guard let k = string(), let v = value() else { return nil }
                pairs.append((k, v))
            }
            guard i < b.count else { return nil }
            i += 1
            return .dict(pairs)
        }

        private mutating func listValue() -> BValue? {
            i += 1
            var xs: [BValue] = []
            while i < b.count, b[i] != 0x65 {
                guard let v = value() else { return nil }
                xs.append(v)
            }
            guard i < b.count else { return nil }
            i += 1
            return .list(xs)
        }

        private mutating func intValue() -> BValue? {
            i += 1
            let start = i
            while i < b.count, b[i] != 0x65 { i += 1 }
            guard i < b.count, i > start,
                  let v = Int64(String(decoding: b[start..<i], as: UTF8.self)) else { return nil }
            i += 1
            return .int(v)
        }

        /// `<长度>:<字节>`；长度按字节数算，所以内容原样切出来
        mutating func string() -> Data? {
            let start = i
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }   // '0'…'9'
            guard i > start, i < b.count, b[i] == 0x3A,               // ':'
                  let n = Int(String(decoding: b[start..<i], as: UTF8.self)),
                  i + 1 + n <= b.count else { return nil }
            i += 1
            let out = Data(b[i..<(i + n)])
            i += n
            return out
        }
    }
}
