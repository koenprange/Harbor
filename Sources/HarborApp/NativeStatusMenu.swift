import AppKit
import SwiftUI
import HarborCore

@MainActor final class NativeStatusMenu: NSObject, NSMenuDelegate {
    static let shared = NativeStatusMenu(model: .shared)
    var openWindow: (() -> Void)?
    private let model: SearchModel
    private let displayName: String
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    let menu = NSMenu()

    init(model: SearchModel, displayName: String = "Harbor") {
        self.model = model
        self.displayName = displayName
        super.init()
    }

    func install() {
        guard statusItem == nil else { return }
        menu.delegate = self
        menu.autoenablesItems = false
        menu.minimumWidth = 360
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        statusItem = item
        updateIcon()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIcon() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func uninstall() {
        timer?.invalidate()
        timer = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        menu.removeAllItems()
        openWindow = nil
    }

    private func updateIcon() {
        let icon = HarborStatusIcon(model: model.downloads)
        statusItem?.button?.image = icon.image
        let label = displayName == "Harbor" ? icon.toolTip : "\(displayName) · \(icon.toolTip)"
        statusItem?.button?.toolTip = label
        statusItem?.button?.setAccessibilityLabel(label)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menu.removeAllItems()
        let searchContainer = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 44))
        let search = NSSearchField(frame: NSRect(x: 14, y: 8, width: 332, height: 28))
        search.placeholderString = "Search torrents…"
        search.setAccessibilityLabel("Quick search")
        search.sendsSearchStringImmediately = false
        search.sendsWholeSearchString = true
        search.target = self
        search.action = #selector(searchSubmitted(_:))
        searchContainer.addSubview(search)
        addView(searchContainer)
        host(MenuTransferSummary(model: model.downloads), height: 54)
        menu.addItem(.separator())
        if model.downloads.transfers.isEmpty {
            let item = NSMenuItem(title: model.downloads.connected ? "No downloads yet" : "Transfers unavailable", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for transfer in model.downloads.transfers {
                host(MenuTransferRow(model: model.downloads, hash: transfer.id) { [weak self] in
                    self?.showTransfer(transfer.id)
                }, height: 114)
            }
        }
        menu.addItem(.separator())
        addAction("Open \(displayName)", action: #selector(showMain))
        if model.downloads.setupRequired { addAction("Set Up Downloads…", action: #selector(showSetup)) }
        let display = NSMenuItem(title: "Menu bar display", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Menu bar display")
        submenu.autoenablesItems = false
        let selected = UserDefaults.standard.string(forKey: "menuBarDisplay") ?? MenuBarDisplay.arrows.rawValue
        for mode in MenuBarDisplay.allCases {
            let option = NSMenuItem(title: mode.title, action: #selector(selectDisplay(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = mode.rawValue
            option.state = selected == mode.rawValue ? .on : .off
            submenu.addItem(option)
        }
        display.submenu = submenu
        menu.addItem(display)
        menu.addItem(.separator())
        addAction("Quit \(displayName) & Stop Transfers", action: #selector(quit))
    }

    private func addAction(_ title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }
    private func addView(_ view: NSView) {
        let item = NSMenuItem()
        item.view = view
        menu.addItem(item)
    }
    private func host<V: View>(_ view: V, height: CGFloat) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: height)
        addView(hosting)
    }
    private func revealMain() {
        menu.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            self?.openWindow?()
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
    private func showTransfer(_ hash: String) {
        model.downloads.filter = ""
        model.downloads.filterText = ""
        model.scope = "downloads"
        model.downloads.selection = hash
        revealMain()
    }
    @objc private func showSetup() { model.downloads.showSetup = true; revealMain() }
    @objc private func showMain() { revealMain() }
    @objc private func quit() {
        menu.cancelTracking()
        NSApplication.shared.terminate(nil)
    }
    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, MenuBarDisplay(rawValue: value) != nil else { return }
        UserDefaults.standard.set(value, forKey: "menuBarDisplay")
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
        updateIcon()
    }
    @objc private func searchSubmitted(_ sender: NSSearchField) {
        let query = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        model.query = query
        model.search()
        revealMain()
    }
}

private struct MenuTransferSummary: View {
    @Bindable var model: DownloadsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 18) {
                TransferRate(bytes: model.downloadSpeed, direction: .download)
                TransferRate(bytes: model.uploadSpeed, direction: .upload)
            }
            Text(model.connected ? "\(model.count(for: "active")) downloading · \(model.count(for: "seeding")) seeding" : "Disconnected · last known transfer status")
                .foregroundStyle(model.connected ? Color.secondary : .orange)
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
    }
}

private struct MenuTransferRow: View {
    @Bindable var model: DownloadsModel
    let hash: String
    let open: () -> Void
    private var transfer: Transfer? { model.transfers.first { $0.id == hash } }
    var body: some View {
        if let transfer {
            VStack(alignment: .leading, spacing: 7) {
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(transfer.name).font(.callout.weight(.medium)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ProgressView(value: transfer.progress).tint(transfer.progressColor)
                            .accessibilityLabel("Download progress")
                        HStack {
                            Text("\(transfer.statusText) · \(transfer.peerActivityText)").lineLimit(1)
                                .help(transfer.peerActivityDescription)
                            Spacer()
                            Text(transfer.progress, format: .percent.precision(.fractionLength(1))).monospacedDigit()
                        }.font(.caption).foregroundStyle(transfer.error != 0 ? Color.red : .secondary)
                    }.contentShape(Rectangle())
                }.help("Open transfer in Harbor")
                HStack(spacing: 12) {
                    TransferRate(bytes: transfer.rateDownload, direction: .download)
                    TransferRate(bytes: transfer.rateUpload, direction: .upload)
                    Spacer(minLength: 0)
                    Button { model.toggle(transfer) } label: {
                        Image(systemName: transfer.isPaused ? "play.fill" : "pause.fill")
                            .frame(width: 24, height: 20).contentShape(Rectangle())
                    }
                    .accessibilityLabel(transfer.isPaused ? "Resume transfer" : "Pause transfer")
                    .help(transfer.isPaused ? "Resume transfer" : "Pause transfer")
                    .disabled(model.busy || !model.connected)
                }.font(.caption)
            }.buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 8)
        } else {
            Text("Transfer removed").font(.caption).foregroundStyle(.secondary)
        }
    }
}
