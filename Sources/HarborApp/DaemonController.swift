import AppKit
import Darwin
import HarborCore
import Security

/// Owns a foreground child process. Never starts a launchd/Homebrew service.
@MainActor @Observable final class DaemonController {
    static let shared = DaemonController()
    private(set) var running = false
    private(set) var starting = false
    private(set) var failure: String?
    private var process: Process?
    private var log: FileHandle?
    private var startTask: Task<Void, Error>?
    private var root: URL { HarborEnvironment.configRoot }

    func prepareFreshSession(directory: String) throws -> LocalCredentials {
        let settings = root.appendingPathComponent("settings.json")
        guard !FileManager.default.fileExists(atPath: settings.path) else {
            throw EngineError("An existing download profile was found. It has been left unchanged.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue, FileManager.default.isWritableFile(atPath: directory) else {
            throw EngineError("Choose an existing, writable download folder.")
        }
        let credentials: LocalCredentials
        if let existing = try ConnectionStore.load() { credentials = existing }
        else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw EngineError("Could not create the local connection credentials.")
            }
            credentials = LocalCredentials(username: "harbor", password: Data(bytes).base64EncodedString())
            try ConnectionStore.save(credentials)
        }
        let data = try EngineBootstrap.settings(downloadDirectory: directory, username: credentials.username,
            password: credentials.password, salt: UUID().uuidString.replacingOccurrences(of: "-", with: ""), rpcPort: HarborEnvironment.rpcPort)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try data.write(to: settings, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        return credentials
    }

    func start() async throws {
        if let startTask { return try await startTask.value }
        if let process, process.isRunning { return }
        let task = Task { @MainActor in try await self.launch() }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    private func launch() async throws {
        starting = true
        failure = nil
        defer { starting = false }
        do {
            guard NSRunningApplication.runningApplications(withBundleIdentifier: "org.m0k.transmission").isEmpty else {
                throw EngineError("Quit the Transmission app before starting Harbor's daemon. Both clients must not manage the same downloads.")
            }
            guard !portInUse() else {
                throw EngineError("The local control port is already in use. Stop the other Transmission instance before starting Harbor's daemon.")
            }
            let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/transmission-daemon").path
            let candidates = [bundled, "/opt/homebrew/opt/transmission-cli/bin/transmission-daemon", "/usr/local/opt/transmission-cli/bin/transmission-daemon"]
            guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw EngineError("The bundled download engine is missing. Reinstall Harbor, or install transmission-cli for a development build.")
            }
            let settings = root.appendingPathComponent("settings.json")
            guard FileManager.default.fileExists(atPath: settings.path) else {
                throw EngineError("Choose a download folder in Set Up Downloads before starting the engine.")
            }
            let credentials = try ConnectionStore.load()
            // Password is never passed as an argument or written as plaintext.
            // The migrated config contains Transmission's salted password verifier.
            let logs = HarborEnvironment.logRoot
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let logfile = logs.appendingPathComponent("transmission-daemon.log")
            if let size = try? logfile.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 5_000_000 {
                let previous = logs.appendingPathComponent("transmission-daemon.previous.log")
                try? FileManager.default.removeItem(at: previous)
                try FileManager.default.moveItem(at: logfile, to: previous)
            }
            if !FileManager.default.fileExists(atPath: logfile.path) {
                FileManager.default.createFile(atPath: logfile.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: logfile)
            try handle.seekToEnd()
            log = handle
            let child = Process()
            child.executableURL = URL(fileURLWithPath: binary)
            child.arguments = ["--foreground", "--config-dir", root.path, "--rpc-bind-address", "127.0.0.1", "--port", String(HarborEnvironment.rpcPort), "--auth", "--log-level", "warn"]
            child.standardOutput = handle
            child.standardError = handle
            child.standardInput = FileHandle.nullDevice
            // Inherit a private creation mask for settings/resume/log files.
            do {
                let previousMask = umask(0o077)
                defer { umask(previousMask) }
                try child.run()
            }
            process = child
            let client = credentials.map { TransmissionClient(username: $0.username, password: $0.password, port: HarborEnvironment.rpcPort) }
            for _ in 0..<20 {
                guard child.isRunning else { throw EngineError("The download engine stopped during startup. See Library/Logs/Harbor/transmission-daemon.log.") }
                do {
                    if let client { _ = try await client.sessionInfo() }
                    else {
                        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(HarborEnvironment.rpcPort)/transmission/rpc")!)
                        guard let http = response as? HTTPURLResponse, [401, 409].contains(http.statusCode) else { throw TransmissionError.unavailable }
                    }
                    running = true
                    return
                } catch TransmissionError.authentication { throw TransmissionError.authentication }
                catch { try await Task.sleep(for: .milliseconds(250)) }
            }
            throw EngineError("The download engine did not become ready. Check its log and local connection settings.")
        } catch {
            failure = error.localizedDescription
            // A failed readiness check must not leave a hidden engine behind.
            if let process, process.isRunning { process.terminate() }
            throw error
        }
    }

    func stop() async -> Bool {
        // Serialize termination with startup, including an immediate Quit after launch.
        if let startTask { _ = try? await startTask.value }
        guard let process else { return true }
        if process.isRunning { process.terminate() } // SIGTERM: flush resume/settings, then exit.
        for _ in 0..<150 {
            if !process.isRunning {
                self.process = nil
                running = false
                try? log?.close()
                log = nil
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        failure = "The download engine has not stopped yet. Harbor will stay open."
        return false
    }

    private func portInUse() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(HarborEnvironment.rpcPort).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    private struct EngineError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
