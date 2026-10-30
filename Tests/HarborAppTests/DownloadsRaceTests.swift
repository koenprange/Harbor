import Foundation
import Testing
import HarborCore
@testable import HarborApp

@Suite(.serialized) @MainActor struct DownloadsRaceTests {
    private let hash = String(repeating: "a", count: 40)
    private let other = String(repeating: "b", count: 40)

    @Test func removedSelectionInvalidatesPendingFileFailure() async throws {
        let model = try await makeModel()
        model.selection = hash
        DelayedRPC.state.enqueue(.init(result: [:], held: true, status: 500))
        let loading = Task { await model.loadFiles() }
        try await pending()
        DelayedRPC.state.enqueue(.init(result: ["torrents": []]))
        await model.refresh()
        #expect(model.selection == nil)
        #expect(!model.loadingFiles)
        DelayedRPC.state.release()
        await loading.value
        #expect(model.files.isEmpty)
        #expect(model.error == nil)
    }

    @Test func oldFileResponseCannotReplaceNewSelection() async throws {
        let model = try await makeModel()
        model.selection = hash
        DelayedRPC.state.enqueue(.init(result: file("old.bin"), held: true))
        let first = Task { await model.loadFiles() }
        try await pending()
        model.selection = other
        DelayedRPC.state.enqueue(.init(result: file("new.bin")))
        await model.loadFiles()
        #expect(model.files.first?.name == "new.bin")
        DelayedRPC.state.release()
        await first.value
        #expect(model.files.first?.name == "new.bin")
        #expect(!model.loadingFiles)
    }

    @Test func lateFailureFromPreviousSelectionIsIgnored() async throws {
        let model = try await makeModel()
        model.selection = hash
        DelayedRPC.state.enqueue(.init(result: [:], held: true, status: 500))
        let loading = Task { await model.loadFiles() }
        try await pending()
        model.selection = other
        DelayedRPC.state.release()
        await loading.value
        #expect(model.error == nil)
    }

    @Test func releasingModelCancelsItsPollingTask() async throws {
        var model: DownloadsModel? = try await makeModel()
        weak var reference: DownloadsModel?
        reference = model
        let polling = model!.startPolling()
        await Task.yield()
        model = nil
        for _ in 0..<100 where reference != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reference == nil)
        #expect(polling.isCancelled)
        // Clean up even on a regression, so the test cannot leave a background task.
        polling.cancel()
    }

    private func makeModel() async throws -> DownloadsModel {
        DelayedRPC.state.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedRPC.self]
        let client = TransmissionClient(username: "test", password: "test", session: URLSession(configuration: configuration))
        let model = DownloadsModel(client: client)
        DelayedRPC.state.enqueue(.init(result: ["version": "test", "download_dir": "/tmp"]))
        DelayedRPC.state.enqueue(.init(result: ["torrents": [transfer(hash), transfer(other)]]))
        await model.refresh()
        #expect(model.connected)
        return model
    }
    private func pending() async throws {
        for _ in 0..<1000 {
            if DelayedRPC.state.hasPending { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw URLError(.timedOut)
    }
    private func file(_ name: String) -> [String: Any] {
        ["torrents": [["files": [["name": name, "length": 1, "bytes_completed": 0]], "file_stats": [["wanted": true]]]]]
    }
    private func transfer(_ hash: String) -> [String: Any] {
        ["hash_string": hash, "name": "Synthetic", "status": 0, "percent_done": 0,
         "rate_download": 0, "rate_upload": 0, "eta": -1, "total_size": 1,
         "downloaded_ever": 0, "uploaded_ever": 0, "upload_ratio": 0, "download_dir": "/tmp",
         "error": 0, "error_string": "", "queue_position": 0, "peers_connected": 0,
         "peers_sending_to_us": 0, "peers_getting_from_us": 0, "metadata_percent_complete": 1]
    }
}

private final class DelayedRPC: URLProtocol, @unchecked Sendable {
    struct Reply: @unchecked Sendable {
        let result: [String: Any]
        var held = false
        var status = 200
    }
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [Reply] = []
        private var pending: [(DelayedRPC, Reply, Int)] = []
        var hasPending: Bool { lock.withLock { !pending.isEmpty } }
        func reset() { lock.withLock { replies = []; pending = [] } }
        func enqueue(_ reply: Reply) { lock.withLock { replies.append(reply) } }
        func accept(_ request: DelayedRPC, id: Int) -> Reply? {
            lock.withLock {
                let reply = replies.isEmpty ? Reply(result: [:], status: 500) : replies.removeFirst()
                if reply.held { pending.append((request, reply, id)); return nil }
                return reply
            }
        }
        func release() {
            let values = lock.withLock { let values = pending; pending = []; return values }
            for (request, reply, id) in values { request.respond(reply, id: id) }
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let id = body?["id"] as? Int ?? -1
        if let reply = Self.state.accept(self, id: id) { respond(reply, id: id) }
    }
    func respond(_ reply: Reply, id: Int) {
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": reply.result])
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
