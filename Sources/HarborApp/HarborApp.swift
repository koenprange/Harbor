import SwiftUI
import AppKit

@main struct HarborApp: App {
    @NSApplicationDelegateAdaptor(HarborLifecycle.self) private var lifecycle
    @Environment(\.openWindow) private var openWindow
    @State private var model = SearchModel()

    var body: some Scene {
        Window("Harbor", id: "main") {
            ContentView(model: model)
                .tint(Color(red: 0.08, green: 0.52, blue: 0.54))
                .frame(minWidth: 900, minHeight: 570)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1200, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Download Settings…") {
                    openWindow(id: "main")
                    model.downloads.showSettings = true
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }.keyboardShortcut(",")
            }
            CommandMenu("Search") {
                Button("Search Again") { model.search() }.keyboardShortcut("r")
                    .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.enabled.isEmpty)
                Button("Stop Search") { model.stop() }.keyboardShortcut(".")
                    .disabled(!model.isSearching)
                Divider()
                Button("Add to Downloads…") { if let result = model.selected { model.openInTransmission(result) } }
                    .keyboardShortcut(.return, modifiers: .command).disabled(model.selected == nil || model.isOpening)
                Button("Copy Magnet Link") { if let result = model.selected { model.copyMagnet(result) } }
                    .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(model.selected?.magnetURL == nil)
            }
            CommandMenu("Downloads") {
                Button("Show Downloads") { model.scope = "downloads" }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Download Settings…") { model.downloads.showSettings = true }
                Button("Connection Settings…") { model.downloads.showConnection = true }
            }
        }
        MenuBarExtra {
            MenuBarView(model: model) {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        } label: {
            HarborStatusLabel(model: model.downloads)
        }
        .menuBarExtraStyle(.window)
    }
}
