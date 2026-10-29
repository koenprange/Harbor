import SwiftUI

struct FirstRunSheet: View {
    @Bindable var model: DownloadsModel
    @Environment(\.dismiss) private var dismiss
    @State private var directory = HarborEnvironment.defaultDownloadDirectory
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Set Up Downloads", systemImage: "sailboat.fill").font(.title2.weight(.semibold))
            Text("Choose where your downloads should go. Harbor will set up its local download engine automatically.")
                .foregroundStyle(.secondary)
            HStack {
                Text(directory).font(.callout).lineLimit(3).textSelection(.enabled)
                Spacer()
                Button("Choose Folder…") {
                    if let path = model.chooseDirectory(current: directory) { directory = path }
                }.disabled(saving)
            }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Text("No Transmission account or separate app is needed. Your existing Transmission files and settings are left alone.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Not Now") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Start Harbor") {
                    saving = true; error = nil
                    Task {
                        defer { saving = false }
                        do {
                            if model.setupRequired { try await model.completeSetup(directory: directory) }
                            else { try await DaemonController.shared.start(); await model.refresh(); model.showSetup = false }
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving)
            }
        }.padding(26).frame(width: 480).interactiveDismissDisabled(saving)
    }
}
