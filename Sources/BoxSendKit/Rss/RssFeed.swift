import Foundation

/// NexusPHP passkey RSS 条目
public struct RssItem: Equatable {
    public var guid: String
    public var link: String      // 详情页 URL
    public var title: String
    public var pubDate: String
    public init(guid: String, link: String, title: String, pubDate: String) {
        self.guid = guid
        self.link = link
        self.title = title
        self.pubDate = pubDate
    }
}

/// 极简 RSS 解析（只取 item 的 guid/link/title/pubDate，够用且零依赖）
public enum RssFeed {
    public static func parse(_ xml: String) -> [RssItem] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        let d = Parser()
        parser.delegate = d
        parser.shouldProcessNamespaces = false
        parser.parse()
        return d.items
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var items: [RssItem] = []
        private var inItem = false
        private var field = ""
        private var guid = "", link = "", title = "", pubDate = ""

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            if name == "item" { inItem = true; return }
            guard inItem else { return }
            field = name
            // guid 有时带 isPermaLink 属性，link 字段更可靠
            if name == "guid", let l = attributes["isPermaLink"], l.lowercased() == "false" {
                field = "guid"
            }
        }
        func parser(_ p: XMLParser, foundCharacters string: String) {
            guard inItem, !field.isEmpty else { return }
            switch field {
            case "guid": guid += string
            case "link": link += string
            case "title": title += string
            case "pubDate": pubDate += string
            default: break
            }
        }
        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard inItem else { return }
            if name == "item" {
                inItem = false
                field = ""
                let g = guid.trimmingCharacters(in: .whitespacesAndNewlines)
                let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
                let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                // 优先用 link（详情页 URL，稳定）；link 缺失时退回 guid
                let key = l.isEmpty ? g : l
                if !key.isEmpty {
                    items.append(RssItem(guid: key, link: l, title: t,
                                         pubDate: pubDate.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                guid = ""; link = ""; title = ""; pubDate = ""
            }
        }
    }
}
