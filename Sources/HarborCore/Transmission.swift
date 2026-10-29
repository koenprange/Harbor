import Foundation

public enum RPCValue: Codable, Sendable, Equatable {
    case string(String), int(Int), double(Double), bool(Bool), array([RPCValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else { self = .array(try c.decode([RPCValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        }
    }
}

public enum TransmissionError: LocalizedError, Sendable {
    case authentication, unavailable, invalidResponse, invalidRequest, server(String), oversized
    public var errorDescription: String? {
        switch self {
        case .authentication: "Transmission rejected the login. Check the connection settings."
        case .unavailable: "Cannot connect to Transmission on this Mac. Quit and reopen Harbor to restart the download engine, then check the local connection settings."
        case .invalidResponse: "Transmission returned an unexpected response. Harbor requires Transmission 4.1 or newer."
        case .invalidRequest: "The selected torrent or file reference is invalid."
        case .server(let message): "Transmission: \(String(message.prefix(400)))"
        case .oversized: "Transmission's response exceeds the size limit."
        }
    }
}

public struct TransmissionSession: Decodable, Sendable {
    public let version: String
    public let downloadDir: String
}

public struct TransmissionSettings: Codable, Sendable, Equatable {
    public var speedLimitDown: Int
    public var speedLimitDownEnabled: Bool
    public var speedLimitUp: Int
    public var speedLimitUpEnabled: Bool
    public var downloadQueueEnabled: Bool
    public var downloadQueueSize: Int
    public var queueStalledEnabled: Bool
    public var queueStalledMinutes: Int
    public var seedRatioLimit: Double
    public var seedRatioLimited: Bool
    public var idleSeedingLimit: Int
    public var idleSeedingLimitEnabled: Bool
    public var seedQueueEnabled: Bool
    public var seedQueueSize: Int
    public var altSpeedEnabled: Bool
    public var altSpeedDown: Int
    public var altSpeedUp: Int
    public var altSpeedTimeEnabled: Bool
    public var altSpeedTimeBegin: Int
    public var altSpeedTimeEnd: Int
    public var altSpeedTimeDay: Int
    public var peerLimitGlobal: Int
    public var peerLimitPerTorrent: Int
    public var peerPort: Int
    public var peerPortRandomOnStart: Bool
    public var portForwardingEnabled: Bool
    public var dhtEnabled: Bool
    public var pexEnabled: Bool
    public var lpdEnabled: Bool
    public var encryption: String
    public var downloadDir: String
    public var incompleteDir: String
    public var incompleteDirEnabled: Bool
    public var renamePartialFiles: Bool
    public var startAddedTorrents: Bool

    public static let fields = ["speed_limit_down", "speed_limit_down_enabled", "speed_limit_up", "speed_limit_up_enabled", "download_queue_enabled", "download_queue_size", "queue_stalled_enabled", "queue_stalled_minutes", "seed_ratio_limit", "seed_ratio_limited", "idle_seeding_limit", "idle_seeding_limit_enabled", "seed_queue_enabled", "seed_queue_size", "alt_speed_enabled", "alt_speed_down", "alt_speed_up", "alt_speed_time_enabled", "alt_speed_time_begin", "alt_speed_time_end", "alt_speed_time_day", "peer_limit_global", "peer_limit_per_torrent", "peer_port", "peer_port_random_on_start", "port_forwarding_enabled", "dht_enabled", "pex_enabled", "lpd_enabled", "encryption", "download_dir", "incomplete_dir", "incomplete_dir_enabled", "rename_partial_files", "start_added_torrents"]

    public var validationError: String? {
        let speeds = [speedLimitDown, speedLimitUp, altSpeedDown, altSpeedUp]
        if !speeds.allSatisfy({ (0...1_000_000_000).contains($0) }) { return "Speed limits must be whole numbers from 0 to 1,000,000,000 kB/s." }
        if !(1...10_000).contains(downloadQueueSize) || !(1...10_000).contains(seedQueueSize) { return "Queue sizes must be between 1 and 10,000." }
        if !seedRatioLimit.isFinite || !(0...10_000).contains(seedRatioLimit) { return "Seed ratio must be a finite number from 0 to 10,000." }
        if !(1...525_600).contains(idleSeedingLimit) || !(1...525_600).contains(queueStalledMinutes) { return "Timeouts must be between 1 and 525,600 minutes." }
        if !(1...100_000).contains(peerLimitGlobal) || !(1...100_000).contains(peerLimitPerTorrent) { return "Peer limits must be between 1 and 100,000." }
        if !(1...65_535).contains(peerPort) { return "Peer port must be between 1 and 65,535." }
        if !(0...1439).contains(altSpeedTimeBegin) || !(0...1439).contains(altSpeedTimeEnd) || !(0...127).contains(altSpeedTimeDay) || altSpeedTimeEnabled && altSpeedTimeDay == 0 { return "Choose a valid schedule and at least one day." }
        if !["required", "preferred", "allowed"].contains(encryption) { return "Choose a supported encryption mode." }
        if ![downloadDir, incompleteDir].allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) { return "Download folders must be absolute paths." }
        return nil
    }

    public func rpcParameters() throws -> [String: RPCValue] {
        guard validationError == nil else { throw TransmissionError.invalidRequest }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try JSONDecoder().decode([String: RPCValue].self, from: encoder.encode(self))
    }
}

public enum SeedLimitMode: Int, Codable, Sendable, CaseIterable {
    case global = 0, custom = 1, unlimited = 2
}

public struct TorrentSeeding: Decodable, Sendable, Equatable {
    public var seedRatioMode: SeedLimitMode
    public var seedRatioLimit: Double
    public var seedIdleMode: SeedLimitMode
    public var seedIdleLimit: Int

    public var isValid: Bool {
        seedRatioLimit.isFinite && (0...10_000).contains(seedRatioLimit) && (1...65_535).contains(seedIdleLimit)
    }
}

public struct TorrentBandwidth: Decodable, Sendable, Equatable {
    public var downloadLimit: Int
    public var downloadLimited: Bool
    public var uploadLimit: Int
    public var uploadLimited: Bool
    public var honorsSessionLimits: Bool
    public var isValid: Bool {
        (0...1_000_000_000).contains(downloadLimit) && (0...1_000_000_000).contains(uploadLimit)
    }
}

public struct Transfer: Decodable, Identifiable, Sendable {
    public let hashString: String
    public var id: String { hashString.lowercased() }
    public let name: String
    public let status: Int
    public let percentDone: Double
    public let rateDownload: Int64
    public let rateUpload: Int64
    public let eta: Int
    public let totalSize: Int64
    public let downloadedEver: Int64
    public let uploadedEver: Int64
    public let uploadRatio: Double
    public let downloadDir: String
    public let error: Int
    public let errorString: String
    public let queuePosition: Int
    public let peersConnected: Int
    public let peersSendingToUs: Int
    public let peersGettingFromUs: Int
    public let metadataPercentComplete: Double
    public var activePeerCount: Int {
        let active = status == 4 ? peersSendingToUs : status == 6 ? peersGettingFromUs : 0
        return min(max(0, peersConnected), max(0, active))
    }
    public var peerActivityText: String { "\(activePeerCount)/\(max(0, peersConnected)) peers active" }
    public var peerActivityDescription: String {
        status == 6 ? "Peers receiving data from us / all connected peers" : "Peers sending data to us / all connected peers"
    }
    public var isPaused: Bool { status == 0 }
    public var isComplete: Bool { percentDone >= 1 }
    public var statusText: String {
        if error != 0 { return "Error" }
        if metadataPercentComplete < 1 { return isPaused ? "Paused · fetching metadata" : "Fetching metadata" }
        switch status {
        case 0: return "Paused"
        case 1: return "Queued for verification"
        case 2: return "Verifying"
        case 3: return "Queued"
        case 4: return "Downloading"
        case 5: return "Queued to seed"
        case 6: return "Seeding"
        default: return "Unknown"
        }
    }
    public var progress: Double { percentDone.isFinite ? min(1, max(0, percentDone)) : 0 }
    public var formattedSize: String { ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .binary) }
    public var formattedETA: String {
        guard eta >= 0 else { return "—" }
        if eta < 60 { return "\(eta)s" }
        if eta < 3600 { return "\(eta / 60)m" }
        if eta < 86400 { return "\(eta / 3600)h \((eta % 3600) / 60)m" }
        return "\(eta / 86400)d \((eta % 86400) / 3600)h"
    }
    public static func speed(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .decimal) + "/s"
    }
}

public struct TransferFile: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let size: Int64
    public let completed: Int64
    public let wanted: Bool
    public var progress: Double { size > 0 ? min(1, max(0, Double(completed) / Double(size))) : 0 }
}

