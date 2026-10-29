import Foundation
import Testing
@testable import HarborCore

struct EngineBootstrapTests {
    @Test func freshProfileUsesLoopbackAuthenticationWithoutPlaintext() throws {
        let password = "0123456789abcdef0123456789abcdef"
        let data = try EngineBootstrap.settings(downloadDirectory: "/tmp/downloads", username: "harbor",
            password: password, salt: "abcdefgh", rpcPort: 9097)
        let settings = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(settings["rpc-password"] as? String == "{5a84082bd0a593ec24519d539f080a610b0bf170abcdefgh")
        #expect(!String(decoding: data, as: UTF8.self).contains(password))
        #expect(settings["rpc-bind-address"] as? String == "127.0.0.1")
        #expect(settings["rpc-authentication-required"] as? Bool == true)
        #expect(settings["rpc-whitelist-enabled"] as? Bool == true)
        #expect(settings["rpc-port"] as? Int == 9097)
        #expect(settings["download-dir"] as? String == "/tmp/downloads")
        #expect(settings["watch-dir-enabled"] as? Bool == false)
        #expect(settings["script-torrent-added-enabled"] as? Bool == false)
    }

    @Test func rejectsUnsafeBootstrapInputs() {
        for directory in ["relative", "", "/tmp/a\0b"] {
            #expect(throws: (any Error).self) {
                try EngineBootstrap.settings(downloadDirectory: directory, username: "harbor", password: "secret", salt: "abcdefgh")
            }
        }
        #expect(throws: (any Error).self) {
            try EngineBootstrap.settings(downloadDirectory: "/tmp", username: "bad:user", password: "secret", salt: "abcdefgh")
        }
        #expect(throws: (any Error).self) {
            try EngineBootstrap.settings(downloadDirectory: "/tmp", username: "harbor", password: "", salt: "abcdefgh")
        }
        #expect(throws: (any Error).self) {
            try EngineBootstrap.settings(downloadDirectory: "/tmp", username: "harbor", password: "secret", salt: "abcdefgh", rpcPort: 0)
        }
    }
}
