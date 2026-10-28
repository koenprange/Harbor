import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

extension SearchService {
    static func parseNyaa(_ data: Data) throws -> [TorrentResult] {
        // This feed is UTF-8. Reject DTDs outright instead of resolving any entities.
        guard let xml = String(data: data, encoding: .utf8),
              !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else { throw HarborError.malformedResponse }
        let delegate = NyaaFeedParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), delegate.validFeed else { throw HarborError.malformedResponse }
        return delegate.results
    }

    static func rssSize(_ string: String?) -> Int64? {
        guard let parts = string?.split(whereSeparator: \.isWhitespace), parts.count == 2,
              let amount = Double(parts[0]), amount.isFinite, amount >= 0 else { return nil }
        let units: [String: Double] = ["B": 1, "KIB": 1024, "MIB": 1048576, "GIB": 1073741824,
            "TIB": 1099511627776, "KB": 1000, "MB": 1000000, "GB": 1000000000, "TB": 1000000000000]
        guard let scale = units[parts[1].uppercased()] else { return nil }
        let bytes = amount * scale
        guard bytes.isFinite, bytes < Double(Int64.max) else { return nil }
        return Int64(bytes)
    }
}

private final class NyaaFeedParser: NSObject, XMLParserDelegate {
    private var path: [String] = []
    private var fields: [String: String] = [:]
    private var activeField: String?
    private(set) var validFeed = false
    private(set) var results: [TorrentResult] = []
    private let namespace = "https://nyaa.si/xmlns/nyaa"

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        path.append(name)
        if path.count > 40 { parser.abortParsing(); return }
        if path == ["rss", "channel"], namespaceURI == nil || namespaceURI == "" { validFeed = true }
        if path == ["rss", "channel", "item"] { fields = [:] }
        activeField = nil
        guard path.count == 4, Array(path.prefix(3)) == ["rss", "channel", "item"] else { return }
        if namespaceURI == namespace, ["infoHash", "seeders", "leechers", "size", "category"].contains(name) {
            activeField = name
        } else if (namespaceURI == nil || namespaceURI == ""), ["title", "guid", "pubDate"].contains(name) {
            activeField = name
        }
        if let activeField { fields[activeField] = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let activeField else { return }
        if (fields[activeField]?.utf8.count ?? 0) + string.utf8.count > 12000 { parser.abortParsing(); return }
        fields[activeField, default: ""] += string
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard activeField != nil else { return }
        guard let text = String(data: data, encoding: .utf8) else { parser.abortParsing(); return }
        self.parser(parser, foundCharacters: text)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if path == ["rss", "channel", "item"], results.count < 100 { appendResult() }
        activeField = nil
        if !path.isEmpty { path.removeLast() }
    }

    private func appendResult() {
        guard let hash = fields["infoHash"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              LinkSafety.validInfoHash(hash), let rawTitle = fields["title"],
              let guid = fields["guid"], let url = URL(string: guid.trimmingCharacters(in: .whitespacesAndNewlines)),
              LinkSafety.isSafeWebURL(url), url.host == "nyaa.si", url.path.hasPrefix("/view/") else { return }
        let title = SearchService.cleanTitle(rawTitle)
        guard !title.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        results.append(TorrentResult(title: title, size: SearchService.rssSize(fields["size"]),
            seeders: SearchService.number(fields["seeders"]?.trimmingCharacters(in: .whitespacesAndNewlines)).map(Int.init),
            leechers: SearchService.number(fields["leechers"]?.trimmingCharacters(in: .whitespacesAndNewlines)).map(Int.init),
            added: fields["pubDate"].flatMap { formatter.date(from: $0.trimmingCharacters(in: .whitespacesAndNewlines)) },
            category: fields["category"].map(SearchService.cleanTitle), infoHash: hash,
            links: [.init(source: .nyaa, url: url)]))
    }
}
