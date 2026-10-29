import Foundation
import CryptoKit
import Darwin
import Testing
import HarborCore
@testable import HarborApp

/// Opt-in: a disposable loopback-only engine, never the user's Harbor profile.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HARBOR_TEST_DAEMON"] != nil))
@MainActor struct EngineStressTests {
    @Test func transfersSettingsAndRestartRecovery() async throws {
        let engine = try IsolatedEngine()
        defer { engine.cleanup() }
        try await engine.start()
        let client = engine.client
        let model = DownloadsModel(client: client)
        await model.refresh()
        #expect(model.connected)
        #expect(model.transfers.isEmpty)

        // Complete local payload plus missing payloads, all private and trackerless.
        var hashes: [String] = []
        for index in 0..<32 {
            let torrent = try engine.torrent(index: index, complete: index == 0)
            let added = try await model.add(torrent: torrent, directory: engine.downloads.path, paused: true)
            #expect(!added.duplicate)
            hashes.append(added.hash)
            if index == 0 {
                let duplicate = try await model.add(torrent: torrent, directory: engine.downloads.path, paused: true)
                #expect(duplicate.duplicate)
            }
        }
        #expect(model.transfers.count == 32)
        #expect(model.count(for: "paused") == 32)
        print("Stress: 32 synthetic transfers and duplicate detection verified")

        let original = try await model.engineSettings()
        var settings = original
        settings.downloadQueueEnabled = true
        settings.downloadQueueSize = 2
        settings.queueStalledEnabled = false
        settings.speedLimitDownEnabled = true
        settings.speedLimitDown = 321
        settings.speedLimitUpEnabled = true
        settings.speedLimitUp = 123
        settings.seedRatioLimited = true
        settings.seedRatioLimit = 1.5
        let actual = try await model.saveEngineSettings(settings, previous: original)
        #expect(actual.downloadQueueSize == 2)
        #expect(actual.speedLimitDown == 321)
        #expect(actual.speedLimitUp == 123)
        #expect(actual.seedRatioLimit == 1.5)

        var bandwidth = try await model.torrentBandwidth(hash: hashes[1])
        bandwidth.downloadLimited = true; bandwidth.downloadLimit = 42
        bandwidth.uploadLimited = true; bandwidth.uploadLimit = 17
        bandwidth.honorsSessionLimits = false
        #expect(try await model.saveTorrentBandwidth(hash: hashes[1], settings: bandwidth) == bandwidth)
        var seeding = try await model.torrentSeeding(hash: hashes[0])
        seeding.seedRatioMode = .unlimited; seeding.seedIdleMode = .unlimited
        #expect(try await model.saveTorrentSeeding(hash: hashes[0], settings: seeding) == seeding)
        model.selection = hashes[1]
        await model.loadFiles()
        #expect(model.files.count == 1)
        try await client.setFile(hash: hashes[1], index: 0, wanted: false)
        #expect(try await client.files(hash: hashes[1]).first?.wanted == false)
        try await client.setFile(hash: hashes[1], index: 0, wanted: true)

        // Overlapping real RPC reads and independent updates exercise token negotiation.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for hash in hashes {
                group.addTask {
                    try await client.start(hash: hash)
                    _ = try await client.files(hash: hash)
                    _ = try await client.diagnostics(hash: hash)
                }
            }
            try await group.waitForAll()
        }
        try await engine.eventually {
            await model.refresh()
            return model.count(for: "active") == 2 && model.count(for: "queued") == 29 && model.count(for: "seeding") == 1
        }
        #expect(model.count(for: "active") == 2)
        #expect(model.count(for: "queued") == 29)
        #expect(model.count(for: "seeding") == 1)
        print("Stress: active/queued/seeding states, limits and concurrent RPC verified")

        for index in 1..<16 {
            try await client.pause(hash: hashes[index])
            try await client.move(hash: hashes[index], up: index.isMultiple(of: 2))
            try await client.start(hash: hashes[index])
        }
        try await engine.stop()
        await model.refresh()
        #expect(!model.connected)
        try await engine.start()
        // Reuse the SAME client: session token changes across engine restarts.
        await model.refresh()
        #expect(model.connected)
        #expect(model.transfers.count == 32)
        #expect(try await model.torrentBandwidth(hash: hashes[1]) == bandwidth)
        #expect(try await model.torrentSeeding(hash: hashes[0]) == seeding)
        #expect(try await model.engineSettings().speedLimitUp == 123)
        print("Stress: graceful restart persists transfers/settings and refresh recovers")

        try await engine.crash()
        await model.refresh()
        #expect(!model.connected)
        try await engine.start()
        await model.refresh()
        #expect(model.connected)
        #expect(model.transfers.count == 32)
        print("Stress: isolated daemon crash and reconnect verified")

        // Remove while the inspector is selected; never delete downloaded payloads.
        model.selection = hashes[0]
        await model.loadFiles()
        try await client.remove(hash: hashes[0])
        await model.refresh()
        #expect(model.selection == nil)
        #expect(model.files.isEmpty)
        #expect(try Data(contentsOf: engine.downloads.appendingPathComponent("Harbor stress 0.bin")) == engine.payload)
        await #expect(throws: (any Error).self) { _ = try await model.torrentSeeding(hash: hashes[0]) }
        for hash in hashes.dropFirst() { try await client.remove(hash: hash) }
        await model.refresh()
        #expect(model.transfers.isEmpty)
        for _ in 0..<3 {
            try await engine.stop()
            try await engine.start()
            await model.refresh()
            #expect(model.connected && model.transfers.isEmpty)
        }
        try await engine.stop()
        print("Stress: selected removal keeps payload; three further restart cycles passed")
    }
}

