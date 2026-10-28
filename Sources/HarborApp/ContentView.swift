import SwiftUI
import HarborCore

struct ContentView: View {
    @Bindable var model: SearchModel
    @FocusState private var searchFocused: Bool
    @State private var showInspector = true
    @State private var sourcePopover: SearchSource?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 225, max: 280)
        } detail: {
            Group {
                if isDownloads {
                    DownloadsView(model: model.downloads)
                } else {
                    VStack(spacing: 0) {
                searchBar
                Divider()
                HSplitView {
                    resultArea.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    if showInspector, let selected = model.selected {
                        ResultInspector(result: selected, model: model)
                            .frame(minWidth: 250, idealWidth: 280, maxWidth: 340, maxHeight: .infinity)
                    }
                }
                Divider()
                statusBar
                    }
                }
            }
            .navigationTitle("Harbor")
            .toolbar {
                if !isDownloads { ToolbarItem(placement: .primaryAction) {
                    Button { showInspector.toggle() } label: { Label("Show Details", systemImage: "sidebar.right") }
                        .help("Show or hide result details")
                } }
            }
        }
        .sheet(isPresented: Binding(get: { model.downloads.showConnection }, set: { model.downloads.showConnection = $0 })) {
            ConnectionSheet(model: model.downloads)
        }
        .sheet(isPresented: Binding(get: { model.downloads.showSettings }, set: { model.downloads.showSettings = $0 })) {
            EngineSettingsSheet(model: model.downloads)
        }
        .sheet(item: $model.pendingAddition) { result in AddDownloadSheet(result: result, model: model) }
        .alert("Harbor", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .background {
            Button("Focus Search") { searchFocused = true }.keyboardShortcut("f").hidden()
        }
        .onAppear { searchFocused = true; model.downloads.startPolling() }
        .onChange(of: model.scope) {
            model.downloads.filter = model.scope?.hasPrefix("downloads:") == true ? String(model.scope!.dropFirst("downloads:".count)) : ""
            if let selection = model.selection, !model.visibleResults.contains(where: { $0.id == selection }) {
                model.selection = nil
            }
        }
    }

    private var isDownloads: Bool {
        model.scope == "downloads" || model.scope?.hasPrefix("downloads:") == true
    }

    private func downloadRow(_ title: String, symbol: String, filter: String) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text("\(model.downloads.count(for: filter))").foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: { Image(systemName: symbol) }
        .tag(filter.isEmpty ? "downloads" : "downloads:\(filter)")
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "sailboat.fill")
                    .font(.system(size: 25, weight: .medium)).foregroundStyle(.tint)
                    .frame(width: 43, height: 43)
                    .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Harbor").font(.title2.weight(.semibold))
                    Text("Search & downloads").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 18)

            List(selection: $model.scope) {
                Section("Downloads") {
                    downloadRow("All Downloads", symbol: "arrow.down.circle", filter: "")
                    downloadRow("Active", symbol: "arrow.up.arrow.down", filter: "active")
                    downloadRow("Queued", symbol: "clock", filter: "queued")
                    downloadRow("Seeding", symbol: "arrow.up.circle", filter: "seeding")
                    downloadRow("Paused", symbol: "pause.circle", filter: "paused")
                    downloadRow("Completed", symbol: "checkmark.circle", filter: "complete")
                }
                Section("Search") {
                    Label {
                        HStack { Text("All Results"); Spacer(); Text("\(model.results.count)").foregroundStyle(.secondary).monospacedDigit() }
                    } icon: { Image(systemName: "magnifyingglass") }
                    .tag("all")
                    ForEach(SearchSource.allCases) { source in
                        HStack(spacing: 9) {
                            Image(systemName: source.symbol).frame(width: 19).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.title).lineLimit(1)
                                Text(model.enabled.contains(source) ? (model.states[source] ?? .idle).caption : "Disabled")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if model.states[source] == .searching { ProgressView().controlSize(.mini) }
                            else if case .failed = model.states[source] {
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.caption)
                            }
                        }
                        .padding(.vertical, 3).tag(source.rawValue).help(source.subtitle)
                    }
                }
                if !model.recentSearches.isEmpty {
                    Section {
                        ForEach(model.recentSearches, id: \.self) { search in
                            Button { model.search(search) } label: {
                                Label(search, systemImage: "clock").lineLimit(1).foregroundStyle(.secondary)
                            }.buttonStyle(.plain).help(search)
                        }
                    } header: {
                        HStack {
                            Text("Recent searches")
                            Spacer()
                            Button {
                                model.recentSearches = []
                                UserDefaults.standard.removeObject(forKey: "recentSearches")
                            } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                .buttonStyle(.plain).help("Clear recent searches")
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Button { model.downloads.showConnection = true } label: { HStack(spacing: 8) {
                Circle().fill(model.downloads.connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transmission · local").font(.caption.weight(.medium))
                    Text(model.downloads.connected ? "Connected on this Mac" : model.downloads.configured ? "Connection unavailable" : "Set up connection")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            } }.buttonStyle(.plain)
            .padding(15)
            .background(.quaternary.opacity(0.4))
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search torrents…", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .focused($searchFocused).onSubmit { model.search() }
                    .accessibilityLabel("Search torrents")
                if !model.query.isEmpty {
                    Button { model.query = ""; searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }.buttonStyle(.plain).help("Clear search")
                }
                Text("⌘F").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.10)))

            Menu {
                ForEach(SearchSource.allCases) { source in
                    Toggle(source.title, isOn: Binding(get: { model.enabled.contains(source) }, set: { _ in model.toggle(source) }))
                }
            } label: { Label(model.sourceSummary, systemImage: "line.3.horizontal.decrease") }
                .menuStyle(.borderlessButton).fixedSize().help("Choose sources for the next search")

            if model.isSearching {
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .controlSize(.large)
            } else {
                Button("Search") { model.search() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.enabled.isEmpty)
            }
        }
        .padding(20)
    }

    private var resultArea: some View {
        VStack(spacing: 0) {
            if model.hasSearched {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.searchedQuery).font(.title3.weight(.semibold)).lineLimit(1)
                    Text("\(model.visibleResults.count) results").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if model.isSearching { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 20).padding(.vertical, 15)
            }
            if !model.hasSearched {
                welcome
            } else if model.visibleResults.isEmpty {
                ContentUnavailableView {
                    Label(model.isSearching ? "Searching the indexes…" : "No results", systemImage: model.isSearching ? "antenna.radiowaves.left.and.right" : "magnifyingglass")
                } description: {
                    Text(model.isSearching ? "Results appear as each source responds." : "Try fewer words or another source. Source status is shown below.")
                }
            } else {
                resultsTable
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle().fill(.tint.opacity(0.06)).frame(width: 138, height: 138)
                Circle().fill(.tint.opacity(0.09)).frame(width: 100, height: 100)
                Image(systemName: "sailboat").font(.system(size: 43, weight: .light)).foregroundStyle(.tint)
            }
            VStack(spacing: 9) {
                Text("A calmer way to search.").font(.system(size: 27, weight: .semibold, design: .rounded))
                Text("Search multiple indexes. Manage your downloads in one place.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 20) {
                Label("Native on your Mac", systemImage: "macwindow")
                Label("No ads or scripts", systemImage: "sparkles")
            }.font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(model.enabled.count) sources enabled  ·  ⌘F to search  ·  ⌘↩ to open a selection")
                .font(.caption).foregroundStyle(.tertiary).padding(.bottom, 25)
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsTable: some View {
        Table(model.visibleResults, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.title) { result in
                HStack(spacing: 9) {
                    Image(systemName: result.archiveIdentifier == nil ? "link" : "archivebox")
                        .font(.system(size: 13)).foregroundStyle(.tint).frame(width: 20)
                    Text(result.title).lineLimit(1).help(result.title)
                }.padding(.vertical, 5)
            }.width(min: 180, ideal: 390)
            TableColumn("Size", value: \.sizeSort) { result in
                Text(result.formattedSize).monospacedDigit().foregroundStyle(.secondary)
            }.width(min: 65, ideal: 85, max: 110)
            TableColumn("Seeds", value: \.seedSort) { result in
                Text(result.seeders.map(String.init) ?? "—").monospacedDigit()
                    .foregroundStyle((result.seeders ?? 0) > 0 ? Color.green : Color.secondary)
            }.width(min: 70, ideal: 75, max: 95)
            TableColumn("Source", value: \.sourceLabel) { result in
                Text(result.sourceCount > 1 ? "\(result.sourceCount) sources" : result.sourceLabel)
                    .font(.caption).foregroundStyle(.secondary).help(result.sourceLabel)
            }.width(min: 90, ideal: 115, max: 150)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let result = model.results.first(where: { $0.id == id }) {
                Button("Add to Downloads…", systemImage: "arrow.down.circle") { model.openInTransmission(result) }
                    .disabled(model.isOpening)
                Button("Copy Magnet Link", systemImage: "link") { model.copyMagnet(result) }
                    .disabled(result.magnetURL == nil)
            }
        } primaryAction: { ids in
            if let id = ids.first, let result = model.results.first(where: { $0.id == id }) { model.openInTransmission(result) }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            ForEach(SearchSource.allCases.filter { model.states[$0] != nil }) { source in
                let state = model.states[source] ?? .idle
                Button { sourcePopover = source } label: {
                    HStack(spacing: 5) {
                        Circle().fill(state.color).frame(width: 6, height: 6)
                        Text(source.shortTitle)
                        if case .complete(let count) = state { Text("\(count)").foregroundStyle(.tertiary) }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(get: { sourcePopover == source }, set: { if !$0 { sourcePopover = nil } })) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(source.title).font(.headline)
                        if case .failed(let message) = state { Text(message).font(.callout) }
                        else { Text(state.caption).font(.callout) }
                    }.padding(18).frame(width: 300, alignment: .leading)
                }
            }
            Spacer(minLength: 8)
            Text(model.notice ?? (model.isSearching ? "Searching…" : model.hasSearched ? "\(model.results.count) unique results" : "Ready to search"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 18).frame(height: 34)
    }
}
