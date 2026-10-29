import SwiftUI

struct ConnectionSheet: View {
    @Bindable var model: DownloadsModel
    @Environment(\.dismiss) private var dismiss
    @State private var username: String
    @State private var password = ""
    @State private var saving = false
    @State private var error: String?
    init(model: DownloadsModel) {
        self.model = model
        _username = State(initialValue: model.username)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Local Transmission Connection", systemImage: "externaldrive.connected.to.line.below")
                .font(.title2.weight(.semibold))
            Text("Harbor controls Transmission on this Mac. Transfers keep running when the window closes and stop when you quit Harbor.")
                .foregroundStyle(.secondary)
            Form {
                LabeledContent("Address", value: "127.0.0.1:\(HarborEnvironment.rpcPort)")
                TextField("Username", text: $username).textContentType(.username)
                SecureField("Password", text: $password).textContentType(.password)
            }
            .textFieldStyle(.roundedBorder)
            Text("Stored in macOS Keychain. Harbor creates the local login automatically for new profiles. This panel can restore credentials for an existing profile.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Save & Connect") {
                    saving = true; error = nil
                    Task {
                        defer { saving = false }
                        do { try await model.saveConnection(username: username, password: password); password = ""; dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(saving || username.isEmpty || password.isEmpty)
            }
        }.padding(26).frame(width: 460).interactiveDismissDisabled(saving)
    }
}
