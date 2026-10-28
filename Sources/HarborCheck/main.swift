import Foundation
import HarborCore
import Darwin

@main struct HarborCheck {
    static func main() async {
        if CommandLine.arguments.dropFirst().first == "--transmission" {
            await checkTransmission()
            return
        }
        let query = CommandLine.arguments.dropFirst().first ?? "ubuntu"
        let requested = CommandLine.arguments.dropFirst(2).compactMap(SearchSource.init(rawValue:))
        let service = SearchService()
        var failed = false
        var collected: [TorrentResult] = []
        for source in requested.isEmpty ? SearchSource.allCases : requested {
            do {
                let results = try await service.search(source, query: query)
                print("\(source.title): \(results.count) results")
                for result in results.prefix(2) { print("  \(result.title) | \(result.formattedSize) | seeds: \(result.seeders.map(String.init) ?? "unknown")") }
                collected += results
                if let first = results.first {
                    if first.archiveIdentifier != nil {
                        var validated = false
                        for item in results.prefix(5) {
                            guard let identifier = item.archiveIdentifier else { continue }
                            do {
                                let url = try await service.archiveTorrentURL(identifier: identifier)
                                let data = try await service.torrentData(from: url)
                                print("  Archive handoff: valid .torrent (\(data.count) bytes); nothing opened or downloaded by a torrent client")
                                validated = true
                                break
                            } catch HarborError.noTorrent {
                                print("  Archive item \(identifier): correctly reported as restricted/unavailable")
                            }
                        }
                        if !validated { throw HarborError.noTorrent }
                    } else if first.magnetURL == nil { throw HarborError.invalidLink }
                }
            } catch {
                failed = true
                print("  FAILED: \(error.localizedDescription)")
            }
        }
        print("Merged: \(collected.count) → \(ResultMerger.merge(collected).count) unique results")
        if failed { exit(1) }
    }

    private static func checkTransmission() async {
        let username = CommandLine.arguments.dropFirst(2).first ?? "harbor"
        guard let buffer = getpass("Local Transmission password: ") else { exit(1) }
        let password = String(cString: buffer)
        memset(buffer, 0, strlen(buffer))
        let client = TransmissionClient(username: username, password: password)
        do {
            let info = try await client.sessionInfo()
            let transfers = try await client.transfers()
            print("Authenticated local RPC: Transmission \(info.version), \(transfers.count) transfers")
            for transfer in transfers {
                print("  \(transfer.name): \(transfer.statusText), \(Int(transfer.progress * 100))%, \(Transfer.speed(transfer.rateDownload))")
                let files = try await client.files(hash: transfer.id)
                print("    File selection decoded: \(files.count) files")
            }
            print("Read-only check complete. No transfers changed.")
        } catch {
            print("Local RPC check failed: \(error.localizedDescription)")
            exit(1)
        }
    }
}
