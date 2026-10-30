import AppKit
import Foundation
import Testing
import HarborCore
@testable import HarborApp

/// Opt-in workload for Instruments/leaks. No daemon, Keychain or network access.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HARBOR_MEMORY_EXERCISE"] == "1"))
@MainActor struct MemoryExerciseTests {
    @Test func repeatedNativeMenuReleasesOldViewsAndModels() async throws {
        _ = NSApplication.shared
        let suite = "nl.koenprange.harbor.memory-fixture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineRPC.self]
        let client = TransmissionClient(username: "fixture", password: "fixture", session: URLSession(configuration: configuration))
        weak var releasedDownloads: DownloadsModel?
        weak var releasedSearch: SearchModel?
        weak var releasedMenu: NativeStatusMenu?
        var oldViews: [WeakView] = []
        let count = min(1_000, max(1, Int(ProcessInfo.processInfo.environment["HARBOR_MEMORY_CYCLES"] ?? "160") ?? 160))
        do {
            let downloads = DownloadsModel(client: client)
            downloads.connected = true
            downloads.transfers = try fixtures()
            let search = SearchModel(downloads: downloads, defaults: defaults)
            let menu = NativeStatusMenu(model: search)
            releasedDownloads = downloads; releasedSearch = search; releasedMenu = menu
            print("Memory exercise ready: PID \(ProcessInfo.processInfo.processIdentifier), 64 synthetic transfers, \(count) menu rebuilds")
            fflush(nil)
            // Allows an attached profiler to establish a baseline without a global pause.
            try await Task.sleep(for: .seconds(10))
            for index in 0..<count {
                autoreleasepool {
                    menu.menuNeedsUpdate(menu.menu)
                    for item in menu.menu.items {
                        if let view = item.view { oldViews.append(WeakView(view)) }
                    }
                    // Exercise changed download state while the native menu exists.
                    downloads.selection = downloads.transfers[index % downloads.transfers.count].id
                    downloads.filter = ["", "active", "queued", "seeding", "paused"][index % 5]
                    _ = downloads.visible
                    _ = downloads.downloadSpeed
                    _ = downloads.uploadSpeed
                }
                try await Task.sleep(for: .milliseconds(50))
                if index % 20 == 19 {
                    print("Memory exercise batch \(index + 1): \(oldViews.filter { $0.value != nil }.count) live views from all generations")
                }
            }
            menu.menu.removeAllItems()
        }
        // Drain deferred AppKit/SwiftUI work before checking object lifetimes.
        try await Task.sleep(for: .seconds(10))
        #expect(releasedMenu == nil)
        #expect(releasedSearch == nil)
        #expect(releasedDownloads == nil)
        let survivors = oldViews.filter { $0.value != nil }.count
        print("Memory exercise final: \(survivors) surviving menu views; models released")
        #expect(survivors == 0)
        fflush(nil)
        // Leave a quiet interval for a live heap snapshot after the workload.
        let hold = min(30, max(1, Int(ProcessInfo.processInfo.environment["HARBOR_MEMORY_HOLD_SECONDS"] ?? "5") ?? 5))
        try await Task.sleep(for: .seconds(hold))
    }

    private func fixtures() throws -> [Transfer] {
        let values: [[String: Any]] = (0..<64).map { index -> [String: Any] in
            let status = [0, 3, 4, 6][index % 4]
            let progress: Double = index % 4 == 3 ? 1.0 : 0.5
            return ["hash_string": String(format: "%040x", index + 1), "name": "Synthetic transfer \(index)",
             "status": status, "percent_done": progress,
             "rate_download": 1024, "rate_upload": 512, "eta": 100, "total_size": 16384,
             "downloaded_ever": 8192, "uploaded_ever": 4096, "upload_ratio": 0.5,
             "download_dir": "/tmp", "error": 0, "error_string": "", "queue_position": index,
             "peers_connected": 4, "peers_sending_to_us": 2, "peers_getting_from_us": 1,
             "metadata_percent_complete": 1]
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([Transfer].self, from: JSONSerialization.data(withJSONObject: values))
    }
}

@MainActor private final class WeakView {
    weak var value: NSView?
    init(_ value: NSView) { self.value = value }
}

private final class OfflineRPC: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
