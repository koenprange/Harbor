import Foundation

public enum HarborError: LocalizedError, Sendable {
    case http(Int), malformedResponse, tooLarge, noTorrent, invalidLink, transmissionMissing
    public var errorDescription: String? {
        switch self {
        case .http(let code): "The source returned HTTP \(code). It may be unavailable or blocking requests."
        case .malformedResponse: "The source returned an unexpected response. Its API may have changed."
        case .tooLarge: "The response exceeded the size limit."
        case .noTorrent: "This Archive item has no publicly downloadable torrent. It may be restricted or unavailable."
        case .invalidLink: "The source returned an invalid download link."
        case .transmissionMissing: "Transmission was not found. Install it, or use Copy Magnet Link to open this result in another client."
        }
    }
}

public struct SearchService: Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    public func search(_ source: SearchSource, query: String) async throws -> [TorrentResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if source == .knaben { try await KnabenThrottle.shared.wait() }
        let data = try await fetch(Self.searchURL(source, query: trimmed))
        try Task.checkCancellation()
        return try Self.parse(data, source: source)
    }

    public static func searchURL(_ source: SearchSource, query: String) -> URL {
        var components: URLComponents
        switch source {
        case .pirateBay:
            components = URLComponents(string: "https://apibay.org/q.php")!
            components.queryItems = [.init(name: "q", value: query), .init(name: "cat", value: "0")]
        case .torrentsCSV:
            components = URLComponents(string: "https://torrents-csv.com/service/search")!
            components.queryItems = [.init(name: "q", value: query), .init(name: "size", value: "100")]
        case .knaben:
            components = URLComponents(string: "https://api.knaben.org/v2/search")!
            components.queryItems = [.init(name: "q", value: query), .init(name: "o", value: "seeders"),
                                     .init(name: "d", value: "desc"), .init(name: "s", value: "100")]
        case .nyaa:
            components = URLComponents(string: "https://nyaa.si/")!
            components.queryItems = [.init(name: "page", value: "rss"), .init(name: "q", value: query),
                .init(name: "c", value: "0_0"), .init(name: "f", value: "0"),
                .init(name: "s", value: "seeders"), .init(name: "o", value: "desc")]
        case .internetArchive:
            components = URLComponents(string: "https://archive.org/advancedsearch.php")!
            let words = query.split(whereSeparator: \.isWhitespace).map {
                "title:\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }.joined(separator: " AND ")
            components.queryItems = [
                .init(name: "q", value: "(\(words)) AND format:\"Archive BitTorrent\" AND NOT mediatype:collection"),
                .init(name: "output", value: "json"), .init(name: "rows", value: "100"),
                .init(name: "sort[]", value: "downloads desc")
            ] + ["identifier", "title", "item_size", "publicdate", "mediatype"].map { .init(name: "fl[]", value: $0) }
        }
        return components.url!
    }

    public func archiveTorrentURL(identifier: String) async throws -> URL {
        guard LinkSafety.archiveIdentifierIsValid(identifier) else { throw HarborError.invalidLink }
        let url = URL(string: "https://archive.org/metadata/\(identifier)")!
        return try Self.parseArchiveTorrent(try await fetch(url), identifier: identifier)
    }

    public static func parseArchiveTorrent(_ data: Data, identifier: String) throws -> URL {
        guard LinkSafety.archiveIdentifierIsValid(identifier) else { throw HarborError.invalidLink }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = root["files"] as? [[String: Any]] else { throw HarborError.malformedResponse }
        guard let file = files.first(where: {
            ($0["format"] as? String == "Archive BitTorrent" || ($0["name"] as? String)?.hasSuffix("_archive.torrent") == true)
                && $0["private"] as? String != "true"
        }), let name = file["name"] as? String, name.hasSuffix(".torrent"),
              !name.contains("/"), !name.contains("\\"), name.count <= 500 else { throw HarborError.noTorrent }
        return URL(string: "https://archive.org/download/\(identifier)/")!.appendingPathComponent(name)
    }

    public func torrentData(from url: URL) async throws -> Data {
        guard url.scheme == "https", url.host == "archive.org", url.path.hasSuffix(".torrent") else {
            throw HarborError.invalidLink
        }
        let data = try await fetch(url, limit: 4 * 1024 * 1024)
        guard TorrentValidator.isTorrent(data) else { throw HarborError.malformedResponse }
        return data
    }

    private func fetch(_ url: URL, limit: Int = 8 * 1024 * 1024) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Harbor/1.1 (native macOS torrent search)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, application/rss+xml, application/xml, application/x-bittorrent;q=0.9", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw HarborError.malformedResponse }
        guard (200...299).contains(response.statusCode) else { throw HarborError.http(response.statusCode) }
        guard response.expectedContentLength <= limit else { throw HarborError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            if data.count >= limit { throw HarborError.tooLarge }
            if data.count % 16384 == 0 { try Task.checkCancellation() }
            data.append(byte)
        }
        return data
    }

    public static func parse(_ data: Data, source: SearchSource) throws -> [TorrentResult] {
        if source == .nyaa { return try parseNyaa(data) }
        let root = try JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        switch source {
        case .pirateBay:
            guard let array = root as? [[String: Any]] else { throw HarborError.malformedResponse }
            rows = array
        case .torrentsCSV:
            guard let object = root as? [String: Any], let array = object["torrents"] as? [[String: Any]] else {
                throw HarborError.malformedResponse
            }
            rows = array
        case .internetArchive:
            guard let object = root as? [String: Any], let response = object["response"] as? [String: Any],
                  let array = response["docs"] as? [[String: Any]] else { throw HarborError.malformedResponse }
            rows = array
        case .knaben:
            guard let object = root as? [String: Any], let array = object["hits"] as? [[String: Any]] else {
                throw HarborError.malformedResponse
            }
            return array.prefix(100).compactMap(parseKnabenRow)
        case .nyaa:
            throw HarborError.malformedResponse // XML is handled before JSON parsing.
        }
        return rows.prefix(100).compactMap { row in
            if source == .internetArchive {
                guard let identifier = row["identifier"] as? String,
                      LinkSafety.archiveIdentifierIsValid(identifier) else { return nil }
                let title = cleanTitle(row["title"] as? String ?? identifier)
                guard !title.isEmpty else { return nil }
                let date = (row["publicdate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                return TorrentResult(title: title, size: number(row["item_size"]), added: date,
                    category: row["mediatype"] as? String, archiveIdentifier: identifier,
                    links: [.init(source: source, url: URL(string: "https://archive.org/details/\(identifier)")!)])
            }
            guard let hash = row[source == .pirateBay ? "info_hash" : "infohash"] as? String,
                  LinkSafety.validInfoHash(hash), let rawTitle = row["name"] as? String else { return nil }
            let title = cleanTitle(rawTitle)
            guard !title.isEmpty else { return nil }
            let stamp = number(row[source == .pirateBay ? "added" : "created_unix"])
            let category = source == .pirateBay ? categoryName(number(row["category"])) : nil
            let link: URL
            if source == .pirateBay, let id = number(row["id"]), id > 0 {
                link = URL(string: "https://thepiratebay.org/description.php?id=\(id)")!
            } else {
                var components = URLComponents(string: "https://torrents-csv.com/")!
                components.fragment = "/search/\(hash.lowercased())"
                link = components.url!
            }
            return TorrentResult(title: title, size: number(row[source == .pirateBay ? "size" : "size_bytes"]),
                seeders: number(row["seeders"]).map(Int.init), leechers: number(row["leechers"]).map(Int.init),
                added: stamp.map { Date(timeIntervalSince1970: Double($0)) }, category: category,
                fileCount: number(row["num_files"]).map(Int.init), infoHash: hash, links: [.init(source: source, url: link)])
        }
    }

    static func number(_ value: Any?) -> Int64? {
        let result: Int64?
        if let string = value as? String { result = Int64(string) }
        else if let number = value as? NSNumber {
            let double = number.doubleValue
            result = double.isFinite && double >= 0 && double < Double(Int64.max) ? number.int64Value : nil
        } else { result = nil }
        return result.flatMap { $0 >= 0 ? $0 : nil }
    }

    private static func categoryName(_ number: Int64?) -> String? {
        guard let number else { return nil }
        switch number / 100 {
        case 1: return "Audio"
        case 2: return "Video"
        case 3: return "Software"
        case 4: return "Games"
        case 5: return "Adult"
        default: return "Other"
        }
    }

    static func cleanTitle(_ raw: String) -> String {
        var title = String(raw.prefix(2000))
        for (entity, character) in [("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            title = title.replacingOccurrences(of: entity, with: character)
        }
        return title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private actor KnabenThrottle {
    static let shared = KnabenThrottle()
    private var next = ContinuousClock.now
    func wait() async throws {
        let now = ContinuousClock.now
        let scheduled = max(now, next)
        next = scheduled.advanced(by: .seconds(2))
        if scheduled > now { try await Task.sleep(until: scheduled, clock: .continuous) }
        try Task.checkCancellation()
    }
}
