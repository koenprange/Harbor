import SwiftUI
import AppKit
import HarborCore

struct EngineSettingsSheet: View {
    @Bindable var model: DownloadsModel
    @Environment(\.dismiss) private var dismiss
    @State private var original: TransmissionSettings?
    @State private var settings: TransmissionSettings?
    @State private var numbers: [String: String] = [:]
    @State private var ratio = ""
    @State private var tab = "Seeding"
    @State private var saving = false
    @State private var loading = true
    @State private var error: String?

    private static let integers: [(String, WritableKeyPath<TransmissionSettings, Int>)] = [
        ("down", \.speedLimitDown), ("up", \.speedLimitUp), ("queue", \.downloadQueueSize),
        ("stalled", \.queueStalledMinutes), ("idle", \.idleSeedingLimit), ("seeds", \.seedQueueSize),
        ("altDown", \.altSpeedDown), ("altUp", \.altSpeedUp), ("peers", \.peerLimitGlobal),
        ("torrentPeers", \.peerLimitPerTorrent), ("port", \.peerPort)]

    private var draft: TransmissionSettings? {
        guard var value = settings else { return nil }
        for (key, path) in Self.integers {
            guard let text = numbers[key], let number = Int(text) else { return nil }
            value[keyPath: path] = number
        }
        guard let number = Double(ratio.replacingOccurrences(of: ",", with: ".")) else { return nil }
        value.seedRatioLimit = number
        return value
    }
    private var validation: String? {
        guard let draft else { return "Enter whole numbers for limits and a decimal number for the seed ratio." }
        return draft.validationError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Transmission Settings", systemImage: "slider.horizontal.3").font(.title2.weight(.semibold))
            Text("Changes apply when you save and are kept for the next start.")
                .font(.callout).foregroundStyle(.secondary)
            if loading {
                ProgressView("Reading current settings…").frame(maxWidth: .infinity).padding()
            } else if settings != nil {
                Picker("Settings section", selection: $tab) {
                    ForEach(["Bandwidth", "Queues", "Seeding", "Network", "Files"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented)
                Form {
                    switch tab {
                    case "Bandwidth": bandwidth
                    case "Queues": queues
                    case "Network": network
                    case "Files": files
                    default: seeding
                    }
                }.formStyle(.grouped).frame(height: 420).disabled(saving)
                if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
            }
            Divider()
            HStack(spacing: 5) {
                Text("Powered by")
                Link("Transmission", destination: URL(string: "https://transmissionbt.com/")!)
                Text("·")
                Link("License & credits", destination: URL(string: "https://github.com/transmission/transmission/blob/4.1.4/COPYING")!)
                if let notices = Bundle.main.resourceURL?.appendingPathComponent("ThirdParty"),
                   FileManager.default.fileExists(atPath: notices.path) {
                    Text("·")
                    Button("Bundled notices") { NSWorkspace.shared.open(notices) }.buttonStyle(.link)
                }
                Spacer()
            }.font(.caption).foregroundStyle(.secondary)
            Text("The open-source BitTorrent engine by the Transmission contributors.")
                .font(.caption2).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                if !loading { Button("Reload") { Task { await load() } }.disabled(saving).help("Discard edits and read current settings") }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Save", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(loading || saving || draft == nil || validation != nil)
            }
        }.padding(24).frame(width: 600).interactiveDismissDisabled(saving)
            .task { await load() }
    }

