import Foundation
import Testing
@testable import HarborCore

let testHash = "0123456789abcdef0123456789abcdef01234567"

@Test func parsesAPIBayMixedNumbersAndRejectsSentinels() throws {
    let data = Data("""
    [{"id":"123","name":"Linux &amp; Tools","info_hash":"\(testHash.uppercased())","size":"4096","seeders":"12","leechers":2,"added":"1700000000","category":"303"},
     {"name":"No results returned","info_hash":"0000000000000000000000000000000000000000"},
     {"name":"Invalid","info_hash":"javascript:alert(1)"}]
    """.utf8)
    let results = try SearchService.parse(data, source: .pirateBay)
    #expect(results.count == 1)
    #expect(results[0].infoHash == testHash)
    #expect(results[0].title == "Linux & Tools")
    #expect(results[0].size == 4096)
    #expect(results[0].seeders == 12)
    #expect(results[0].category == "Software")
}

@Test func parsesTorrentsCSVAndMergesByHash() throws {
    let data = Data("""
    {"torrents":[{"infohash":"\(testHash)","name":"Linux","size_bytes":4096,"seeders":9,"leechers":1,"created_unix":1700000000}]}
    """.utf8)
    let csv = try SearchService.parse(data, source: .torrentsCSV)
    let other = TorrentResult(title: "Linux", size: 4096, seeders: 15, infoHash: testHash.uppercased(),
        links: [.init(source: .pirateBay, url: URL(string: "https://thepiratebay.org/description.php?id=1")!)])
    let results = ResultMerger.merge(csv + [other, other])
    #expect(results.count == 1)
    #expect(results[0].links.count == 2)
    #expect(results[0].seeders == 15)
}

@Test func magnetEscapesTitleAndCannotInjectParameters() throws {
    let result = TorrentResult(title: "A &xt=evil # 🚀", infoHash: testHash, links: [])
    let url = try #require(result.magnetURL)
    let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(parts.filter { $0.name == "xt" }.count == 1)
    #expect(parts.first { $0.name == "dn" }?.value == result.title)
    #expect(url.scheme == "magnet")
}

@Test func queryCannotInjectArchiveSearchSyntaxOrURLParameters() throws {
    let query = "hello &cat=500 OR title:* \" / 😀"
    for source in SearchSource.allCases {
        let url = SearchService.searchURL(source, query: query)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(parts.filter { $0.name == "q" }.count == 1)
        if source != .internetArchive { #expect(parts.first { $0.name == "q" }?.value == query) }
        else {
            let value = try #require(parts.first { $0.name == "q" }?.value)
            #expect(value.contains("title:\"OR\" AND title:\"title:*\""))
            #expect(value.contains("format:\"Archive BitTorrent\""))
        }
    }
}

@Test func archiveMetadataHandlesTorrentFilenameAndRejectsPaths() throws {
    let data = Data(#"{"files":[{"name":"Example file_archive.torrent","format":"Archive BitTorrent"}]}"#.utf8)
    let url = try SearchService.parseArchiveTorrent(data, identifier: "example-item")
    #expect(url.host == "archive.org")
    #expect(url.lastPathComponent == "Example file_archive.torrent")
    #expect(throws: (any Error).self) { try SearchService.parseArchiveTorrent(data, identifier: "../evil") }
    let malicious = Data(#"{"files":[{"name":"../../evil.torrent","format":"Archive BitTorrent"}]}"#.utf8)
    #expect(throws: (any Error).self) { try SearchService.parseArchiveTorrent(malicious, identifier: "valid") }
    let restricted = Data(#"{"files":[{"name":"valid_archive.torrent","format":"Archive BitTorrent","private":"true"}]}"#.utf8)
    #expect(throws: (any Error).self) { try SearchService.parseArchiveTorrent(restricted, identifier: "valid") }
}

@Test func archiveSearchKeepsUnknownSwarmCountsUnknown() throws {
    let data = Data(#"{"response":{"docs":[{"identifier":"test-item","title":"Test","item_size":1234},{"identifier":"../escape"}]}}"#.utf8)
    let rows = try SearchService.parse(data, source: .internetArchive)
    #expect(rows.count == 1)
    #expect(rows[0].seeders == nil)
    #expect(rows[0].magnetURL == nil)
    #expect(rows[0].size == 1234)
}

@Test func rejectsHTMLAndUnexpectedJSON() {
    #expect(throws: (any Error).self) { try SearchService.parse(Data("<html>Blocked</html>".utf8), source: .pirateBay) }
    #expect(throws: (any Error).self) { try SearchService.parse(Data("{}".utf8), source: .torrentsCSV) }
}

@Test func validatesTorrentContainerWithoutExecutingAnything() {
    #expect(TorrentValidator.isTorrent(Data("d4:infod4:name4:test6:lengthi1eee".utf8)))
    #expect(!TorrentValidator.isTorrent(Data("<html>Download now</html>".utf8)))
    #expect(!TorrentValidator.isTorrent(Data("d4:info4:teste".utf8)))
    #expect(!TorrentValidator.isTorrent(Data("d4:infod4:name999:testee".utf8)))
    #expect(!TorrentValidator.isTorrent(Data("d4:infodeeTRAILING".utf8)))
    #expect(!TorrentValidator.isTorrent(Data("d4:info".utf8)))
    #expect(!TorrentValidator.isTorrent(Data(("d4:info" + String(repeating: "l", count: 50) + String(repeating: "e", count: 51)).utf8)))
}
