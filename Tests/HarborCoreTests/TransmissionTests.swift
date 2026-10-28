import Foundation
import Testing
@testable import HarborCore

@Suite(.serialized) struct TransmissionTests {
    private func client(_ replies: [RPCMock.Reply]) -> TransmissionClient {
        RPCMock.state.reset(replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RPCMock.self]
        return TransmissionClient(username: "test-user", password: "test-password", session: URLSession(configuration: configuration))
    }

    @Test func readsAndWritesOnlyDownloadSettings() async throws {
        let values: [String: Any] = ["speed_limit_down": 1500, "speed_limit_down_enabled": true,
            "speed_limit_up": 0, "speed_limit_up_enabled": false, "download_queue_enabled": true,
            "download_queue_size": 3, "queue_stalled_enabled": false, "alt_speed_enabled": false].merging(extraSettings) { old, _ in old }
        let client = client([.init(result: values), .init(result: [:])])
        let settings = try await client.settings()
        #expect(settings.speedLimitDown == 1500)
        #expect(settings.speedLimitUp == 0)
        #expect(settings.downloadQueueSize == 3)
        try await client.updateSettings(settings)
        let requests = RPCMock.state.requests
        let read = try RPCMock.body(requests[0])
        #expect(read["method"] as? String == "session_get")
        let fields = try #require((read["params"] as? [String: Any])?["fields"] as? [String])
        #expect(Set(fields) == Set(values.keys))
        let write = try RPCMock.body(requests[1])
        #expect(write["method"] as? String == "session_set")
        let params = try #require(write["params"] as? [String: Any])
        #expect(Set(params.keys) == Set(values.keys))
        #expect(params["speed_limit_down"] as? Int == 1500)
        #expect(params["speed_limit_up_enabled"] as? Bool == false)
        #expect(params["queue_stalled_enabled"] as? Bool == false)
        #expect(params["download_queue_size"] as? Int == 3)
    }

    @Test func rejectsInvalidSettingsWithoutWriting() async throws {
        let values: [String: Any] = ["speed_limit_down": 100, "speed_limit_down_enabled": true,
            "speed_limit_up": 50, "speed_limit_up_enabled": true, "download_queue_enabled": true,
            "download_queue_size": 3, "queue_stalled_enabled": true, "alt_speed_enabled": false].merging(extraSettings) { old, _ in old }
        let client = client([.init(result: values)])
        let original = try await client.settings()
        for invalid in [-1, 1_000_000_001] {
            var settings = original; settings.speedLimitDown = invalid
            await #expect(throws: (any Error).self) { try await client.updateSettings(settings) }
            settings = original; settings.speedLimitUp = invalid
            await #expect(throws: (any Error).self) { try await client.updateSettings(settings) }
        }
        for invalid in [0, 10_001] {
            var settings = original; settings.downloadQueueSize = invalid
            await #expect(throws: (any Error).self) { try await client.updateSettings(settings) }
        }
        #expect(RPCMock.state.requests.count == 1)
    }

    private var extraSettings: [String: Any] {
        ["queue_stalled_minutes": 30, "seed_ratio_limit": 2.5, "seed_ratio_limited": true,
         "idle_seeding_limit": 30, "idle_seeding_limit_enabled": false,
         "seed_queue_enabled": false, "seed_queue_size": 3,
         "alt_speed_down": 10, "alt_speed_up": 10, "alt_speed_time_enabled": false,
         "alt_speed_time_begin": 240, "alt_speed_time_end": 840, "alt_speed_time_day": 127,
         "peer_limit_global": 200, "peer_limit_per_torrent": 60, "peer_port": 51413,
         "peer_port_random_on_start": false, "port_forwarding_enabled": true,
         "dht_enabled": true, "pex_enabled": true, "lpd_enabled": false, "encryption": "preferred",
         "download_dir": "/tmp/downloads", "incomplete_dir": "/tmp/incomplete",
         "incomplete_dir_enabled": true, "rename_partial_files": true, "start_added_torrents": true]
    }

