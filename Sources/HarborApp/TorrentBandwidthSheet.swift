import SwiftUI
import HarborCore

struct TorrentBandwidthSheet: View {
    let transfer: Transfer
    @Bindable var model: DownloadsModel
    @Environment(\.dismiss) private var dismiss
    @State private var value: TorrentBandwidth?
    @State private var down = ""
    @State private var up = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    private var draft: TorrentBandwidth? {
        guard var value, let down = Int(down), let up = Int(up) else { return nil }
        value.downloadLimit = down; value.uploadLimit = up
        return value.isValid ? value : nil
    }
    private var followsGeneral: Bool {
        value?.honorsSessionLimits == true && value?.downloadLimited == false && value?.uploadLimited == false
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Torrent Speed Limits", systemImage: "speedometer").font(.title2.weight(.semibold))
            Text(transfer.name).font(.callout).lineLimit(3).textSelection(.enabled)
            if loading { ProgressView("Reading this torrent’s settings…") }
            else if value != nil {
                Form {
                    Toggle("Respect general bandwidth limits", isOn: flag(\.honorsSessionLimits))
                    Toggle("Limit download speed for this torrent", isOn: flag(\.downloadLimited))
                    TextField("Download limit (kB/s)", text: $down).disabled(value?.downloadLimited != true)
                    Toggle("Limit upload speed for this torrent", isOn: flag(\.uploadLimited))
                    TextField("Upload limit (kB/s)", text: $up).disabled(value?.uploadLimited != true)
                }.disabled(saving)
                Button("Follow General Limits") {
                    value?.honorsSessionLimits = true
                    value?.downloadLimited = false; value?.uploadLimited = false
                }.disabled(saving || followsGeneral)
                Text(followsGeneral ? "Following the general upload and download limits, including Turtle mode." : value?.honorsSessionLimits == true ? "General limits still apply. A custom limit can slow this torrent further, but cannot exceed the general ceiling." : "This torrent ignores general and Turtle limits in both directions. A direction without its own limit is unlimited.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("1,000 kB/s = 1 MB/s. An enabled limit of 0 stops traffic in that direction. Only this torrent changes; saving does not resume it.")
                    .font(.caption).foregroundStyle(.secondary)
                if draft == nil { Text("Enter whole-number speeds between 0 and 1,000,000,000 kB/s.").font(.caption).foregroundStyle(.red) }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Reload") { Task { await load() } }.disabled(loading || saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Save") {
                    guard let draft else { return }
                    saving = true; error = nil
                    Task {
                        defer { saving = false }
                        do {
                            let actual = try await model.saveTorrentBandwidth(hash: transfer.id, settings: draft)
                            populate(actual)
                            guard actual == draft else { error = "Transmission returned different values. Review them before saving again."; return }
                            dismiss()
                        } catch { self.error = "Could not confirm saved limits: \(error.localizedDescription) Use Reload before retrying." }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(loading || saving || draft == nil)
            }
        }.padding(24).frame(width: 520).interactiveDismissDisabled(saving).task { await load() }
    }
    private func flag(_ key: WritableKeyPath<TorrentBandwidth, Bool>) -> Binding<Bool> {
        Binding(get: { value?[keyPath: key] ?? false }, set: { value?[keyPath: key] = $0 })
    }
    private func populate(_ settings: TorrentBandwidth) {
        value = settings; down = String(settings.downloadLimit); up = String(settings.uploadLimit)
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do { populate(try await model.torrentBandwidth(hash: transfer.id)) }
        catch { value = nil; self.error = error.localizedDescription }
    }
}