    private var seeding: some View {
        Section("Automatic stopping") {
            Toggle("Stop seeding at ratio", isOn: flag(\.seedRatioLimited))
            TextField("Seed ratio", text: $ratio).disabled(settings?.seedRatioLimited != true)
            note("Ratio 1.0 means uploaded as much as downloaded; 2.0 means twice as much. Reaching the target stops seeding and keeps your files.")
            Toggle("Stop seeding after inactivity", isOn: flag(\.idleSeedingLimitEnabled))
            integer("Inactivity (minutes)", "idle", enabled: settings?.idleSeedingLimitEnabled == true)
            note("The first reached stop condition wins. These are global defaults; torrents with their own ratio or inactivity override keep that override. Lowering a target can stop existing seeds immediately.")
        }
    }
    private var bandwidth: some View {
        Group {
            Section("Regular limits") {
                Toggle("Limit download speed", isOn: flag(\.speedLimitDownEnabled))
                integer("Download (kB/s)", "down", enabled: settings?.speedLimitDownEnabled == true)
                Toggle("Limit upload speed", isOn: flag(\.speedLimitUpEnabled))
                integer("Upload (kB/s)", "up", enabled: settings?.speedLimitUpEnabled == true)
                note("1,000 kB/s = 1 MB/s. An enabled limit of 0 stops traffic in that direction.")
            }
            Section("Temporary limits · Turtle mode") {
                Toggle("Use temporary limits now", isOn: flag(\.altSpeedEnabled))
                integer("Temporary download (kB/s)", "altDown")
                integer("Temporary upload (kB/s)", "altUp")
                note("Temporary limits override regular limits while active.")
                Toggle("Schedule temporary limits", isOn: flag(\.altSpeedTimeEnabled))
                DatePicker("Start", selection: time(\.altSpeedTimeBegin), displayedComponents: .hourAndMinute)
                    .disabled(settings?.altSpeedTimeEnabled != true)
                DatePicker("End", selection: time(\.altSpeedTimeEnd), displayedComponents: .hourAndMinute)
                    .disabled(settings?.altSpeedTimeEnabled != true)
                HStack {
                    ForEach(Array(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].enumerated()), id: \.offset) { index, title in
                        Toggle(title, isOn: day(index)).toggleStyle(.button).font(.caption)
                    }
                }.disabled(settings?.altSpeedTimeEnabled != true)
                note("Schedule uses this Mac’s local time; an end before the start spans midnight.")
            }
        }
    }
    private var queues: some View {
        Group {
            Section("Downloads") {
                Toggle("Limit simultaneous downloads", isOn: flag(\.downloadQueueEnabled))
                integer("Maximum downloads", "queue", enabled: settings?.downloadQueueEnabled == true)
            }
            Section("Uploads") {
                Toggle("Limit simultaneous seeds", isOn: flag(\.seedQueueEnabled))
                integer("Maximum seeds", "seeds", enabled: settings?.seedQueueEnabled == true)
            }
            Section("Stalled transfers") {
                Toggle("Exclude stalled transfers from queue limits", isOn: flag(\.queueStalledEnabled))
                integer("Consider stalled after (minutes)", "stalled", enabled: settings?.queueStalledEnabled == true)
                note("Excluding stalled transfers can allow more running torrents than the maximum above.")
            }
        }
    }
    private var network: some View {
        Group {
            Section("Peers") {
                integer("Maximum peers overall", "peers")
                integer("Maximum peers per torrent", "torrentPeers")
                note("The per-torrent limit is the default for new torrents; existing torrents may retain their own limit.")
                Toggle("DHT for public torrents", isOn: flag(\.dhtEnabled))
                Toggle("Peer exchange (PEX)", isOn: flag(\.pexEnabled))
                Toggle("Local peer discovery", isOn: flag(\.lpdEnabled))
                Picker("Peer encryption", selection: text(\.encryption)) {
                    Text("Prefer encrypted").tag("preferred")
                    Text("Require encrypted").tag("required")
                    Text("Allow unencrypted").tag("allowed")
                }
                note("Peer encryption does not hide your IP address.")
            }
            Section("Incoming connections") {
                integer("Peer port", "port")
                Toggle("Random peer port on startup", isOn: flag(\.peerPortRandomOnStart))
                Toggle("Automatic port mapping (UPnP / NAT-PMP)", isOn: flag(\.portForwardingEnabled))
                note("If you forward a peer port on your router, keep that rule in sync with this setting.")
            }
        }
    }
    private var files: some View {
        Group {
            Section("Folders") {
                folder("Download folder", \.downloadDir)
                Toggle("Use a separate folder for incomplete downloads", isOn: flag(\.incompleteDirEnabled))
                folder("Incomplete folder", \.incompleteDir).disabled(settings?.incompleteDirEnabled != true)
                note("Folder changes are defaults for new transfers. Existing downloads are not moved.")
            }
            Section("New transfers") {
                Toggle("Start new downloads by default", isOn: flag(\.startAddedTorrents))
                Toggle("Add .part to incomplete filenames", isOn: flag(\.renamePartialFiles))
                note("The Add Download sheet uses this start preference; you can override it for each addition.")
            }
        }
    }

    private func note(_ message: String) -> some View { Text(message).font(.caption).foregroundStyle(.secondary) }
    private func integer(_ title: String, _ key: String, enabled: Bool = true) -> some View {
        TextField(title, text: Binding(get: { numbers[key] ?? "" }, set: { numbers[key] = $0 })).disabled(!enabled)
    }
    private func flag(_ key: WritableKeyPath<TransmissionSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings?[keyPath: key] ?? false }, set: { settings?[keyPath: key] = $0 })
    }
    private func text(_ key: WritableKeyPath<TransmissionSettings, String>) -> Binding<String> {
        Binding(get: { settings?[keyPath: key] ?? "" }, set: { settings?[keyPath: key] = $0 })
    }
    private func time(_ key: WritableKeyPath<TransmissionSettings, Int>) -> Binding<Date> {
        Binding(get: {
            let minutes = settings?[keyPath: key] ?? 0
            return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        }, set: {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
            settings?[keyPath: key] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }
    private func day(_ index: Int) -> Binding<Bool> {
        Binding(get: { ((settings?.altSpeedTimeDay ?? 0) & (1 << index)) != 0 }, set: { enabled in
            guard let current = settings?.altSpeedTimeDay else { return }
            settings?.altSpeedTimeDay = enabled ? current | (1 << index) : current & ~(1 << index)
        })
    }
    private func folder(_ title: String, _ key: WritableKeyPath<TransmissionSettings, String>) -> some View {
        HStack {
            TextField(title, text: text(key))
            Button("Choose…") {
                if let path = model.chooseDirectory(current: settings?[keyPath: key] ?? "") { settings?[keyPath: key] = path }
            }
        }
    }
    private func populate(_ value: TransmissionSettings) {
        settings = value
        numbers = Dictionary(uniqueKeysWithValues: Self.integers.map { ($0.0, String(value[keyPath: $0.1])) })
        ratio = String(value.seedRatioLimit)
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let value = try await model.engineSettings()
            original = value; populate(value)
        } catch { settings = nil; self.error = error.localizedDescription }
    }
    private func save() {
        guard let draft, draft.validationError == nil, let original else { return }
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                let actual = try await model.saveEngineSettings(draft, previous: original)
                let expected = try draft.rpcParameters(), before = try original.rpcParameters(), after = try actual.rpcParameters()
                let changed = expected.filter { before[$0.key] != $0.value }
                self.original = actual; populate(actual)
                guard changed.allSatisfy({ after[$0.key] == $0.value }) else {
                    error = "Transmission returned different values for your edits. Review the current values before saving again."
                    return
                }
                dismiss()
            } catch {
                self.error = "Could not confirm saved settings: \(error.localizedDescription) Use Reload to read current values before retrying."
            }
        }
    }
}
