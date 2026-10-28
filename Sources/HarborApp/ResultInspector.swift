import SwiftUI
import HarborCore

struct ResultInspector: View {
    let result: TorrentResult
    @Bindable var model: SearchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 13) {
                    Image(systemName: result.archiveIdentifier == nil ? "link.circle.fill" : "archivebox.circle.fill")
                        .font(.system(size: 38, weight: .light)).foregroundStyle(.tint)
                    Text(result.title).font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let category = result.category {
                        Text(category.capitalized).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary, in: Capsule())
                    }
                }

                VStack(spacing: 9) {
                    Button {
                        model.openInTransmission(result)
                    } label: {
                        HStack {
                            if model.openingID == result.id { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.down.circle") }
                            Text(model.openingID == result.id ? "Adding…" : "Add to Downloads…")
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isOpening)
                    if result.magnetURL != nil {
                        Button { model.copyMagnet(result) } label: {
                            Label("Copy Magnet Link", systemImage: "link").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).controlSize(.large)
                    }
                    Text("⌘↩ to open").font(.caption2).foregroundStyle(.tertiary)
                }
                Divider()
                VStack(spacing: 13) {
                    detail(result.archiveIdentifier == nil ? "Size" : "Item size", result.formattedSize)
                    detail("Seeders", result.seeders.map(String.init) ?? "Not reported")
                    detail("Leechers", result.leechers.map(String.init) ?? "Not reported")
                    if let files = result.fileCount { detail("Files", String(files)) }
                    if let date = result.added { detail("Added", date.formatted(date: .abbreviated, time: .omitted)) }
                }
                if let hash = result.infoHash {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("INFO HASH").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(hash).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("FOUND ON").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(result.links, id: \.self) { link in
                        Button { model.openDetails(link) } label: {
                            HStack { Label(link.label, systemImage: link.source.symbol); Spacer(); Image(systemName: "arrow.up.right").font(.caption2) }
                        }.buttonStyle(.plain).foregroundStyle(.tint)
                            .help("Open the source page in your browser")
                    }
                }
                if result.archiveIdentifier != nil {
                    Text("Archive torrents may contain an entire collection. Transmission lets you choose which files to download. Item size can differ from the torrent's payload size.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(22)
        }
        .background(.background.opacity(0.6))
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }.font(.callout)
    }
}