public struct TransferAddition: Sendable {
    public let hash: String
    public let duplicate: Bool
}

/// Local-only client. Credentials are never sent to a configurable remote host.
public actor TransmissionClient {
    public static let endpoint = URL(string: "http://127.0.0.1:9091/transmission/rpc")!
    private let rpcEndpoint: URL
    private let authorization: String
    private let session: URLSession
    private let redirectGuard: NoRedirects
    private var sessionID: String?
    private var nextID = 0

    public init(username: String, password: String, session: URLSession? = nil, port: Int = 9091) {
        precondition((1...65535).contains(port))
        rpcEndpoint = URL(string: "http://127.0.0.1:\(port)/transmission/rpc")!
        self.authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        let guardDelegate = NoRedirects()
        self.redirectGuard = guardDelegate
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 6
            configuration.timeoutIntervalForResource = 10
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: guardDelegate, delegateQueue: nil)
        }
    }

    public func sessionInfo() async throws -> TransmissionSession {
        try await call("session_get", ["fields": .array([.string("version"), .string("download_dir")])])
    }

    public func settings() async throws -> TransmissionSettings {
        try await call("session_get", ["fields": .array(TransmissionSettings.fields.map(RPCValue.string))])
    }

    public func updateSettings(_ settings: TransmissionSettings, previous: TransmissionSettings? = nil) async throws {
        var parameters = try settings.rpcParameters()
        if let previous {
            let old = try previous.rpcParameters()
            parameters = parameters.filter { old[$0.key] != $0.value }
        }
        guard !parameters.isEmpty else { return }
        let _: Empty = try await call("session_set", parameters)
    }

    public func transfers() async throws -> [Transfer] {
        let fields = ["hash_string", "name", "status", "percent_done", "rate_download", "rate_upload", "eta",
            "total_size", "downloaded_ever", "uploaded_ever", "upload_ratio", "download_dir", "error",
            "error_string", "queue_position", "peers_connected", "peers_sending_to_us", "peers_getting_from_us", "metadata_percent_complete"]
        let response: TransferList = try await call("torrent_get", ["fields": .array(fields.map(RPCValue.string))])
        return response.torrents.sorted { $0.queuePosition < $1.queuePosition }
    }

    public func diagnostics(hash: String) async throws -> TransferDiagnostics {
        var parameters = try ids(hash)
        parameters["fields"] = .array(["peers_connected", "peers_sending_to_us", "peers_getting_from_us", "desired_available", "left_until_done", "is_stalled", "tracker_stats"].map(RPCValue.string))
        let response: DiagnosticsList = try await call("torrent_get", parameters)
        guard response.torrents.count == 1, let value = response.torrents.first else { throw TransmissionError.invalidRequest }
        return value
    }

    public func seeding(hash: String) async throws -> TorrentSeeding {
        var parameters = try ids(hash)
        parameters["fields"] = .array(["seed_ratio_mode", "seed_ratio_limit", "seed_idle_mode", "seed_idle_limit"].map(RPCValue.string))
        let response: SeedingList = try await call("torrent_get", parameters)
        guard response.torrents.count == 1, let value = response.torrents.first else { throw TransmissionError.invalidRequest }
        return value
    }

    public func setSeeding(hash: String, settings: TorrentSeeding) async throws {
        var parameters = try ids(hash)
        guard settings.isValid else { throw TransmissionError.invalidRequest }
        parameters["seed_ratio_mode"] = .int(settings.seedRatioMode.rawValue)
        parameters["seed_ratio_limit"] = .double(settings.seedRatioLimit)
        parameters["seed_idle_mode"] = .int(settings.seedIdleMode.rawValue)
        parameters["seed_idle_limit"] = .int(settings.seedIdleLimit)
        let _: Empty = try await call("torrent_set", parameters)
    }

    public func bandwidth(hash: String) async throws -> TorrentBandwidth {
        var parameters = try ids(hash)
        parameters["fields"] = .array(["download_limit", "download_limited", "upload_limit", "upload_limited", "honors_session_limits"].map(RPCValue.string))
        let response: BandwidthList = try await call("torrent_get", parameters)
        guard response.torrents.count == 1, let value = response.torrents.first else { throw TransmissionError.invalidRequest }
        return value
    }

    public func setBandwidth(hash: String, settings: TorrentBandwidth) async throws {
        var parameters = try ids(hash)
        guard settings.isValid else { throw TransmissionError.invalidRequest }
        parameters["download_limit"] = .int(settings.downloadLimit)
        parameters["download_limited"] = .bool(settings.downloadLimited)
        parameters["upload_limit"] = .int(settings.uploadLimit)
        parameters["upload_limited"] = .bool(settings.uploadLimited)
        parameters["honors_session_limits"] = .bool(settings.honorsSessionLimits)
        let _: Empty = try await call("torrent_set", parameters)
    }

    public func start(hash: String) async throws { let _: Empty = try await call("torrent_start", try ids(hash)) }
    public func pause(hash: String) async throws { let _: Empty = try await call("torrent_stop", try ids(hash)) }
    public func move(hash: String, up: Bool) async throws {
        let _: Empty = try await call(up ? "queue_move_up" : "queue_move_down", try ids(hash))
    }
    /// Removal deliberately never deletes the downloaded payload.
    public func remove(hash: String) async throws {
        var parameters = try ids(hash)
        parameters["delete_local_data"] = .bool(false)
        let _: Empty = try await call("torrent_remove", parameters)
    }
    public func files(hash: String) async throws -> [TransferFile] {
        var parameters = try ids(hash)
        parameters["fields"] = .array([.string("files"), .string("file_stats")])
        let response: FileList = try await call("torrent_get", parameters)
        guard let torrent = response.torrents.first else { return [] }
        return torrent.files.enumerated().map { index, file in
            TransferFile(id: index, name: file.name, size: file.length, completed: file.bytesCompleted,
                         wanted: index < torrent.fileStats.count ? torrent.fileStats[index].wanted : true)
        }
    }
    public func setFile(hash: String, index: Int, wanted: Bool) async throws {
        guard index >= 0 else { throw TransmissionError.invalidRequest }
        var parameters = try ids(hash)
        parameters[wanted ? "files_wanted" : "files_unwanted"] = .array([.int(index)])
        let _: Empty = try await call("torrent_set", parameters)
    }
    public func add(magnet: URL? = nil, torrent: Data? = nil, directory: String?, paused: Bool) async throws -> TransferAddition {
        var parameters: [String: RPCValue] = ["paused": .bool(paused)]
        if let magnet, SearchService.infoHashFromMagnet(magnet.absoluteString) != nil, torrent == nil {
            parameters["filename"] = .string(magnet.absoluteString)
        } else if let torrent, magnet == nil, torrent.count <= 4 * 1024 * 1024, TorrentValidator.isTorrent(torrent) {
            parameters["metainfo"] = .string(torrent.base64EncodedString())
        } else { throw TransmissionError.invalidRequest }
        if let directory, !directory.isEmpty { parameters["download_dir"] = .string(directory) }
        let response: AdditionResponse = try await call("torrent_add", parameters)
        guard let item = response.torrentAdded ?? response.torrentDuplicate,
              LinkSafety.validInfoHash(item.hashString) else { throw TransmissionError.invalidResponse }
        return TransferAddition(hash: item.hashString.lowercased(), duplicate: response.torrentDuplicate != nil)
    }

    private func ids(_ hash: String) throws -> [String: RPCValue] {
        guard LinkSafety.validInfoHash(hash) else { throw TransmissionError.invalidRequest }
        return ["ids": .array([.string(hash)])]
    }

    private func call<T: Decodable & Sendable>(_ method: String, _ parameters: [String: RPCValue]) async throws -> T {
        nextID += 1
        let id = nextID
        let body = try JSONEncoder().encode(Request(method: method, params: parameters, id: id))
        for attempt in 0..<2 {
            var request = URLRequest(url: rpcEndpoint)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "X-Transmission-Session-Id") }
            let data: Data
            let response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch is CancellationError { throw CancellationError() }
            catch { if Task.isCancelled { throw CancellationError() }; throw TransmissionError.unavailable }
            guard let response = response as? HTTPURLResponse else { throw TransmissionError.invalidResponse }
            if response.statusCode == 401 || response.statusCode == 403 { throw TransmissionError.authentication }
            if response.statusCode == 409, attempt == 0,
               let token = response.value(forHTTPHeaderField: "X-Transmission-Session-Id"), token.count <= 1024 {
                sessionID = token; continue
            }
            guard response.statusCode == 200 else { throw TransmissionError.invalidResponse }
            guard data.count <= 16 * 1024 * 1024 else { throw TransmissionError.oversized }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let envelope = try? decoder.decode(Envelope<T>.self, from: data), envelope.id == id else {
                throw TransmissionError.invalidResponse
            }
            if let error = envelope.error { throw TransmissionError.server(error.data?.errorString ?? error.message) }
            guard let result = envelope.result else { throw TransmissionError.invalidResponse }
            return result
        }
        throw TransmissionError.invalidResponse
    }

    private struct Request: Encodable { let jsonrpc = "2.0"; let method: String; let params: [String: RPCValue]; let id: Int }
    private struct Envelope<T: Decodable>: Decodable { let id: Int?; let result: T?; let error: ServerError? }
    private struct ServerError: Decodable { let message: String; let data: ErrorData? }
    private struct ErrorData: Decodable { let errorString: String? }
    private struct Empty: Decodable, Sendable {}
    private struct DiagnosticsList: Decodable, Sendable { let torrents: [TransferDiagnostics] }
    private struct BandwidthList: Decodable, Sendable { let torrents: [TorrentBandwidth] }
    private struct SeedingList: Decodable, Sendable { let torrents: [TorrentSeeding] }
    private struct TransferList: Decodable, Sendable { let torrents: [Transfer] }
    private struct FileList: Decodable, Sendable { let torrents: [Files] }
    private struct Files: Decodable, Sendable { let files: [File]; let fileStats: [FileStat] }
    private struct File: Decodable, Sendable { let name: String; let length: Int64; let bytesCompleted: Int64 }
    private struct FileStat: Decodable, Sendable { let wanted: Bool }
    private struct AdditionResponse: Decodable, Sendable { let torrentAdded: Added?; let torrentDuplicate: Added? }
    private struct Added: Decodable, Sendable { let hashString: String }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
