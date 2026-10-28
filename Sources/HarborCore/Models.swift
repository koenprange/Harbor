import Foundation

public enum SearchSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case pirateBay, torrentsCSV, internetArchive, knaben, nyaa
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .pirateBay: "The Pirate Bay"
        case .torrentsCSV: "TorrentsCSV"
        case .internetArchive: "Internet Archive"
        case .knaben: "Knaben"
        case .nyaa: "Nyaa"
        }
    }
    public var subtitle: String {
        switch self {
        case .pirateBay: "General index · APIBay"
        case .torrentsCSV: "General index · JSON API"
        case .internetArchive: "Digital collections · Archive API"
        case .knaben: "Multiple indexes · JSON API"
        case .nyaa: "Japanese media & games · RSS"
        }
    }
    public var symbol: String {
        switch self {
        case .pirateBay: "sailboat"
        case .torrentsCSV: "externaldrive"
        case .internetArchive: "building.columns"
        case .knaben: "square.stack.3d.up"
        case .nyaa: "sparkles.tv"
        }
    }

    public var shortTitle: String {
        switch self {
        case .pirateBay: "APIBay"
        case .internetArchive: "Archive"
        default: title
        }
    }

    /// Enable newly shipped sources once, without resetting existing opt-outs.
    public static func restoredSelection(enabled: [String]?, known: [String]?) -> Set<Self> {
        guard let enabled else { return Set(allCases) }
        let original: [Self] = [.pirateBay, .torrentsCSV, .internetArchive]
        let previous = Set((known ?? original.map(\.rawValue)).compactMap(Self.init(rawValue:)))
        return Set(enabled.compactMap(Self.init(rawValue:))).union(Set(allCases).subtracting(previous))
    }
}

public struct SourceLink: Hashable, Sendable {
    public let source: SearchSource
    public let url: URL
    public let indexer: String?
    public var label: String { indexer.map { "\(source.title) · \($0)" } ?? source.title }
    public init(source: SearchSource, url: URL, indexer: String? = nil) {
        self.source = source; self.url = url; self.indexer = indexer
    }
}

public struct TorrentResult: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var size: Int64?
    public var seeders: Int?
    public var leechers: Int?
    public var added: Date?
    public var category: String?
    public var fileCount: Int?
    public let infoHash: String?
    public let archiveIdentifier: String?
    public var links: [SourceLink]

    public init(title: String, size: Int64? = nil, seeders: Int? = nil, leechers: Int? = nil,
                added: Date? = nil, category: String? = nil, fileCount: Int? = nil,
                infoHash: String? = nil, archiveIdentifier: String? = nil, links: [SourceLink]) {
        self.infoHash = infoHash?.lowercased()
        self.archiveIdentifier = archiveIdentifier
        self.id = infoHash?.lowercased() ?? "archive:\(archiveIdentifier ?? UUID().uuidString)"
        self.title = title
        self.size = size
        self.seeders = seeders
        self.leechers = leechers
        self.added = added
        self.category = category
        self.fileCount = fileCount
        self.links = links
    }

    public var sourceCount: Int { Set(links.map(\.source)).count }
    public var sourceLabel: String {
        SearchSource.allCases.filter { source in links.contains { $0.source == source } }.map(\.title).joined(separator: ", ")
    }
    public var seedSort: Int { seeders ?? -1 }
    public var sizeSort: Int64 { size ?? -1 }
    public var dateSort: Date { added ?? .distantPast }
    public var formattedSize: String {
        size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary) } ?? "—"
    }
    public var magnetURL: URL? {
        guard let infoHash, LinkSafety.validInfoHash(infoHash) else { return nil }
        var components = URLComponents()
        components.scheme = "magnet"
        components.queryItems = [
            .init(name: "xt", value: "urn:btih:\(infoHash)"),
            .init(name: "dn", value: title),
            .init(name: "tr", value: "udp://tracker.opentrackr.org:1337/announce"),
            .init(name: "tr", value: "udp://open.stealth.si:80/announce")
        ]
        return components.url
    }
}

public enum LinkSafety {
    public static func validInfoHash(_ hash: String) -> Bool {
        hash.count == 40 && hash.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
            && hash.contains(where: { $0 != "0" })
    }

    public static func archiveIdentifierIsValid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 200 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        } && id != "." && id != ".."
    }

    public static func isSafeWebURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
    }
}

public enum ResultMerger {
    public static func merge(_ results: [TorrentResult]) -> [TorrentResult] {
        var merged: [String: TorrentResult] = [:]
        for result in results {
            guard var existing = merged[result.id] else { merged[result.id] = result; continue }
            existing.seeders = maximum(existing.seeders, result.seeders)
            existing.leechers = maximum(existing.leechers, result.leechers)
            existing.size = existing.size ?? result.size
            existing.category = existing.category ?? result.category
            existing.fileCount = existing.fileCount ?? result.fileCount
            existing.added = existing.added ?? result.added
            existing.links = Array(Set(existing.links + result.links)).sorted {
                ($0.source.rawValue, $0.indexer ?? "", $0.url.absoluteString) < ($1.source.rawValue, $1.indexer ?? "", $1.url.absoluteString)
            }
            merged[result.id] = existing
        }
        return merged.values.sorted { $0.id < $1.id }
    }
    private static func maximum<T: Comparable>(_ a: T?, _ b: T?) -> T? {
        if let a, let b { return max(a, b) }
        return a ?? b
    }
}
