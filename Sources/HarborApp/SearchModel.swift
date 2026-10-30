import AppKit
import SwiftUI
import HarborCore

enum SourceState: Equatable {
    case idle, searching, complete(Int), failed(String), cancelled
    var caption: String {
        switch self {
        case .idle: "Ready"
        case .searching: "Searching…"
        case .complete(let count): "\(count) results"
        case .failed: "Unavailable"
        case .cancelled: "Stopped"
        }
    }
    var color: Color {
        switch self {
        case .searching: .accentColor
        case .complete: .green
        case .failed: .orange
        default: .secondary
        }
    }
}

@MainActor @Observable final class SearchModel {
    static let shared = SearchModel()
    var query = ""
    var searchedQuery = ""
    var scope: String? = "all"
    var selection: String?
    var results: [TorrentResult] = []
    var states: [SearchSource: SourceState] = [:]
    var isSearching = false
    var hasSearched = false
    var isOpening = false
    var openingID: String?
    var error: String?
    var notice: String?
    var pendingAddition: TorrentResult?
    let downloads: DownloadsModel
    private let defaults: UserDefaults
    var recentSearches: [String]
    var enabled: Set<SearchSource>
    var sortOrder = [KeyPathComparator(\TorrentResult.seedSort, order: .reverse), KeyPathComparator(\TorrentResult.title)]
    private var searchTask: Task<Void, Never>?
    private var searchID = UUID()
    private let service = SearchService()

    init(downloads: DownloadsModel? = nil, defaults: UserDefaults = .standard) {
        self.downloads = downloads ?? DownloadsModel()
        self.defaults = defaults
        recentSearches = defaults.stringArray(forKey: "recentSearches") ?? []
        enabled = SearchSource.restoredSelection(
            enabled: defaults.stringArray(forKey: "enabledSources"),
            known: defaults.stringArray(forKey: "knownSources"))
        defaults.set(SearchSource.allCases.map(\.rawValue), forKey: "knownSources")
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: "enabledSources")
    }

    var visibleResults: [TorrentResult] {
        results.filter { result in
            scope == nil || scope == "all" || result.links.contains { $0.source.rawValue == scope }
        }.sorted(using: sortOrder)
    }
    var selected: TorrentResult? { results.first { $0.id == selection } }
    var sourceSummary: String {
        enabled.count == SearchSource.allCases.count ? "All sources" : "\(enabled.count) sources"
    }
    var transmissionURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.m0k.transmission") }

    func toggle(_ source: SearchSource) {
        if enabled.contains(source) { enabled.remove(source) } else { enabled.insert(source) }
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: "enabledSources")
    }

    func search(_ text: String? = nil) {
        let text = (text ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !enabled.isEmpty else { return }
        searchTask?.cancel()
        searchID = UUID()
        let id = searchID
        query = text
        searchedQuery = text
        results = []
        selection = nil
        notice = nil
        hasSearched = true
        isSearching = true
        scope = "all"
        let sources = SearchSource.allCases.filter { enabled.contains($0) }
        states = Dictionary(uniqueKeysWithValues: sources.map { ($0, .searching) })
        recentSearches.removeAll { $0.caseInsensitiveCompare(text) == .orderedSame }
        recentSearches.insert(text, at: 0)
        recentSearches = Array(recentSearches.prefix(8))
        defaults.set(recentSearches, forKey: "recentSearches")
        let service = service
        searchTask = Task {
            await withTaskGroup(of: SourceOutcome.self) { group in
                for source in sources {
                    group.addTask {
                        do { return SourceOutcome(source: source, results: try await service.search(source, query: text), failure: nil) }
                        catch { return SourceOutcome(source: source, results: [], failure: error.localizedDescription) }
                    }
                }
                for await outcome in group {
                    guard !Task.isCancelled, self.searchID == id else { group.cancelAll(); continue }
                    if let failure = outcome.failure {
                        self.states[outcome.source] = .failed(failure)
                    } else {
                        self.states[outcome.source] = .complete(outcome.results.count)
                        self.results = ResultMerger.merge(self.results + outcome.results)
                    }
                }
            }
            guard self.searchID == id else { return }
            self.isSearching = false
        }
    }

    func stop() {
        searchTask?.cancel()
        searchID = UUID()
        isSearching = false
        for source in SearchSource.allCases where states[source] == .searching { states[source] = .cancelled }
    }

    func copyMagnet(_ result: TorrentResult) {
        guard let url = result.magnetURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        notice = "Magnet link copied"
    }

    func openInTransmission(_ result: TorrentResult) {
        guard !isOpening else { return }
        if downloads.setupRequired { downloads.showSetup = true; return }
        guard downloads.configured else { downloads.showConnection = true; return }
        pendingAddition = result
    }

    func addDownload(_ result: TorrentResult, directory: String, start: Bool) async throws {
        isOpening = true
        openingID = result.id
        defer { isOpening = false; openingID = nil }
        let added: TransferAddition
        if let magnet = result.magnetURL {
            added = try await downloads.add(magnet: magnet, directory: directory, paused: !start)
        } else if let identifier = result.archiveIdentifier {
            let remote = try await service.archiveTorrentURL(identifier: identifier)
            let data = try await service.torrentData(from: remote)
            added = try await downloads.add(torrent: data, directory: directory, paused: !start)
        } else { throw HarborError.invalidLink }
        notice = added.duplicate ? "Already in Downloads" : "Added to Downloads"
        pendingAddition = nil
        scope = "downloads"
    }

    func openDetails(_ link: SourceLink) {
        guard LinkSafety.isSafeWebURL(link.url) else { return }
        NSWorkspace.shared.open(link.url)
    }
}

private struct SourceOutcome: Sendable {
    let source: SearchSource
    let results: [TorrentResult]
    let failure: String?
}
