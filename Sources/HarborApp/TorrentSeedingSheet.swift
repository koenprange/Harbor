import SwiftUI
import HarborCore

struct TorrentSeedingSheet: View {
    let transfer: Transfer
    @Bindable var model: DownloadsModel
    @Environment(\.dismiss) private var dismiss
    @State private var value: TorrentSeeding?
    @State private var ratio = ""
    @State private var idle = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    private var draft: TorrentSeeding? {
        guard var value, let ratio = Double(ratio.replacingOccurrences(of: ",", with: ".")), let idle = Int(idle) else { return nil }
        value.seedRatioLimit = ratio
        value.seedIdleLimit = idle
        // Unlimited seeding must also ignore the inactivity stop rule.
        if value.seedRatioMode == .unlimited { value.seedIdleMode = .unlimited }
        return value.isValid ? value : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Torrent Seeding", systemImage: "arrow.up.circle").font(.title2.weight(.semibold))
            Text(transfer.name).font(.callout).lineLimit(3).textSelection(.enabled)
            if loading { ProgressView("Reading this torrent’s settings…") }
            else if value != nil {
                Form {
                    Picker("Seed ratio", selection: mode(\.seedRatioMode)) {
                        Text("Follow general setting").tag(SeedLimitMode.global)
                        Text("Use a custom ratio").tag(SeedLimitMode.custom)
                        Text("Seed indefinitely").tag(SeedLimitMode.unlimited)
                    }
                    if value?.seedRatioMode == .custom {
                        TextField("Target ratio", text: $ratio)
                        Text("1.0 uploads as much as was downloaded. Decimal commas are accepted.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if value?.seedRatioMode == .unlimited {
                        Text("Ignores both the general ratio and inactivity stop limits. You can still pause this torrent or quit Harbor to stop it.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Stop after inactivity", selection: mode(\.seedIdleMode)) {
                            Text("Follow general setting").tag(SeedLimitMode.global)
                            Text("Use a custom timeout").tag(SeedLimitMode.custom)
                            Text("Never stop for inactivity").tag(SeedLimitMode.unlimited)
                        }
                        if value?.seedIdleMode == .custom { TextField("Inactivity (minutes)", text: $idle) }
                    }
                }.disabled(saving)
                Text("Only this torrent changes. These choices are saved across restarts. Saving does not resume a paused torrent.")
                    .font(.caption).foregroundStyle(.secondary)
                if draft == nil { Text("Enter a ratio from 0 to 10,000 and an inactivity timeout from 1 to 65,535 minutes.").font(.caption).foregroundStyle(.red) }
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
                            let actual = try await model.saveTorrentSeeding(hash: transfer.id, settings: draft)
                            populate(actual)
                            guard actual == draft else { error = "Transmission returned different values. Review them before saving again."; return }
                            dismiss()
                        } catch { self.error = "Could not confirm these settings: \(error.localizedDescription) Use Reload before retrying." }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(loading || saving || draft == nil)
            }
        }.padding(24).frame(width: 510).interactiveDismissDisabled(saving)
            .task { await load() }

    }
    private func mode(_ key: WritableKeyPath<TorrentSeeding, SeedLimitMode>) -> Binding<SeedLimitMode> {
        Binding(get: { value?[keyPath: key] ?? .global }, set: { new in
            let old = value?[keyPath: key]
            value?[keyPath: key] = new
            if key == \TorrentSeeding.seedRatioMode {
                if new == .unlimited { value?.seedIdleMode = .unlimited }
                else if old == .unlimited { value?.seedIdleMode = .global }
            }
        })
    }
    private func populate(_ settings: TorrentSeeding) {
        value = settings; ratio = String(settings.seedRatioLimit); idle = String(settings.seedIdleLimit)
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do { populate(try await model.torrentSeeding(hash: transfer.id)) }
        catch { value = nil; self.error = error.localizedDescription }
    }
}