    @Test func fractionalRatioAndChangedFieldsOnly() async throws {
        let values = extraSettings.merging(["speed_limit_down": 100, "speed_limit_down_enabled": false,
            "speed_limit_up": 50, "speed_limit_up_enabled": false, "download_queue_enabled": false,
            "download_queue_size": 3, "queue_stalled_enabled": false, "alt_speed_enabled": false]) { _, new in new }
        let client = client([.init(result: values), .init(result: [:])])
        let original = try await client.settings()
        #expect(original.seedRatioLimit == 2.5)
        var changed = original; changed.seedRatioLimit = 1.25; changed.idleSeedingLimitEnabled = true
        try await client.updateSettings(changed, previous: original)
        let body = try RPCMock.body(try #require(RPCMock.state.requests.last))
        let params = try #require(body["params"] as? [String: Any])
        #expect(Set(params.keys) == ["seed_ratio_limit", "idle_seeding_limit_enabled"])
        #expect(params["seed_ratio_limit"] as? Double == 1.25)
        #expect(params["idle_seeding_limit_enabled"] as? Bool == true)
        try await client.updateSettings(original, previous: original)
        #expect(RPCMock.state.requests.count == 2)
        for invalid in [Double.nan, Double.infinity, -0.1, 10_001] {
            var bad = original; bad.seedRatioLimit = invalid
            await #expect(throws: (any Error).self) { try await client.updateSettings(bad) }
        }
        var invalid = original; invalid.peerPort = 65536
        #expect(invalid.validationError != nil)
        invalid = original; invalid.altSpeedTimeEnabled = true; invalid.altSpeedTimeDay = 0
        #expect(invalid.validationError != nil)
        invalid = original; invalid.downloadDir = "relative/path"
        #expect(invalid.validationError != nil)
        #expect(RPCMock.state.requests.count == 2)
    }

    @Test func perTorrentSeedOverridesAreHashScoped() async throws {
        let fields: [String: Any] = ["seed_ratio_mode": 0, "seed_ratio_limit": 2.0, "seed_idle_mode": 0, "seed_idle_limit": 30]
        let client = client([.init(result: ["torrents": [fields]]), .init(result: [:]), .init(result: [:]), .init(result: [:])])
        let original = try await client.seeding(hash: testHash)
        #expect(original.seedRatioMode == .global)
        var custom = original; custom.seedRatioMode = .custom; custom.seedRatioLimit = 1.25
        try await client.setSeeding(hash: testHash, settings: custom)
        var unlimited = original; unlimited.seedRatioMode = .unlimited; unlimited.seedIdleMode = .unlimited
        try await client.setSeeding(hash: testHash, settings: unlimited)
        try await client.setSeeding(hash: testHash, settings: original)
        for request in RPCMock.state.requests {
            let body = try RPCMock.body(request)
            let params = try #require(body["params"] as? [String: Any])
            #expect(params["ids"] as? [String] == [testHash])
            #expect(body["method"] as? String != "session_set")
        }
        let customBody = try RPCMock.body(RPCMock.state.requests[1])
        let params = try #require(customBody["params"] as? [String: Any])
        #expect(params["seed_ratio_limit"] as? Double == 1.25)
        #expect(params["seed_ratio_mode"] as? Int == 1)
        let unlimitedBody = try RPCMock.body(RPCMock.state.requests[2])
        let unlimitedParams = try #require(unlimitedBody["params"] as? [String: Any])
        #expect(unlimitedParams["seed_ratio_mode"] as? Int == 2)
        #expect(unlimitedParams["seed_idle_mode"] as? Int == 2)
        #expect(Set(unlimitedParams.keys) == ["ids", "seed_ratio_mode", "seed_ratio_limit", "seed_idle_mode", "seed_idle_limit"])
    }

    @Test func seedOverridesRejectInvalidTargetsAndDeletedTorrents() async throws {
        let fields: [String: Any] = ["seed_ratio_mode": 0, "seed_ratio_limit": 2.0, "seed_idle_mode": 0, "seed_idle_limit": 30]
        let client = client([.init(result: ["torrents": [fields]]), .init(result: ["torrents": []])])
        let original = try await client.seeding(hash: testHash)
        await #expect(throws: (any Error).self) { try await client.setSeeding(hash: "", settings: original) }
        for invalid in [Double.nan, Double.infinity, -1, 10_001] {
            var bad = original; bad.seedRatioLimit = invalid
            await #expect(throws: (any Error).self) { try await client.setSeeding(hash: testHash, settings: bad) }
        }
        var bad = original; bad.seedIdleLimit = 0
        await #expect(throws: (any Error).self) { try await client.setSeeding(hash: testHash, settings: bad) }
        #expect(RPCMock.state.requests.count == 1)
        await #expect(throws: (any Error).self) { try await client.seeding(hash: testHash) }
    }

    @Test func torrentBandwidthOverridesAndGeneralInheritanceAreScoped() async throws {
        let values: [String: Any] = ["download_limit": 100, "download_limited": false,
            "upload_limit": 50, "upload_limited": false, "honors_session_limits": true]
        let client = client([.init(result: ["torrents": [values]]), .init(result: [:]), .init(result: [:]), .init(result: [:])])
        let original = try await client.bandwidth(hash: testHash)
        #expect(original.honorsSessionLimits)
        #expect(!original.downloadLimited && !original.uploadLimited)
        var custom = original; custom.downloadLimit = 1500; custom.downloadLimited = true
        custom.uploadLimit = 0; custom.uploadLimited = true
        try await client.setBandwidth(hash: testHash, settings: custom)
        custom.honorsSessionLimits = false
        try await client.setBandwidth(hash: testHash, settings: custom)
        try await client.setBandwidth(hash: testHash, settings: original)
        for request in RPCMock.state.requests {
            let body = try RPCMock.body(request)
            let params = try #require(body["params"] as? [String: Any])
            #expect(params["ids"] as? [String] == [testHash])
            #expect(body["method"] as? String != "session_set")
        }
        let body = try RPCMock.body(RPCMock.state.requests[1])
        let params = try #require(body["params"] as? [String: Any])
        #expect(Set(params.keys) == ["ids", "download_limit", "download_limited", "upload_limit", "upload_limited", "honors_session_limits"])
        #expect(params["download_limit"] as? Int == 1500)
        #expect(params["upload_limit"] as? Int == 0)
        #expect(params["honors_session_limits"] as? Bool == true)
        let bypass = try RPCMock.body(RPCMock.state.requests[2])
        #expect((bypass["params"] as? [String: Any])?["honors_session_limits"] as? Bool == false)
    }

    @Test func invalidTorrentBandwidthNeverMutates() async throws {
        let values: [String: Any] = ["download_limit": 100, "download_limited": false,
            "upload_limit": 50, "upload_limited": false, "honors_session_limits": true]
        let client = client([.init(result: ["torrents": [values]]), .init(result: ["torrents": []])])
        let original = try await client.bandwidth(hash: testHash)
        await #expect(throws: (any Error).self) { try await client.setBandwidth(hash: "", settings: original) }
        for invalid in [-1, 1_000_000_001] {
            var bad = original; bad.downloadLimit = invalid
            await #expect(throws: (any Error).self) { try await client.setBandwidth(hash: testHash, settings: bad) }
            bad = original; bad.uploadLimit = invalid
            await #expect(throws: (any Error).self) { try await client.setBandwidth(hash: testHash, settings: bad) }
        }
        #expect(RPCMock.state.requests.count == 1)
        await #expect(throws: (any Error).self) { try await client.bandwidth(hash: testHash) }
    }

    @Test func diagnosticsDistinguishTrackerEstimatesFromConnections() async throws {
        func tracker(_ id: Int, seeds: Int, leechers: Int) -> [String: Any] {
            ["id": id, "announce": "https://tracker.example/announce?passkey=do-not-display",
             "announce_state": 1, "has_announced": true, "last_announce_succeeded": true,
             "last_announce_timed_out": false, "last_announce_result": "Success",
             "last_announce_time": 100, "next_announce_time": 200,
             "seeder_count": seeds, "leecher_count": leechers, "is_backup": false,
             "has_scraped": false, "last_scrape_succeeded": false,
             "last_scrape_result": "", "last_scrape_time": 0]
        }
        var timeout = tracker(2, seeds: -1, leechers: -1)
        timeout["last_announce_succeeded"] = false; timeout["last_announce_timed_out"] = true
        var pending = tracker(3, seeds: 4, leechers: 9)
        pending["has_announced"] = false; pending["is_backup"] = true
        let fields: [String: Any] = ["peers_connected": 0, "peers_sending_to_us": 0,
            "peers_getting_from_us": 0, "desired_available": 0, "left_until_done": 1000,
            "is_stalled": true, "tracker_stats": [tracker(1, seeds: 7, leechers: 3), timeout, pending]]
        let client = client([.init(result: ["torrents": [fields]]), .init(result: ["torrents": []])])
        let result = try await client.diagnostics(hash: testHash)
        #expect(result.peersConnected == 0)
        #expect(result.reportedSeeders == 7)
        #expect(result.reportedLeechers == 9)
        #expect(result.trackerStats[0].displayName == "tracker.example")
        #expect(result.trackerStats[0].announceStatus == "Announce succeeded")
        #expect(result.trackerStats[1].knownSeeders == nil)
        #expect(result.trackerStats[1].announceStatus == "Timed out")
        #expect(result.trackerStats[2].announceStatus == "Backup · not contacted yet")
        let body = try RPCMock.body(try #require(RPCMock.state.requests.first))
        #expect(body["method"] as? String == "torrent_get")
        let params = try #require(body["params"] as? [String: Any])
        #expect(params["ids"] as? [String] == [testHash])
        #expect((params["fields"] as? [String])?.contains("tracker_stats") == true)
        await #expect(throws: (any Error).self) { try await client.diagnostics(hash: "") }
        #expect(RPCMock.state.requests.count == 1)
        await #expect(throws: (any Error).self) { try await client.diagnostics(hash: testHash) }
    }

    @Test func unknownTrackerCountsAreNotZero() throws {
        let json = #"{"peers_connected":0,"peers_sending_to_us":0,"peers_getting_from_us":0,"desired_available":0,"left_until_done":10,"is_stalled":false,"tracker_stats":[]}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let details = try decoder.decode(TransferDiagnostics.self, from: Data(json.utf8))
        #expect(details.reportedSeeders == nil)
        #expect(details.reportedLeechers == nil)
    }

    @Test func activePeersFollowTransferDirectionWithoutDoubleCounting() throws {
        let base: [String: Any] = ["hash_string": testHash, "name": "Example", "status": 4,
            "percent_done": 0.5, "rate_download": 1000, "rate_upload": 20, "eta": 120,
            "total_size": 4000, "downloaded_ever": 2000, "uploaded_ever": 200, "upload_ratio": 0.1,
            "download_dir": "/tmp/downloads", "error": 0, "error_string": "", "queue_position": 0,
            "peers_connected": 8, "peers_sending_to_us": 3, "peers_getting_from_us": 5, "metadata_percent_complete": 1.0]
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        for (status, expected) in [(4, 3), (6, 5), (0, 0), (3, 0)] {
            var fields = base; fields["status"] = status
            let transfer = try decoder.decode(Transfer.self, from: JSONSerialization.data(withJSONObject: fields))
            #expect(transfer.activePeerCount == expected)
            #expect(transfer.peerActivityText == "\(expected)/8 peers active")
        }
        var fields = base; fields["peers_connected"] = 0
        let empty = try decoder.decode(Transfer.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(empty.peerActivityText == "0/0 peers active")
    }

    @Test func negotiatesSessionAndUsesOnlyTheLocalEndpoint() async throws {
        let client = client([.init(status: 409, headers: ["X-Transmission-Session-Id": "test-session"]),
                             .init(result: ["version": "4.1.4", "download_dir": "/tmp/downloads"])])
        let info = try await client.sessionInfo()
        #expect(info.version == "4.1.4")
        #expect(info.downloadDir == "/tmp/downloads")
        let requests = RPCMock.state.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url == TransmissionClient.endpoint })
        #expect(requests[1].value(forHTTPHeaderField: "X-Transmission-Session-Id") == "test-session")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Basic " + Data("test-user:test-password".utf8).base64EncodedString())
        #expect(try RPCMock.body(requests[1])["method"] as? String == "session_get")
    }

    @Test func rejectsAuthenticationAndServerErrors() async {
        let denied = client([.init(status: 401)])
        await #expect(throws: (any Error).self) { try await denied.sessionInfo() }
        #expect(RPCMock.state.requests.count == 1)
        let rejected = client([.init(error: ["code": 7, "message": "Rejected", "data": ["error_string": "invalid torrent"]])])
        await #expect(throws: (any Error).self) { try await rejected.pause(hash: testHash) }
    }

    @Test func neverRetriesMutationAfterTransportFailure() async {
        let client = client([.init(failure: true)])
        await #expect(throws: (any Error).self) { try await client.start(hash: testHash) }
        #expect(RPCMock.state.requests.count == 1)
    }

    @Test func capsSessionNegotiationAndRejectsMismatchedResponses() async {
        let repeated = client([.init(status: 409, headers: ["X-Transmission-Session-Id": "a"]),
                               .init(status: 409, headers: ["X-Transmission-Session-Id": "b"])])
        await #expect(throws: (any Error).self) { try await repeated.sessionInfo() }
        #expect(RPCMock.state.requests.count == 2)
        let mismatch = client([.init(result: ["version": "4.1.4", "download_dir": "/tmp"], mismatchID: true)])
        await #expect(throws: (any Error).self) { try await mismatch.sessionInfo() }
    }

    @Test func removalPreservesPayloadAndUsesStableHash() async throws {
        let client = client([.init(result: [:])])
        try await client.remove(hash: testHash)
        let request = try #require(RPCMock.state.requests.first)
        let body = try RPCMock.body(request)
        #expect(body["method"] as? String == "torrent_remove")
        let params = try #require(body["params"] as? [String: Any])
        #expect(params["ids"] as? [String] == [testHash])
        #expect(params["delete_local_data"] as? Bool == false)
    }

    @Test func addsPausedTorrentAndDetectsDuplicates() async throws {
        let client = client([.init(result: ["torrent_duplicate": ["hash_string": testHash.uppercased()]])])
        let data = Data("d4:infod4:name4:test6:lengthi1eee".utf8)
        let result = try await client.add(torrent: data, directory: "/tmp/downloads", paused: true)
        #expect(result.duplicate)
        #expect(result.hash == testHash)
        let body = try RPCMock.body(try #require(RPCMock.state.requests.first))
        let params = try #require(body["params"] as? [String: Any])
        #expect(params["paused"] as? Bool == true)
        #expect(params["metainfo"] as? String == data.base64EncodedString())
        #expect(params["download_dir"] as? String == "/tmp/downloads")
    }

    @Test func rejectsInvalidReferencesBeforeSendingAnything() async {
        let client = client([])
        await #expect(throws: (any Error).self) { try await client.pause(hash: "") }
        await #expect(throws: (any Error).self) { try await client.setFile(hash: testHash, index: -1, wanted: true) }
        await #expect(throws: (any Error).self) { try await client.add(magnet: URL(string: "https://evil.example/")!, directory: nil, paused: true) }
        await #expect(throws: (any Error).self) { try await client.add(torrent: Data("<html>not a torrent</html>".utf8), directory: nil, paused: true) }
        #expect(RPCMock.state.requests.isEmpty)
    }

    @Test func decodesTransfersAndFileSelection() async throws {
        let fields: [String: Any] = ["hash_string": testHash, "name": "Example", "status": 4,
            "percent_done": 0.5, "rate_download": 1000, "rate_upload": 20, "eta": 120,
            "total_size": 4000, "downloaded_ever": 2000, "uploaded_ever": 200, "upload_ratio": 0.1,
            "download_dir": "/tmp/downloads", "error": 0, "error_string": "", "queue_position": 0,
            "peers_connected": 2, "peers_sending_to_us": 1, "peers_getting_from_us": 1, "metadata_percent_complete": 1.0]
        let client = client([.init(result: ["torrents": [fields]]),
            .init(result: ["torrents": [["files": [["name": "example.iso", "length": 4000, "bytes_completed": 2000]],
                                      "file_stats": [["wanted": false]]]]])])
        let transfer = try #require(try await client.transfers().first)
        #expect(transfer.statusText == "Downloading")
        #expect(transfer.peerActivityText == "1/2 peers active")
        #expect(transfer.progress == 0.5)
        #expect(transfer.formattedETA == "2m")
        let file = try #require(try await client.files(hash: testHash).first)
        #expect(!file.wanted)
        #expect(file.progress == 0.5)
        #expect(file.id == 0)
    }
}

private final class RPCMock: URLProtocol, @unchecked Sendable {
    struct Reply: @unchecked Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var result: [String: Any]? = nil
        var error: [String: Any]? = nil
        var failure = false
        var mismatchID = false
    }
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [Reply] = []
        private var seen: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { seen } }
        func reset(_ replies: [Reply]) { lock.withLock { self.replies = replies; seen = [] } }
        func next(_ request: URLRequest) -> Reply {
            lock.withLock {
                seen.append(request)
                return replies.isEmpty ? Reply(status: 500) : replies.removeFirst()
            }
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func body(_ request: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
    }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
            captured.httpBody = data
        }
        let reply = Self.state.next(captured)
        if reply.failure { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let id = ((try? Self.body(captured)["id"]) as? Int ?? 0) + (reply.mismatchID ? 100 : 0)
        var envelope: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let result = reply.result { envelope["result"] = result }
        if let error = reply.error { envelope["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: envelope) { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
