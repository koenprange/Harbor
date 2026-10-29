import AppKit
import SwiftUI
import HarborCore

@MainActor @Observable final class DownloadsModel {
    var transfers: [Transfer] = []
    var selection: String?
    var files: [TransferFile] = []
    var filter = ""
    var filterText = ""
    var connected = false
    var configured = false
    var status = "Set up the local connection"
    var username = "harbor"
    var defaultDirectory = ""
    var error: String?
    var setupRequired = HarborEnvironment.needsSetup
    var showSetup = false
    var showConnection = false
    var showSettings = false
    var busy = false
    var loadingFiles = false
    private var client: TransmissionClient?
    private var pollTask: Task<Void, Never>?
    private var refreshing = false
    private var filesRequest = UUID()

    init() {
        do {
            if let credentials = try ConnectionStore.load() { use(credentials) }
        } catch { status = error.localizedDescription }
    }
    private func use(_ credentials: LocalCredentials) {
        username = credentials.username
        client = TransmissionClient(username: credentials.username, password: credentials.password, port: HarborEnvironment.rpcPort)
        configured = true
        connected = false
        defaultDirectory = ""
        status = "Connecting…"
    }
    func saveConnection(username: String, password: String) async throws {
        guard !username.isEmpty, !username.contains(":"), !password.isEmpty else { throw TransmissionError.invalidRequest }
        let candidate = TransmissionClient(username: username, password: password, port: HarborEnvironment.rpcPort)
        let info = try await candidate.sessionInfo()
        let credentials = LocalCredentials(username: username, password: password)
        try ConnectionStore.save(credentials)
        use(credentials)
        defaultDirectory = info.downloadDir
        await refresh()
    }
    func completeSetup(directory: String) async throws {
        let credentials = try DaemonController.shared.prepareFreshSession(directory: directory)
        use(credentials)
        setupRequired = false
        try await DaemonController.shared.start()
        await refresh()
        showSetup = false
    }
    func presentSettings() {
        if setupRequired { showSetup = true }
        else { showSettings = true }
    }
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    func refresh() async {
        guard let client, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            if defaultDirectory.isEmpty { defaultDirectory = try await client.sessionInfo().downloadDir }
            let transfers = try await client.transfers()
            self.transfers = transfers
            connected = true
            status = "Connected locally"
            if let selection, !transfers.contains(where: { $0.id == selection }) { self.selection = nil; files = [] }
        } catch is CancellationError { }
        catch { connected = false; status = error.localizedDescription }
    }
    var selected: Transfer? { transfers.first { $0.id == selection } }
    var filterTitle: String {
        switch filter {
        case "active": "Active Downloads"
        case "queued": "Queued Downloads"
        case "seeding": "Seeding"
        case "paused": "Paused Downloads"
        case "complete": "Completed Downloads"
        default: "All Downloads"
        }
    }

    private func matches(_ transfer: Transfer, filter: String) -> Bool {
        filter.isEmpty || filter == "active" && transfer.status == 4 || filter == "queued" && transfer.status == 3 || filter == "seeding" && transfer.status == 6 || filter == "paused" && transfer.isPaused || filter == "complete" && transfer.isComplete
    }

    func count(for filter: String) -> Int {
        transfers.filter { matches($0, filter: filter) }.count
    }

    var visible: [Transfer] {
        transfers.filter { transfer in
            matches(transfer, filter: filter)
                && (filterText.isEmpty || transfer.name.localizedCaseInsensitiveContains(filterText))
        }
    }
    var downloadSpeed: Int64 { transfers.reduce(0) { $0 + $1.rateDownload } }
    var uploadSpeed: Int64 { transfers.reduce(0) { $0 + $1.rateUpload } }

    func loadFiles() async {
        filesRequest = UUID()
        let request = filesRequest
        files = []
        guard let hash = selection, let client else { loadingFiles = false; return }
        loadingFiles = true
        defer { if request == filesRequest { loadingFiles = false } }
        do {
            let result = try await client.files(hash: hash)
            guard selection == hash, request == filesRequest else { return }
            files = result
        } catch { if request == filesRequest { self.error = error.localizedDescription } }
    }
    func toggle(_ transfer: Transfer) { action { client in
        if transfer.isPaused { try await client.start(hash: transfer.id) }
        else { try await client.pause(hash: transfer.id) }
    } }
    func move(_ transfer: Transfer, up: Bool) { action { try await $0.move(hash: transfer.id, up: up) } }
    func remove(_ transfer: Transfer) { action { try await $0.remove(hash: transfer.id) } }
    func setWanted(_ file: TransferFile, hash: String, wanted: Bool) {
        action { client in
            try await client.setFile(hash: hash, index: file.id, wanted: wanted)
            if self.selection == hash { await self.loadFiles() }
        }
    }
    private func action(_ operation: @escaping @MainActor (TransmissionClient) async throws -> Void) {
        guard let client, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await operation(client); await refresh() }
            catch { self.error = error.localizedDescription }
        }
    }
    func add(magnet: URL? = nil, torrent: Data? = nil, directory: String?, paused: Bool) async throws -> TransferAddition {
        guard let client else { throw TransmissionError.unavailable }
        let result = try await client.add(magnet: magnet, torrent: torrent, directory: directory, paused: paused)
        await refresh()
        selection = result.hash
        return result
    }
    func engineSettings() async throws -> TransmissionSettings {
        guard let client else { throw TransmissionError.unavailable }
        return try await client.settings()
    }
    func saveEngineSettings(_ settings: TransmissionSettings, previous: TransmissionSettings? = nil) async throws -> TransmissionSettings {
        guard let client else { throw TransmissionError.unavailable }
        try await client.updateSettings(settings, previous: previous)
        let actual = try await client.settings()
        defaultDirectory = actual.downloadDir
        return actual
    }
    func torrentSeeding(hash: String) async throws -> TorrentSeeding {
        guard let client else { throw TransmissionError.unavailable }
        return try await client.seeding(hash: hash)
    }
    func saveTorrentSeeding(hash: String, settings: TorrentSeeding) async throws -> TorrentSeeding {
        guard let client else { throw TransmissionError.unavailable }
        try await client.setSeeding(hash: hash, settings: settings)
        let actual = try await client.seeding(hash: hash)
        await refresh()
        return actual
    }
    func torrentBandwidth(hash: String) async throws -> TorrentBandwidth {
        guard let client else { throw TransmissionError.unavailable }
        return try await client.bandwidth(hash: hash)
    }
    func saveTorrentBandwidth(hash: String, settings: TorrentBandwidth) async throws -> TorrentBandwidth {
        guard let client else { throw TransmissionError.unavailable }
        try await client.setBandwidth(hash: hash, settings: settings)
        let actual = try await client.bandwidth(hash: hash)
        await refresh()
        return actual
    }
    func diagnostics(hash: String) async throws -> TransferDiagnostics {
        guard let client else { throw TransmissionError.unavailable }
        return try await client.diagnostics(hash: hash)
    }
    func reveal(_ transfer: Transfer) {
        let directory = URL(fileURLWithPath: transfer.downloadDir, isDirectory: true)
        let target = directory.appendingPathComponent(transfer.name)
        if FileManager.default.fileExists(atPath: target.path) {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } else { NSWorkspace.shared.open(directory) }
    }
    func chooseDirectory(current: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !current.isEmpty { panel.directoryURL = URL(fileURLWithPath: current) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
