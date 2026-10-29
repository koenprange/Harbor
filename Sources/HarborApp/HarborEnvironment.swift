import Foundation

/// Isolated install-test bundles cannot touch the production profile or Keychain item.
enum HarborEnvironment {
    static var isInstallTest: Bool { Bundle.main.bundleIdentifier?.hasSuffix(".installtest") == true }
    static var supportRoot: URL {
        if isInstallTest, let path = Bundle.main.object(forInfoDictionaryKey: "HarborTestDataRoot") as? String {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Harbor", isDirectory: true)
    }
    static var configRoot: URL { supportRoot.appendingPathComponent("Transmission", isDirectory: true) }
    static var rpcPort: Int {
        if isInstallTest, let port = Bundle.main.object(forInfoDictionaryKey: "HarborTestRPCPort") as? Int,
           (1024...65535).contains(port) { return port }
        return 9091
    }
    static var needsSetup: Bool {
        !FileManager.default.fileExists(atPath: configRoot.appendingPathComponent("settings.json").path)
    }
    static var defaultDownloadDirectory: String {
        if isInstallTest, let path = Bundle.main.object(forInfoDictionaryKey: "HarborTestDownloadDirectory") as? String { return path }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    }
    static var logRoot: URL {
        if isInstallTest { return supportRoot.appendingPathComponent("Logs", isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Harbor", isDirectory: true)
    }
}
