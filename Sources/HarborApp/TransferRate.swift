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

enum MenuBarDisplay: String, CaseIterable {
    case iconOnly, arrows, speeds
    var title: String {
        switch self {
        case .iconOnly: "Icon only"
        case .arrows: "Activity arrows"
        case .speeds: "Transfer speeds"
        }
    }
}

extension Transfer {
    var progressColor: Color {
        if error != 0 { return .red }
        if status == 6 { return .green }
        if isPaused || isComplete { return .gray }
        return .blue
    }
}

struct HarborStatusLabel: View {
    @Bindable var model: DownloadsModel
    @AppStorage("menuBarDisplay") private var display = MenuBarDisplay.arrows.rawValue
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
    private func compactSpeed(_ bytes: Int64) -> String {
        let speed = Double(max(0, bytes))
        if speed >= 1_000_000_000 { return String(format: "%.1f GB/s", speed / 1_000_000_000) }
        if speed >= 1_000_000 { return String(format: "%.1f MB/s", speed / 1_000_000) }
        if speed >= 1000 { return String(format: "%.0f kB/s", speed / 1000) }
        return "\(Int(speed)) B/s"
    }
    private var speedText: String {
        model.connected ? "↓ \(compactSpeed(model.downloadSpeed))  ↑ \(compactSpeed(model.uploadSpeed))" : "↓ —  ↑ —"
    }
    private var icon: NSImage {
        // A single native image keeps the boat, indicator and optional text together.
        let mode = MenuBarDisplay(rawValue: display) ?? .arrows
        let text = NSAttributedString(string: speedText, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.black])
        let width: CGFloat = mode == .iconOnly ? 18 : mode == .arrows ? 36 : 24 + ceil(text.size().width)
        let image = NSImage(size: NSSize(width: width, height: 18))
        image.lockFocus()
        let boat = NSImage(systemSymbolName: "sailboat.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        boat?.draw(in: NSRect(x: 0, y: 1, width: 18, height: 16))
        if mode == .arrows {
            let indicator = NSImage(systemSymbolName: status.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            indicator?.draw(in: NSRect(x: 21, y: 3, width: 13, height: 12))
        } else if mode == .speeds {
            text.draw(at: NSPoint(x: 24, y: floor((18 - text.size().height) / 2)))
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
    var body: some View {
        Image(nsImage: icon)
            .accessibilityLabel("Harbor · \(status.title) · \(speedText)")
            .help("Harbor · \(status.title) · \(speedText)")
    }
}
