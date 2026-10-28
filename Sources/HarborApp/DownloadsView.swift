import SwiftUI
import HarborCore
import AppKit

struct DownloadsView: View {
    @Bindable var model: DownloadsModel
    @State private var removal: Transfer?
    @State private var seedingTransfer: Transfer?
    @State private var bandwidthTransfer: Transfer?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.filterTitle).font(.title2.weight(.semibold))
                    Text("Powered by Transmission daemon on this Mac").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Filter downloads", text: $model.filterText).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                Menu {
                    Button("Download Settings…") { model.showSettings = true }
                    Button("Connection Settings…") { model.showConnection = true }
                    Button("Start Download Engine") {
                        Task {
                            do { try await DaemonController.shared.start(); await model.refresh() }
                            catch { model.error = error.localizedDescription }
                        }
                    }

                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }.padding(20)
            HStack {
                Spacer()
                if let transfer = model.selected {
                    Button { model.toggle(transfer) } label: {
                        Label(transfer.isPaused ? "Resume" : "Pause", systemImage: transfer.isPaused ? "play.fill" : "pause.fill")
                    }.disabled(model.busy || !model.connected)
                    Button { model.reveal(transfer) } label: { Image(systemName: "folder") }.help("Show in Finder")
                    Button { removal = transfer } label: { Image(systemName: "minus.circle") }.help("Remove transfer, keep files")
                        .disabled(model.busy || !model.connected)
                }
            }.padding(.horizontal, 20).padding(.bottom, 15)
            if !model.connected {
                HStack {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(model.status).font(.callout)
                    Spacer()
                    Button("Connection…") { model.showConnection = true }
                }.padding(14).background(Color.orange.opacity(0.08))
            }
            Divider()
            HSplitView {
                if model.visible.isEmpty {
                    ContentUnavailableView("No downloads", systemImage: "arrow.down.circle", description: Text("Choose a search result to add a download."))
                        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(model.visible, selection: $model.selection) {
                        TableColumn("Download") { transfer in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(transfer.name).lineLimit(1).help(transfer.name)
                                ProgressView(value: transfer.progress).tint(transfer.isComplete ? .green : .accentColor)
                                HStack {
                                    Text(transfer.statusText)
                                    Spacer()
                                    Text(transfer.progress, format: .percent.precision(.fractionLength(1)))
                                }.font(.caption).foregroundStyle(transfer.error == 0 ? Color.secondary : Color.red)
                            }.padding(.vertical, 9)
                        }.width(min: 190, ideal: 350)
                        TableColumn("Down") { TransferRate(bytes: $0.rateDownload, direction: .download, showArrow: false) }.width(85)
                        TableColumn("Up") { TransferRate(bytes: $0.rateUpload, direction: .upload, showArrow: false) }.width(85)
                        TableColumn("ETA") { Text($0.formattedETA).monospacedDigit().foregroundStyle(.secondary) }.width(65)
                    }
                    .frame(minWidth: 440)
                    .contextMenu(forSelectionType: String.self) { ids in
                        if let transfer = model.transfers.first(where: { $0.id == ids.first }) {
                            Button(transfer.isPaused ? "Resume" : "Pause") { model.toggle(transfer) }.disabled(model.busy || !model.connected)
                            Button("Move Up") { model.move(transfer, up: true) }.disabled(model.busy || !model.connected)
                            Button("Move Down") { model.move(transfer, up: false) }.disabled(model.busy || !model.connected)
                            Button("Speed Limits…") { bandwidthTransfer = transfer }.disabled(model.busy || !model.connected)
                            Button("Seeding Settings…") { seedingTransfer = transfer }.disabled(model.busy || !model.connected)
                            Button("Show in Finder") { model.reveal(transfer) }
                            Divider()
                            Button("Remove Transfer…") { removal = transfer }.disabled(model.busy || !model.connected)
                        }
                    }
                }
                if let transfer = model.selected {
                    inspector(transfer).frame(minWidth: 260, idealWidth: 290, maxWidth: 350, maxHeight: .infinity)
                }
            }
            Divider()
            HStack(spacing: 15) {
                Circle().fill(model.connected ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(model.connected ? "\(model.transfers.count) transfers · local connection" : "Disconnected · showing last known state")
                Spacer()
                TransferRate(bytes: model.downloadSpeed, direction: .download)
                TransferRate(bytes: model.uploadSpeed, direction: .upload)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 35)
        }
        .sheet(item: $bandwidthTransfer) { transfer in
            TorrentBandwidthSheet(transfer: transfer, model: model)
        }
        .sheet(item: $seedingTransfer) { transfer in
            TorrentSeedingSheet(transfer: transfer, model: model)
        }
        .task(id: model.selection) { await model.loadFiles() }
        .alert("Remove this transfer?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { transfer in
            Button("Cancel", role: .cancel) { removal = nil }
            Button("Remove Transfer", role: .destructive) { model.remove(transfer); removal = nil }
        } message: { _ in Text("Downloaded files will be kept. Only the transfer is removed from Transmission.") }
        .alert("Transmission", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private func inspector(_ transfer: Transfer) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                Text(transfer.name).font(.headline).textSelection(.enabled)
                LabeledContent("Size", value: transfer.formattedSize)
                LabeledContent("Peers", value: "\(transfer.peersConnected)")
                LabeledContent("Ratio", value: transfer.uploadRatio >= 0 ? String(format: "%.2f", transfer.uploadRatio) : "—")
                Button("Speed Limits…", systemImage: "speedometer") { bandwidthTransfer = transfer }
                    .disabled(model.busy || !model.connected)
                Button("Seeding Settings…", systemImage: "slider.horizontal.3") { seedingTransfer = transfer }
                    .disabled(model.busy || !model.connected)
                if transfer.error != 0 { Text(transfer.errorString).font(.callout).foregroundStyle(.red) }
                HStack {
                    Button { model.move(transfer, up: true) } label: { Label("Up", systemImage: "arrow.up") }
                    Button { model.move(transfer, up: false) } label: { Label("Down", systemImage: "arrow.down") }
                }.disabled(model.busy || !model.connected)
                Text(transfer.downloadDir).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Divider()
                Text("FILES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if model.loadingFiles { ProgressView().controlSize(.small) }
                else if model.files.isEmpty {
                    Text(transfer.metadataPercentComplete < 1 ? "Waiting for torrent metadata…" : "No file list available.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Refresh Files") { Task { await model.loadFiles() } }
                } else {
                    ForEach(model.files) { file in
                        Toggle(isOn: Binding(get: { file.wanted }, set: { model.setWanted(file, hash: transfer.id, wanted: $0) })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.name).font(.caption).lineLimit(2).help(file.name)
                                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .binary))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox).disabled(model.busy || !model.connected)
                    }
                }
            }.font(.callout).padding(20)
        }.background(.background.opacity(0.6))
    }
}
