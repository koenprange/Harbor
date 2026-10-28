import SwiftUI
import AppKit
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
        if model.downloadSpeed > 0 && model.uploadSpeed > 0 { return ("arrow.up.arrow.down", "Downloading and uploading") }
        if model.downloadSpeed > 0 { return ("arrow.down", "Downloading") }
        if model.uploadSpeed > 0 { return ("arrow.up", "Uploading") }
        if model.transfers.contains(where: { $0.error != 0 }) { return ("exclamationmark.triangle.fill", "Transfer needs attention") }
        if model.count(for: "active") > 0 { return ("arrow.down.circle", "Waiting for download peers") }
        if model.count(for: "seeding") > 0 { return ("arrow.up.circle", "Ready to seed") }
        if model.count(for: "queued") > 0 { return ("clock", "Queued") }
        if !model.transfers.isEmpty && model.transfers.allSatisfy(\.isPaused) { return ("pause.circle", "Paused") }
        return ("checkmark.circle", "Idle")
    }
    private var icon: NSImage {
        // A single image keeps both symbols visible in the native status item.
        let image = NSImage(size: NSSize(width: 36, height: 18))
        image.lockFocus()
        let boat = NSImage(systemSymbolName: "sailboat.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        boat?.draw(in: NSRect(x: 0, y: 1, width: 18, height: 16))
        let indicator = NSImage(systemSymbolName: status.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        indicator?.draw(in: NSRect(x: 21, y: 3, width: 13, height: 12))
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
    var body: some View {
        Image(nsImage: icon)
            .accessibilityLabel("Harbor · \(status.title)")
            .help("Harbor · \(status.title)")
    }
}
