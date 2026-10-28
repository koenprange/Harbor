import Foundation
import Testing
@testable import HarborCore

@Test func knabenUsesTorrentHashNotDatabaseIDAndPreservesOrigin() throws {
    let data = Data("""
    {"hits":[{"id":"not-a-torrent-hash","hash":"\(testHash.uppercased())","title":"Example &amp; Soundtrack","bytes":4096,"seeders":500,"liveSeeders":0,"livePeers":2,"date":"2026-10-28T03:33:37+00:00","tracker":"1337x","details":"https://1337x.to/torrent/123/example"},
    {"id":"\(testHash)","title":"Unresolvable record","link":"https://knaben.org/live/dl/example"}]}
    """.utf8)
    let results = try SearchService.parse(data, source: .knaben)
    #expect(results.count == 1)
    #expect(results[0].infoHash == testHash)
    #expect(results[0].seeders == 0)
    #expect(results[0].leechers == 2)
    #expect(results[0].added != nil)
    #expect(results[0].links[0].label == "Knaben · 1337x")
}

@Test func knabenAcceptsHashFromMagnetButNotUnsafeDetailsURL() throws {
    let data = Data("""
    {"hits":[{"title":"Linux","magnetUrl":"magnet:?xt=urn:btih:\(testHash)","details":"javascript:alert(1)"}]}
    """.utf8)
    let result = try #require(SearchService.parse(data, source: .knaben).first)
    #expect(result.infoHash == testHash)
    #expect(result.links[0].url.scheme == "https")
    #expect(result.links[0].url.host == "knaben.org")
}

private func nyaaFeed(item: String) -> Data {
    Data("""
    <rss xmlns:nyaa="https://nyaa.si/xmlns/nyaa" version="2.0"><channel><title>Nyaa</title>\(item)</channel></rss>
    """.utf8)
}

@Test func nyaaParsesNamespacedRSSAndCDATAWithoutReadingHTMLDescriptions() throws {
    let data = nyaaFeed(item: """
    <item><title><![CDATA[Example & soundtrack 日本語]]></title>
    <guid>https://nyaa.si/view/123</guid><pubDate>Mon, 28 Apr 2025 13:00:02 -0000</pubDate>
    <nyaa:infoHash>\(testHash)</nyaa:infoHash><nyaa:seeders>23</nyaa:seeders><nyaa:leechers>0</nyaa:leechers>
    <nyaa:size>1.5 GiB</nyaa:size><nyaa:category>Audio - Lossless</nyaa:category>
    <description><![CDATA[<script>doNotRun()</script>]]></description></item>
    """)
    let result = try #require(SearchService.parse(data, source: .nyaa).first)
    #expect(result.title == "Example & soundtrack 日本語")
    #expect(result.seeders == 23)
    #expect(result.leechers == 0)
    #expect(result.size == 1610612736)
    #expect(result.added != nil)
    #expect(result.magnetURL?.scheme == "magnet")
}

@Test func nyaaRejectsDTDWrongRootAndTruncatedXML() {
    let dangerous = Data("""
    <!DOCTYPE rss [<!ENTITY secret SYSTEM "file:///etc/passwd">]><rss><channel><title>&secret;</title></channel></rss>
    """.utf8)
    for data in [dangerous, Data("<html><body>Blocked</body></html>".utf8), Data("<rss><channel>".utf8)] {
        #expect(throws: (any Error).self) { try SearchService.parse(data, source: .nyaa) }
    }
}

@Test func nyaaDropsInvalidHashesOffsiteLinksAndFakeNamespaces() throws {
    let items = """
    <item><title>Invalid hash</title><guid>https://nyaa.si/view/1</guid><nyaa:infoHash>0000000000000000000000000000000000000000</nyaa:infoHash></item>
    <item><title>Wrong host</title><guid>https://nyaa.si.evil.example/view/1</guid><nyaa:infoHash>\(testHash)</nyaa:infoHash></item>
    <item xmlns:evil="https://evil.example"><title>Wrong namespace</title><guid>https://nyaa.si/view/1</guid><evil:infoHash>\(testHash)</evil:infoHash></item>
    """
    #expect(try SearchService.parse(nyaaFeed(item: items), source: .nyaa).isEmpty)
    #expect(try SearchService.parse(nyaaFeed(item: ""), source: .nyaa).isEmpty)
}

@Test func feedSizeParsingHandlesUnitsAndOverflow() {
    #expect(SearchService.rssSize("1.5 GiB") == 1610612736)
    #expect(SearchService.rssSize("2.5 MB") == 2500000)
    #expect(SearchService.rssSize("-1 GiB") == nil)
    #expect(SearchService.rssSize("NaN GiB") == nil)
    #expect(SearchService.rssSize("1e100 TiB") == nil)
    #expect(SearchService.rssSize("2 unknown") == nil)
}

@Test func newSourcesAreEnabledOnceWithoutReenablingUserOptOuts() {
    let old = SearchSource.restoredSelection(enabled: ["pirateBay"], known: nil)
    #expect(old == [.pirateBay, .knaben, .nyaa])
    let current = SearchSource.restoredSelection(enabled: ["pirateBay"], known: SearchSource.allCases.map(\.rawValue))
    #expect(current == [.pirateBay])
    #expect(SearchSource.restoredSelection(enabled: nil, known: nil) == Set(SearchSource.allCases))
}

@Test func aggregatorResultsMergeWithExistingSourcesWithoutInflatingProviderCount() {
    let links: [SourceLink] = [
        .init(source: .knaben, url: URL(string: "https://1337x.to/torrent/1/example")!, indexer: "1337x"),
        .init(source: .knaben, url: URL(string: "https://knaben.org/search/test")!, indexer: "The Pirate Bay"),
        .init(source: .torrentsCSV, url: URL(string: "https://torrents-csv.com/")!)
    ]
    let results = links.map { TorrentResult(title: "Example", infoHash: testHash, links: [$0]) }
    let merged = ResultMerger.merge(results)
    #expect(merged.count == 1)
    #expect(merged[0].sourceCount == 2)
    #expect(merged[0].links.count == 3)
    #expect(merged[0].sourceLabel == "TorrentsCSV, Knaben")
}
