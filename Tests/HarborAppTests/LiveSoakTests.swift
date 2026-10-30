import AppKit
import Foundation
import SwiftUI
import Testing
import HarborCore
@testable import HarborApp

/// Prepared separately; never runs during ordinary tests or metadata preparation.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HARBOR_SOAK_EXERCISE"] == "1"))
@MainActor struct LiveSoakTests {
    private struct Configuration: Decodable {
        let port: Int
        let username: String
        let password: String
        let root: String
        let hours: Int
        let interval: Int
    }
    private struct Failure: LocalizedError {
        let code: String
        var errorDescription: String? { code }
    }

    @Test func liveEngineAndNativeInterface() async throws {
        // Credentials are received only through a private pipe, never arguments/env/logs.
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let config: Configuration
        do { config = try JSONDecoder().decode(Configuration.self, from: input) }
        catch { throw Failure(code: "Invalid private soak configuration") }
        let root = URL(fileURLWithPath: config.root).standardizedFileURL
        guard config.hours == 48, config.interval >= 60, config.port != 9091,
              (1024...65535).contains(config.port), !config.password.isEmpty,
              FileManager.default.fileExists(atPath: root.appendingPathComponent("plan.json").path) else {
            throw Failure(code: "Refusing an unbound soak configuration")
        }
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        let domain = "nl.koenprange.harbor.soak.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else { throw Failure(code: "No isolated preferences") }
        defer { defaults.removePersistentDomain(forName: domain) }
        let client = TransmissionClient(username: config.username, password: config.password, port: config.port)
        weak var oldDownloads: DownloadsModel?
        weak var oldSearch: SearchModel?
        weak var oldMenu: NativeStatusMenu?
        var cycles = 0
        let report = root.appendingPathComponent("ui-report.json")
        do {
            let downloads = DownloadsModel(client: client)
            let search = SearchModel(downloads: downloads, defaults: defaults)
            search.scope = "downloads"
            let menu = NativeStatusMenu(model: search, displayName: "Harbor 48h Test")
            oldDownloads = downloads; oldSearch = search; oldMenu = menu
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 700),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Harbor — isolated 48-hour test"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ContentView(model: search))
            menu.openWindow = { [weak window] in window?.makeKeyAndOrderFront(nil) }
            menu.install()
            downloads.startPolling()
            // Layout without repeatedly bringing a test window in front of the user's work.
            defer {
                menu.uninstall()
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
            let deadline = ContinuousClock.now + .seconds(config.hours * 3600 + 120)
            var next = ContinuousClock.now
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent("stop-requested.json").path) {
                if ContinuousClock.now >= deadline { throw Failure(code: "Soak controller deadline exceeded") }
                if ContinuousClock.now >= next {
                    await downloads.refresh()
                    guard downloads.connected else { throw Failure(code: "Lost isolated engine connection") }
                    if let transfer = downloads.transfers.first {
                        downloads.selection = downloads.transfers[cycles % downloads.transfers.count].id
                        await downloads.loadFiles()
                        _ = try await downloads.diagnostics(hash: transfer.id)
                        _ = try await downloads.torrentBandwidth(hash: transfer.id)
                        _ = try await downloads.torrentSeeding(hash: transfer.id)
                    }
                    _ = try await downloads.engineSettings()
                    search.scope = ["downloads", "downloads:active", "downloads:queued", "downloads:seeding", "downloads:paused"][cycles % 5]
                    menu.menuNeedsUpdate(menu.menu)
                    window.contentView?.layoutSubtreeIfNeeded()
                    cycles += 1
                    let value: [String: Any] = ["status": "running", "cycles": cycles,
                        "at": ISO8601DateFormatter().string(from: Date()), "transfers": downloads.transfers.count,
                        "connected": downloads.connected, "download_bytes_per_second": downloads.downloadSpeed,
                        "upload_bytes_per_second": downloads.uploadSpeed]
                    try JSONSerialization.data(withJSONObject: value).write(to: report, options: .atomic)
                    next = ContinuousClock.now + .seconds(config.interval)
                }
                try await Task.sleep(for: .seconds(1))
            }
        }
        // Let pending actor/UI work finish, then verify that the long-lived owners released.
        for _ in 0..<30 {
            if oldDownloads == nil && oldSearch == nil && oldMenu == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let released = oldDownloads == nil && oldSearch == nil && oldMenu == nil
        try JSONSerialization.data(withJSONObject: ["status": released ? "stopped" : "retained-owners",
            "cycles": cycles, "owners_released": released]).write(to: report, options: .atomic)
        guard released else { throw Failure(code: "Soak models retained after teardown") }
    }
}