@MainActor private final class IsolatedEngine {
    let root: URL
    let downloads: URL
    let client: TransmissionClient
    let binary: String
    let payload = Data(repeating: 65, count: 16_384)
    private var child: Process?
    private let log: FileHandle

    init() throws {
        binary = ProcessInfo.processInfo.environment["HARBOR_TEST_DAEMON"]!
        guard binary.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: binary) else {
            throw Failure(message: "HARBOR_TEST_DAEMON must be an absolute executable path")
        }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-stress-\(UUID().uuidString)")
        downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let port = try Self.freePort()
        let password = UUID().uuidString + UUID().uuidString
        client = TransmissionClient(username: "stress", password: password, port: port)
        var config = try JSONSerialization.jsonObject(with: EngineBootstrap.settings(
            downloadDirectory: downloads.path, username: "stress", password: password,
            salt: UUID().uuidString, rpcPort: port)) as! [String: Any]
        config["peer-port"] = try Self.freePort()
        config["bind-address-ipv4"] = "127.0.0.1"
        config["bind-address-ipv6"] = "::1"
        config["dht-enabled"] = false; config["pex-enabled"] = false
        config["lpd-enabled"] = false; config["port-forwarding-enabled"] = false
        try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("settings.json"))
        let logURL = root.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        log = try FileHandle(forWritingTo: logURL)
    }
    func start() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--foreground", "--config-dir", root.path, "--log-level", "warn"]
        process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "TMPDIR": root.path]
        process.standardOutput = log; process.standardError = log
        process.standardInput = FileHandle.nullDevice
        try process.run(); child = process
        try await eventually {
            guard process.isRunning else { throw Failure(message: "Test engine exited during startup") }
            do { _ = try await self.client.sessionInfo(); return true } catch { return false }
        }
    }
    func stop() async throws {
        guard let child else { return }
        if child.isRunning { child.terminate() }
        try await eventually { !child.isRunning }
        #expect(child.terminationStatus == 0)
        self.child = nil
    }
    func crash() async throws {
        guard let child, child.isRunning else { throw Failure(message: "No test process to crash") }
        // Only the Process instance created by this fixture; no process-name matching.
        kill(child.processIdentifier, SIGKILL)
        try await eventually { !child.isRunning }
        self.child = nil
    }
    func eventually(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure(message: "Timed out waiting for isolated engine state")
    }
    func torrent(index: Int, complete: Bool) throws -> Data {
        let name = "Harbor stress \(index).bin"
        if complete { try payload.write(to: downloads.appendingPathComponent(name)) }
        let digest = Data(Insecure.SHA1.hash(data: payload))
        var data = Data("d4:infod6:lengthi16384e4:name\(name.utf8.count):\(name)12:piece lengthi16384e6:pieces20:".utf8)
        data.append(digest); data.append(Data("7:privatei1eee".utf8))
        return data
    }
    func cleanup() {
        if let child, child.isRunning {
            // Bounded emergency cleanup applies only to this disposable child.
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
        }
        try? log.close()
        try? FileManager.default.removeItem(at: root)
    }
    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "Could not allocate test socket") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw Failure(message: "Could not bind test socket") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard read == 0 else { throw Failure(message: "Could not read test port") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
    private struct Failure: Error { let message: String }
}
