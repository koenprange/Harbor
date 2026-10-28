import SwiftUI
import AppKit
import HarborCore

struct MenuBarView: View {
    @Bindable var model: SearchModel
    let openMain: () -> Void
    @State private var query = ""
    @State private var displayMenuHovered = false
    @AppStorage("menuBarDisplay") private var display = MenuBarDisplay.arrows.rawValue

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
            if !model.downloads.connected {
                Text("Disconnected · last known transfer status")
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.downloads.transfers.isEmpty {
                Text(model.downloads.connected ? "No downloads yet" : "Transfers unavailable")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.downloads.transfers) { transfer in
                            transferRow(transfer)
                            if transfer.id != model.downloads.transfers.last?.id { Divider().padding(.vertical, 10) }
                        }
                    }.padding(.vertical, 2)
                }
                .frame(height: min(CGFloat(model.downloads.transfers.count) * 112, 340))
            }
            Divider()
            Button("Open Harbor") { openMain() }
            Menu {
                ForEach(MenuBarDisplay.allCases, id: \.rawValue) { mode in
                    Toggle(mode.title, isOn: Binding(
                        get: { display == mode.rawValue },
                        set: { selected in if selected { display = mode.rawValue } }
                    ))
                }
            } label: {
                HStack {
                    Text("Menu bar display")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .contentShape(Rectangle())
                .background(displayMenuHovered ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .onHover { displayMenuHovered = $0 }
            Divider()
            Button("Quit Harbor & Stop Transfers") { NSApplication.shared.terminate(nil) }
                .help("Stops Transmission before quitting Harbor")
        }
        .buttonStyle(.plain)
        .padding(16)
        .frame(width: 360)
        .onAppear { model.downloads.startPolling() }
    }

    private func transferRow(_ transfer: Transfer) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                model.downloads.filter = ""
                model.downloads.filterText = ""
                model.scope = "downloads"
                model.downloads.selection = transfer.id
                openMain()
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(transfer.name).font(.callout.weight(.medium)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ProgressView(value: transfer.progress)
                        .tint(transfer.progressColor)
                        .accessibilityLabel("Download progress")
                    HStack {
                        Text(transfer.statusText).lineLimit(1)
                        Spacer()
                        Text(transfer.progress, format: .percent.precision(.fractionLength(1))).monospacedDigit()
                    }.font(.caption).foregroundStyle(transfer.error != 0 ? Color.red : Color.secondary)
                }.contentShape(Rectangle())
            }.help("Open \(transfer.name) in Harbor")
            HStack(spacing: 12) {
                TransferRate(bytes: transfer.rateDownload, direction: .download)
                TransferRate(bytes: transfer.rateUpload, direction: .upload)
                Spacer(minLength: 0)
                Button { model.downloads.toggle(transfer) } label: {
                    Image(systemName: transfer.isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 24, height: 20).contentShape(Rectangle())
                }
                .help(transfer.isPaused ? "Resume transfer" : "Pause transfer")
                .accessibilityLabel(transfer.isPaused ? "Resume transfer" : "Pause transfer")
                .disabled(model.downloads.busy || !model.downloads.connected)
            }.font(.caption)
        }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        model.query = term
        model.search()
        openMain()
    }
}
