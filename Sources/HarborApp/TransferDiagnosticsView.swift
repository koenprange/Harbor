import SwiftUI
import HarborCore

struct TransferDiagnosticsView: View {
    let transfer: Transfer
    @Bindable var model: DownloadsModel
    @State private var details: TransferDiagnostics?
    @State private var error: String?
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PEERS & TRACKERS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let details {
                LabeledContent("Connected peers", value: "\(details.peersConnected)")
                LabeledContent("Sending to us", value: "\(details.peersSendingToUs)")
                LabeledContent("Receiving from us", value: "\(details.peersGettingFromUs)")
                LabeledContent("Seeders · tracker max", value: count(details.reportedSeeders))
                LabeledContent("Leechers · tracker max", value: count(details.reportedLeechers))
                Text("Tracker counts are estimates, not live connections. The highest reported count is shown; unknown is —.")
                    .font(.caption).foregroundStyle(.secondary)
                if let explanation = explanation(details) {
                    Text(explanation).font(.caption).foregroundStyle(.secondary)
                }
                if details.isStalled && transfer.status == 4 {
                    Label("Transmission considers this download stalled", systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                }
                if details.leftUntilDone > 0 && transfer.metadataPercentComplete >= 1 {
                    LabeledContent("Remaining data available", value: ByteCountFormatter.string(fromByteCount: details.desiredAvailable, countStyle: .binary))
                        .font(.caption)
                        .help("Remaining wanted bytes currently advertised by connected peers; not the full swarm’s availability")
                }
                DisclosureGroup("Trackers (\(details.trackerStats.count))", isExpanded: $expanded) {
                    if details.trackerStats.isEmpty {
                        Text("No trackers. Public torrents can also discover peers through DHT and PEX.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(details.trackerStats) { tracker in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .top) {
                                Text(tracker.displayName).font(.caption.weight(.semibold)).lineLimit(2)
                                Spacer(minLength: 4)
                                if tracker.isBackup { Text("Backup").font(.caption2).foregroundStyle(.secondary) }
                            }
                            Text(tracker.announceStatus).font(.caption)
                                .foregroundStyle(tracker.announceFailed ? Color.orange : .secondary)
                            if tracker.hasAnnounced && !tracker.lastAnnounceResult.isEmpty {
                                Text(tracker.lastAnnounceResult).font(.caption).textSelection(.enabled)
                            }
                            Text("Seeders \(count(tracker.knownSeeders)) · Leechers \(count(tracker.knownLeechers))")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            if tracker.lastAnnounceTime > 0 {
                                HStack(spacing: 4) {
                                    Text("Last announce")
                                    Text(Date(timeIntervalSince1970: Double(tracker.lastAnnounceTime)), style: .relative)
                                }.font(.caption2).foregroundStyle(.secondary)
                            }
                            if tracker.announceState == 1 && tracker.nextAnnounceTime > 0 {
                                HStack(spacing: 4) {
                                    Text("Next announce")
                                    Text(Date(timeIntervalSince1970: Double(tracker.nextAnnounceTime)), style: .relative)
                                }.font(.caption2).foregroundStyle(.secondary)
                            }
                            if tracker.hasScraped {
                                Text(tracker.lastScrapeSucceeded ? "Swarm count request succeeded" : "Swarm count request failed: \(tracker.lastScrapeResult)")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if tracker.lastScrapeTime > 0 {
                                    HStack(spacing: 4) {
                                        Text("Last count update")
                                        Text(Date(timeIntervalSince1970: Double(tracker.lastScrapeTime)), style: .relative)
                                    }.font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                        Divider()
                    }
                }
            } else if error == nil {
                ProgressView("Reading peer and tracker status…").controlSize(.small)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if !model.connected && details != nil {
                Text("Disconnected · showing last known details").font(.caption).foregroundStyle(.orange)
            }
        }
        .task(id: transfer.id) {
            while !Task.isCancelled {
                do {
                    let value = try await model.diagnostics(hash: transfer.id)
                    guard !Task.isCancelled else { return }
                    details = value; error = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = "Could not update diagnostics: \(error.localizedDescription)"
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    private func count(_ number: Int?) -> String { number.map(String.init) ?? "—" }
    private func explanation(_ details: TransferDiagnostics) -> String? {
        if transfer.isPaused { return "This transfer is paused; it is not trying to download." }
        if transfer.status == 3 { return "Waiting for a free slot in the download queue." }
        guard transfer.status == 4 else { return nil }
        if transfer.metadataPercentComplete < 1 { return "Waiting for torrent metadata from peers." }
        if details.peersConnected == 0 { return "No peers are connected. This does not prove that the entire swarm is offline." }
        if details.peersSendingToUs == 0 { return "Peers are connected, but none are currently sending data to us." }
        if details.desiredAvailable < details.leftUntilDone { return "Connected peers do not currently advertise all remaining data." }
        return nil
    }
}
