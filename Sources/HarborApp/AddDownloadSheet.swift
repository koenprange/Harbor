import SwiftUI
import HarborCore

struct AddDownloadSheet: View {
    let result: TorrentResult
    @Bindable var model: SearchModel
    @Environment(\.dismiss) private var dismiss
    @State private var directory = ""
    @State private var start = true
    @State private var loadingDefaults = true
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add to Downloads").font(.title2.weight(.semibold))
            Text(result.title).font(.headline).textSelection(.enabled)
            LabeledContent("Size", value: result.formattedSize)
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Download folder").font(.caption).foregroundStyle(.secondary)
                    Text(directory.isEmpty ? "Transmission's default folder" : directory).lineLimit(2).truncationMode(.middle)
                }
                Spacer()
                Button("Choose…") {
                    if let folder = model.downloads.chooseDirectory(current: directory) { directory = folder }
                }.disabled(model.isOpening || loadingDefaults)
            }
            Toggle("Start downloading", isOn: $start).disabled(model.isOpening || loadingDefaults)
            Text("You can select individual files in Downloads once torrent metadata is available.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isOpening || loadingDefaults)
                Spacer()
                if model.isOpening { ProgressView().controlSize(.small) }
                Button(model.isOpening ? "Adding…" : "Add Download") {
                    error = nil
                    Task {
                        do { try await model.addDownload(result, directory: directory, start: start); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.isOpening || loadingDefaults)
            }
        }.padding(26).frame(width: 480).interactiveDismissDisabled(model.isOpening)
            .task {
                defer { loadingDefaults = false }
                await model.downloads.refresh()
                directory = model.downloads.defaultDirectory
                do { start = try await model.downloads.engineSettings().startAddedTorrents }
                catch { self.error = "Could not read default start behavior. Check Start downloading before adding." }
            }
    }
}
