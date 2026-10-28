import Foundation

public struct TransferDiagnostics: Decodable, Sendable {
    public let peersConnected: Int
    public let peersSendingToUs: Int
    public let peersGettingFromUs: Int
    public let desiredAvailable: Int64
    public let leftUntilDone: Int64
    public let isStalled: Bool
    public let trackerStats: [TrackerStatus]

    // Trackers can describe the same swarm: never sum their counts.
    public var reportedSeeders: Int? { trackerStats.compactMap(\.knownSeeders).max() }
    public var reportedLeechers: Int? { trackerStats.compactMap(\.knownLeechers).max() }
}

public struct TrackerStatus: Decodable, Identifiable, Sendable {
    public let id: Int
    public let announce: String
    public let announceState: Int
    public let hasAnnounced: Bool
    public let lastAnnounceSucceeded: Bool
    public let lastAnnounceTimedOut: Bool
    public let lastAnnounceResult: String
    public let lastAnnounceTime: Int64
    public let nextAnnounceTime: Int64
    public let seederCount: Int
    public let leecherCount: Int
    public let isBackup: Bool
    public let hasScraped: Bool
    public let lastScrapeSucceeded: Bool
    public let lastScrapeResult: String
    public let lastScrapeTime: Int64

    public var displayName: String { URL(string: announce)?.host ?? "Tracker \(id)" }
    public var knownSeeders: Int? { seederCount >= 0 ? seederCount : nil }
    public var knownLeechers: Int? { leecherCount >= 0 ? leecherCount : nil }
    public var announceFailed: Bool { hasAnnounced && (!lastAnnounceSucceeded || lastAnnounceTimedOut) }
    public var announceStatus: String {
        if announceState == 3 { return "Announcing…" }
        if announceState == 2 { return "Queued to announce" }
        if hasAnnounced {
            if lastAnnounceTimedOut { return "Timed out" }
            if !lastAnnounceSucceeded { return "Announce failed" }
            return "Announce succeeded"
        }
        if isBackup { return "Backup · not contacted yet" }
        return announceState == 1 ? "Waiting to announce" : "Not contacted yet"
    }
}
