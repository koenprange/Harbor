import SwiftUI
import AppKit
import HarborCore

struct MenuBarView: View {
    @Bindable var model: SearchModel
    let openMain: () -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Harbor", systemImage: "sailboat.fill").font(.headline)
                Spacer()
                Circle().fill(model.downloads.connected ? Color.green : Color.orange).frame(width: 7, height: 7)
            }
            HStack {
                TextField("Search torrents…", text: $query).onSubmit(search)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Quick search")
                Button(action: search) { Image(systemName: "magnifyingglass") }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 18) {
                TransferRate(bytes: model.downloads.downloadSpeed, direction: .download)
                TransferRate(bytes: model.downloads.uploadSpeed, direction: .upload)
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            HStack {
                Text("\(model.downloads.count(for: "active")) downloading · \(model.downloads.count(for: "seeding")) seeding")
                Spacer()
            }.font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("Open Harbor") { openMain() }
            Divider()
            Button("Quit Harbor & Stop Transfers") { NSApplication.shared.terminate(nil) }
                .help("Stops Transmission before quitting Harbor")
        }
        .buttonStyle(.plain)
        .padding(16)
        .frame(width: 320)
        .onAppear { model.downloads.startPolling() }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        model.query = term
        model.search()
        openMain()
    }
}
