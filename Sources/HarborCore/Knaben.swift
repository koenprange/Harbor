import Foundation

extension SearchService {
    static func parseKnabenRow(_ row: [String: Any]) -> TorrentResult? {
        // Knaben IDs identify database records, not torrents. Never use "id" as an info hash.
        let explicit = row["hash"] as? String
        let hash = explicit.flatMap { LinkSafety.validInfoHash($0) ? $0 : nil }
            ?? (row["magnetUrl"] as? String).flatMap(infoHashFromMagnet)
        guard let hash, let rawTitle = row["title"] as? String else { return nil }
        let title = cleanTitle(rawTitle)
        guard !title.isEmpty else { return nil }

        var fallback = URLComponents(string: "https://knaben.org/search/")!
        fallback.path += "\(hash.lowercased())/0/seeders"
        let details = (row["details"] as? String).flatMap(URL.init(string:))
            .flatMap { LinkSafety.isSafeWebURL($0) ? $0 : nil } ?? fallback.url!
        let date = (row["date"] as? String).flatMap { value -> Date? in
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: value)
        }
        let indexer = (row["tracker"] as? String).map(cleanTitle).flatMap { $0.isEmpty ? nil : String($0.prefix(100)) }
        return TorrentResult(title: title, size: number(row["bytes"]),
            seeders: (number(row["liveSeeders"]) ?? number(row["seeders"])).map(Int.init),
            leechers: (number(row["livePeers"]) ?? number(row["peers"])).map(Int.init),
            added: date, category: (row["category"] as? String).map(cleanTitle), infoHash: hash,
            links: [.init(source: .knaben, url: details, indexer: indexer)])
    }

    static func infoHashFromMagnet(_ string: String) -> String? {
        guard let components = URLComponents(string: string), components.scheme == "magnet" else { return nil }
        for item in components.queryItems ?? [] where item.name == "xt" {
            let prefix = "urn:btih:"
            guard let value = item.value, value.lowercased().hasPrefix(prefix) else { continue }
            let hash = String(value.dropFirst(prefix.count))
            if LinkSafety.validInfoHash(hash) { return hash }
        }
        return nil
    }
}
