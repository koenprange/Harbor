import SwiftUI
import HarborCore

struct TransferRate: View {
    enum Direction { case download, upload }
    let bytes: Int64
    let direction: Direction
    var showArrow = true
    var body: some View {
        HStack(spacing: 4) {
            if showArrow { Image(systemName: direction == .download ? "arrow.down" : "arrow.up") }
            Text(Transfer.speed(bytes))
        }
        .monospacedDigit()
        .foregroundStyle(bytes > 0 ? (direction == .download ? Color.blue : Color.orange) : Color.secondary)
        .accessibilityLabel("\(direction == .download ? "Download" : "Upload"): \(Transfer.speed(bytes))")
    }
}

struct HarborStatusLabel: View {
    @Bindable var model: DownloadsModel
    private var status: (symbol: String, title: String) {
        if !model.connected { return ("exclamationmark.circle.fill", "Disconnected") }
        if model.transfers.contains(where: { $0.error != 0 }) { return ("exclamationmark.triangle.fill", "Transfer needs attention") }
        if model.downloadSpeed > 0 && model.uploadSpeed > 0 { return ("arrow.up.arrow.down.circle.fill", "Downloading and uploading") }
        if model.downloadSpeed > 0 { return ("arrow.down.circle.fill", "Downloading") }
        if model.uploadSpeed > 0 { return ("arrow.up.circle.fill", "Uploading") }
        if model.count(for: "active") > 0 { return ("arrow.down.circle", "Waiting for download peers") }
        if model.count(for: "seeding") > 0 { return ("arrow.up.circle", "Ready to seed") }
        if model.count(for: "queued") > 0 { return ("clock", "Queued") }
        if !model.transfers.isEmpty && model.transfers.allSatisfy(\.isPaused) { return ("pause.circle", "Paused") }
        return ("checkmark.circle", "Idle")
    }
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sailboat.fill")
            Image(systemName: status.symbol).font(.system(size: 10, weight: .semibold))
        }.accessibilityLabel("Harbor · \(status.title)").help("Harbor · \(status.title)")
    }
}
