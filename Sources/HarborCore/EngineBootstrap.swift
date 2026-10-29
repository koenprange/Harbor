import Foundation
import CryptoKit

/// Generates only a fresh session. Existing configuration must never pass through this path.
public enum EngineBootstrap {
    public static func settings(downloadDirectory: String, username: String, password: String,
                                salt: String, rpcPort: Int = 9091) throws -> Data {
        guard downloadDirectory.hasPrefix("/"), !downloadDirectory.contains("\0"),
              !username.isEmpty, !username.contains(":"), !password.isEmpty,
              salt.count >= 8, (1...65535).contains(rpcPort) else { throw TransmissionError.invalidRequest }
        // Transmission's native salted verifier is "{" + SHA1(password + salt) + salt.
        let digest = Insecure.SHA1.hash(data: Data((password + salt).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let settings: [String: Any] = [
            "rpc-enabled": true, "rpc-bind-address": "127.0.0.1", "rpc-port": rpcPort,
            "rpc-authentication-required": true, "rpc-username": username,
            "rpc-password": "{" + digest + salt, "rpc-whitelist-enabled": true,
            "rpc-whitelist": "127.0.0.1", "rpc-host-whitelist-enabled": true,
            "rpc-host-whitelist": "localhost", "download-dir": downloadDirectory,
            "incomplete-dir": downloadDirectory, "incomplete-dir-enabled": false,
            "peer-port": 51413, "peer-port-random-on-start": false,
            "port-forwarding-enabled": true, "dht-enabled": true, "pex-enabled": true,
            "lpd-enabled": false, "encryption": 1, "download-queue-enabled": true,
            "download-queue-size": 5, "seed-queue-enabled": false, "seed-queue-size": 10,
            "ratio-limit-enabled": false, "ratio-limit": 2.0,
            "idle-seeding-limit-enabled": false, "idle-seeding-limit": 30,
            "start-added-torrents": true, "rename-partial-files": true,
            "watch-dir-enabled": false, "script-torrent-added-enabled": false,
            "script-torrent-done-enabled": false, "script-torrent-done-seeding-enabled": false,
            "umask": "077"]
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }
}
