import XCTest

@testable import App

/// Task 01a120be: the share sheet's large-file path. The limit is the
/// server's (`GET /api/app/upload_config`); files over the multipart
/// threshold reserve an upload and queue a background PATCH for every
/// chunk at once, while the sheet is still in the foreground.
final class LargeUploadTests: XCTestCase {
    private let config = UploadConfig(
        maxUploadBytes: 1_000_000_000, maxUploadLabel: "1 GB", chunkBytes: 100, multipartMaxBytes: 8_000_000)

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    // MARK: upload_config

    func testUploadConfigDecodes() throws {
        StubURLProtocol.respond = { _ in
            (200, Data(#"{"max_upload_bytes":1073741824,"max_upload_label":"1 GB","chunk_bytes":33554432,"multipart_max_bytes":8000000}"#.utf8))
        }
        let api = SuiteAPIClient(session: StubURLProtocol.session(), tokens: MemoryTokenStore(tokens: ["h.example.com": "tok"]))
        let done = expectation(description: "config")
        var got: UploadConfig?
        api.uploadConfig(host: "h.example.com") {
            got = try? $0.get()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(
            got, UploadConfig(maxUploadBytes: 1_073_741_824, maxUploadLabel: "1 GB", chunkBytes: 33_554_432, multipartMaxBytes: 8_000_000))
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.path, "/api/app/upload_config")
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testReserveUploadPostsTheFileAndMapsA413() throws {
        StubURLProtocol.respond = { _ in (413, Data(#"{"error":"file_too_large","max_upload_label":"1 GB"}"#.utf8)) }
        let api = SuiteAPIClient(session: StubURLProtocol.session(), tokens: MemoryTokenStore(tokens: ["h.example.com": "tok"]))
        let done = expectation(description: "reserve")
        var failure: Error?
        api.reserveUpload(
            host: "h.example.com", spaceID: "s1", filename: "clip.mov", contentType: "video/quicktime", byteSize: 1_100_000_000,
            text: "the clip", agentID: nil
        ) {
            if case .failure(let error) = $0 { failure = error }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(failure as? SuiteAPIClient.Failure, .refused(status: 413, code: "file_too_large"))
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.path, "/api/app/spaces/s1/uploads")
        let body = try XCTUnwrap(StubURLProtocol.json(at: 0))
        XCTAssertEqual(body["filename"] as? String, "clip.mov")
        XCTAssertEqual((body["byte_size"] as? NSNumber)?.int64Value, 1_100_000_000)
        XCTAssertEqual(body["text"] as? String, "the clip")
    }

    // MARK: Routing

    func testRoutingAtTheMultipartThresholdAndTheServerLimit() {
        XCTAssertEqual(ShareRoute.decide(fileName: "a.bin", fileBytes: 7_999_000, multipartBodyBytes: 8_000_000, config: config), .multipart)
        XCTAssertEqual(ShareRoute.decide(fileName: "a.bin", fileBytes: 7_999_001, multipartBodyBytes: 8_000_001, config: config), .chunked)
        XCTAssertEqual(
            ShareRoute.decide(fileName: "quarterly-raw.mov", fileBytes: 1_153_433_600, multipartBodyBytes: 1_153_434_000, config: config),
            .tooLarge(name: "quarterly-raw.mov", bytes: 1_153_433_600, label: "1 GB"))
        XCTAssertEqual(
            ShareRoute.tooLargeText(name: "quarterly-raw.mov", bytes: 1_153_433_600, label: "1 GB"),
            "quarterly-raw.mov is 1.2 GB. This Suite accepts files up to 1 GB.")
    }

    func testAChangedServerLimitChangesTheDecision() {
        let raised = UploadConfig(maxUploadBytes: 2_000_000_000, maxUploadLabel: "2 GB", chunkBytes: 100, multipartMaxBytes: 8_000_000)
        let lowered = UploadConfig(maxUploadBytes: 500_000_000, maxUploadLabel: "500 MB", chunkBytes: 100, multipartMaxBytes: 8_000_000)
        let size: Int64 = 1_153_433_600
        XCTAssertEqual(ShareRoute.decide(fileName: "f", fileBytes: size, multipartBodyBytes: size + 300, config: raised), .chunked)
        XCTAssertEqual(
            ShareRoute.decide(fileName: "f", fileBytes: 600_000_000, multipartBodyBytes: 600_000_300, config: lowered),
            .tooLarge(name: "f", bytes: 600_000_000, label: "500 MB"))
    }

    /// The shared decimal size rule (task 01a120be brief): the example
    /// table every surface carries.
    func testByteLabelFollowsTheSharedDecimalRule() {
        let table: [(Int64, String)] = [
            (1_000_000_000, "1 GB"),
            (1_073_741_824, "1.1 GB"),
            (899_109_076, "899.1 MB"),
            (900_000_000, "900 MB"),
            (1_153_433_600, "1.2 GB"),
            (8_000_000, "8 MB"),
            (33_554_432, "33.6 MB"),
            (999_960_000, "1 GB"),
            (512, "512 bytes"),
        ]
        for (bytes, label) in table {
            XCTAssertEqual(ByteLabel.format(bytes), label, "format(\(bytes))")
        }
        XCTAssertEqual(ByteLabel.progress(sent: 412_000_000, total: 900_000_000), "412 of 900 MB")
        XCTAssertEqual(ByteLabel.progress(sent: 416_000_000, total: 899_109_076), "416 of 899.1 MB")
        XCTAssertEqual(ByteLabel.progress(sent: 999_000_000, total: 900_000_000), "900 of 900 MB", "sent is clamped to total")
        XCTAssertEqual(ByteLabel.format(999), "999 bytes")
        XCTAssertEqual(ByteLabel.format(1_000), "1 KB")
        XCTAssertEqual(ByteLabel.format(1_049), "1 KB")
        XCTAssertEqual(ByteLabel.format(1_050), "1.1 KB", "half up")
    }

    func testShareSheetSizeCopyUsesTheSameRule() {
        XCTAssertEqual(
            ShareSheetModel.Banner.tooLarge(bytes: 33_554_432).text,
            "This item is 33.6 MB. Burrow takes up to 8 MB from the share sheet.")
    }

    // MARK: Chunk slicing

    func testChunkRangesAndSlicedBytes() throws {
        XCTAssertEqual(ChunkPlan.ranges(size: 250, chunkBytes: 100), [0..<100, 100..<200, 200..<250])
        XCTAssertEqual(ChunkPlan.range(offset: 150, size: 250, chunkBytes: 100), 150..<250)
        XCTAssertEqual(ChunkPlan.range(offset: 250, size: 250, chunkBytes: 100), 250..<250)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data((0..<250).map { UInt8($0 % 251) })
        let source = dir.appendingPathComponent("source")
        try bytes.write(to: source)
        var joined = Data()
        for (i, range) in ChunkPlan.ranges(size: 250, chunkBytes: 100).enumerated() {
            let chunk = dir.appendingPathComponent("c\(i)")
            try ChunkPlan.writeChunk(from: source, range: range, to: chunk)
            joined.append(try Data(contentsOf: chunk))
        }
        XCTAssertEqual(joined, bytes)
    }

    // MARK: Background uploader (every chunk queued up front)

    /// Records every task the uploader starts; the test answers them.
    private final class ManualTransport: UploadTransport {
        struct Sent {
            let request: URLRequest
            let file: URL?
            let body: Data?
            let description: String
            let key: String
            var method: String { request.httpMethod ?? "?" }
            var offset: String { request.value(forHTTPHeaderField: "Upload-Offset") ?? "-" }
            var call: String { "\(method) \(offset)" }
        }
        var sent: [Sent] = []
        var cancelled: [String] = []
        var live: [String: String] = [:]
        private var next = 0

        func send(_ request: URLRequest, file: URL?, description: String, sessionID: String) -> String {
            next += 1
            let key = "\(sessionID)#\(next)"
            sent.append(Sent(request: request, file: file, body: file.flatMap { try? Data(contentsOf: $0) }, description: description, key: key))
            return key
        }

        func liveTasks(sessionID: String, completion: @escaping ([String: String]) -> Void) {
            completion(live.filter { $0.key.hasPrefix(sessionID + "#") })
        }

        func cancel(jobID: String, sessionIDs: [String]) { cancelled.append(jobID) }
    }

    private struct Rig {
        let dir: URL
        let uploader: BackgroundUploader
        let transport: ManualTransport
        let notices: () -> [UploadNotice]

        /// Answers one recorded task and waits for the uploader to act.
        func answer(_ sent: ManualTransport.Sent, _ event: UploadEvent) {
            uploader.handle(taskKey: sent.key, description: sent.description, event: event)
            uploader.drain()
        }

        /// Task `index`, failing the test (not crashing it) when absent.
        func sent(_ index: Int) throws -> ManualTransport.Sent {
            try XCTUnwrap(transport.sent.indices.contains(index) ? transport.sent[index] : nil, "no task #\(index)")
        }

        func patch(at offset: Int64) -> ManualTransport.Sent? {
            transport.sent.last { $0.method == "PATCH" && $0.offset == String(offset) }
        }
    }

    private func makeRig() -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let transport = ManualTransport()
        let uploader = BackgroundUploader(store: UploadJobStore(directory: dir), transport: transport, sessionID: "app-session")
        let box = NoticeBox()
        uploader.notify = { box.append($0) }
        return Rig(dir: dir, uploader: uploader, transport: transport, notices: { box.items })
    }

    private final class NoticeBox {
        private let lock = NSLock()
        private var _items: [UploadNotice] = []
        var items: [UploadNotice] {
            lock.lock()
            defer { lock.unlock() }
            return _items
        }
        func append(_ notice: UploadNotice) {
            lock.lock()
            _items.append(notice)
            lock.unlock()
        }
    }

    private let sourceBytes = Data((0..<250).map { UInt8($0 % 251) })

    /// Enqueues a 250-byte file in 100-byte chunks, as the share sheet does.
    private func enqueue(_ rig: Rig, reservedOffset: Int64 = 0) throws -> URL {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
        try sourceBytes.write(to: source)
        try rig.uploader.enqueue(
            reservation: UploadReservation(id: "job1", uploadURL: "/chat/attachments/upload/tok", chunkBytes: 100, offset: reservedOffset),
            host: "h.example.com", file: source, filename: "clip.mov", byteSize: 250, spaceName: "design-review")
        return source
    }

    func testEveryChunkTaskIsCreatedUpFrontWithAlignedOffsetsAndLengths() throws {
        let rig = makeRig()
        let source = try enqueue(rig)

        // Before enqueue returns (the sheet is still up) and before any
        // response: one PATCH per chunk, no HEAD.
        XCTAssertEqual(rig.transport.sent.map(\.call), ["PATCH 0", "PATCH 100", "PATCH 200"])
        XCTAssertEqual(rig.transport.sent.map { $0.body?.count }, [100, 100, 50], "exactly min(chunk_bytes, total - offset) bytes")
        XCTAssertEqual(rig.transport.sent.compactMap(\.body).reduce(Data(), +), sourceBytes)
        XCTAssertEqual(rig.transport.sent.map(\.description), ["job1|patch|0", "job1|patch|100", "job1|patch|200"])
        let first = try XCTUnwrap(rig.transport.sent.first?.request)
        XCTAssertEqual(first.url?.absoluteString, "https://h.example.com/chat/attachments/upload/tok")
        XCTAssertNil(first.value(forHTTPHeaderField: "Authorization"), "the token in the URL is the only auth")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "the slices replace the full copy")

        // The mapping from task to chunk is persisted for a relaunch.
        let job = try XCTUnwrap(rig.uploader.store.load("job1"))
        XCTAssertEqual(job.pending, [0, 100, 200])
        XCTAssertEqual(Set(job.tasks.values), [0, 100, 200])
        XCTAssertEqual(job.tasks[try rig.sent(1).key], 100)

        // A 204 deletes that chunk's slice and queues nothing new.
        rig.answer(try rig.sent(1), .patched(status: 204, uploadOffset: 0, body: Data()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.uploader.store.chunkURL("job1", offset: 100).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.uploader.store.chunkURL("job1", offset: 0).path))
        XCTAssertEqual(rig.transport.sent.count, 3)
        XCTAssertEqual(rig.notices(), [])
    }

    func testAHeadOffsetSkipsEarlierChunks() throws {
        // A fresh reservation that already holds 200 bytes queues only the
        // chunk at 200.
        let fresh = makeRig()
        _ = try enqueue(fresh, reservedOffset: 200)
        XCTAssertEqual(fresh.transport.sent.map(\.call), ["PATCH 200"])

        // Relaunch: a job the extension left with four chunks outstanding;
        // the task for chunk 300 is still alive in the extension's session.
        let rig = makeRig()
        let store = rig.uploader.store
        let job = UploadJob(
            id: "job2", host: "h.example.com", uploadURL: URL(string: "https://h.example.com/chat/attachments/upload/tok")!,
            filename: "clip.mov", byteSize: 400, chunkBytes: 100, spaceName: "design-review", sessionIDs: ["extension-session"],
            pending: [0, 100, 200, 300], tasks: ["extension-session#1": 0, "extension-session#4": 300],
            updatedAt: Date(timeIntervalSinceNow: -600))
        store.save(job)
        for offset in job.pending { try Data(repeating: 1, count: 100).write(to: store.chunkURL("job2", offset: offset)) }
        rig.transport.live = ["extension-session#4": "job2|patch|300"]

        rig.uploader.resumePending(olderThan: 60)
        rig.uploader.drain()
        rig.uploader.drain()
        XCTAssertEqual(rig.transport.sent.map(\.call), ["HEAD -"], "HEAD before queueing anything")

        rig.answer(try rig.sent(0), .headed(status: 200, uploadOffset: 200))
        XCTAssertEqual(rig.transport.sent.map(\.call), ["HEAD -", "PATCH 200"], "chunks below 200 skipped, live chunk 300 not duplicated")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.chunkURL("job2", offset: 0).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.chunkURL("job2", offset: 100).path))
        XCTAssertEqual(store.load("job2")?.pending, [200, 300])
        XCTAssertEqual(try rig.sent(1).request.url?.absoluteString, "https://h.example.com/chat/attachments/upload/tok")
    }

    func testA410PostsTheExpiredNotificationCancelsTheRestAndCleansUp() throws {
        let rig = makeRig()
        _ = try enqueue(rig)
        rig.answer(try rig.sent(0), .patched(status: 204, uploadOffset: 100, body: Data()))
        rig.answer(try rig.sent(1), .patched(status: 410, uploadOffset: nil, body: Data()))

        XCTAssertEqual(rig.notices(), [.expired(file: "clip.mov", space: "design-review")])
        XCTAssertEqual(
            rig.notices().first?.body,
            "Couldn't send clip.mov to #design-review: the upload expired after the connection was lost too long. Share it again.")
        XCTAssertEqual(rig.notices().first?.request().content.body, rig.notices().first?.body)
        XCTAssertEqual(rig.transport.cancelled, ["job1"], "the remaining chunk tasks are cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.uploader.store.jobDirectory("job1").path), "slices removed")

        // The cancelled task's late callback is ignored: one notice only.
        rig.answer(try rig.sent(2), .transportError)
        XCTAssertEqual(rig.notices().count, 1)
        XCTAssertEqual(rig.transport.sent.count, 3)
    }

    func testA404OnHeadIsExpiredToo() throws {
        let rig = makeRig()
        _ = try enqueue(rig)
        // Force a reconcile as after a relaunch.
        var job = try XCTUnwrap(rig.uploader.store.load("job1"))
        job.updatedAt = Date(timeIntervalSinceNow: -600)
        rig.uploader.store.save(job)
        rig.uploader.resumePending(olderThan: 60)
        rig.uploader.drain()
        rig.uploader.drain()
        let head = try XCTUnwrap(rig.transport.sent.last { $0.method == "HEAD" })
        rig.answer(head, .headed(status: 404, uploadOffset: nil))
        XCTAssertEqual(rig.notices(), [.expired(file: "clip.mov", space: "design-review")])
        XCTAssertNil(rig.uploader.store.load("job1"))
    }

    func testTheFinishing200PostsSentTo() throws {
        let rig = makeRig()
        _ = try enqueue(rig)
        rig.answer(try rig.sent(2), .patched(status: 204, uploadOffset: 0, body: Data()))
        rig.answer(try rig.sent(1), .patched(status: 204, uploadOffset: 0, body: Data()))
        XCTAssertEqual(rig.notices(), [], "out-of-order 204s are not the end")
        rig.answer(try rig.sent(0), .patched(status: 200, uploadOffset: 250, body: Data(#"{"id":"att","message_id":"m1"}"#.utf8)))

        XCTAssertEqual(rig.notices(), [.sent(space: "design-review")])
        XCTAssertEqual(rig.notices().first?.body, "Sent to #design-review")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.uploader.store.jobDirectory("job1").path))
    }

    func testALostFinishing200IsRecoveredWithAZeroLengthPatchAtTheTotal() throws {
        let rig = makeRig()
        _ = try enqueue(rig)
        rig.answer(try rig.sent(0), .patched(status: 204, uploadOffset: 100, body: Data()))
        rig.answer(try rig.sent(1), .patched(status: 204, uploadOffset: 200, body: Data()))
        // The finishing PATCH's 200 is lost; its re-send finds the upload
        // finalized (409 at the total).
        rig.answer(try rig.sent(2), .transportError)
        rig.answer(try XCTUnwrap(rig.patch(at: 200)), .patched(status: 409, uploadOffset: 250, body: Data()))
        XCTAssertEqual(rig.notices(), [])
        let probe = try XCTUnwrap(rig.patch(at: 250), "a zero-length PATCH at the total")
        XCTAssertEqual(probe.body, Data())
        XCTAssertEqual(rig.transport.sent.filter { $0.offset == "250" }.count, 1)
        rig.answer(probe, .patched(status: 200, uploadOffset: 250, body: Data(#"{"message_id":"m1"}"#.utf8)))
        XCTAssertEqual(rig.notices(), [.sent(space: "design-review")])
        XCTAssertNil(rig.uploader.store.load("job1"))
    }

    func testAHeadAtTheTotalSendsTheZeroLengthPatch() throws {
        let rig = makeRig()
        _ = try enqueue(rig)
        var job = try XCTUnwrap(rig.uploader.store.load("job1"))
        job.updatedAt = Date(timeIntervalSinceNow: -600)
        rig.uploader.store.save(job)
        rig.uploader.resumePending(olderThan: 60)
        rig.uploader.drain()
        rig.uploader.drain()
        let head = try XCTUnwrap(rig.transport.sent.last { $0.method == "HEAD" })
        rig.answer(head, .headed(status: 200, uploadOffset: 250))
        let probe = try XCTUnwrap(rig.patch(at: 250))
        XCTAssertEqual(probe.body?.count, 0)
        rig.answer(probe, .patched(status: 200, uploadOffset: 250, body: Data()))
        XCTAssertEqual(rig.notices(), [.sent(space: "design-review")])
    }

    func testATransportFailureRecreatesOnlyThatChunk() throws {
        let rig = makeRig()
        _ = try enqueue(rig)
        rig.answer(try rig.sent(1), .transportError)

        XCTAssertEqual(rig.transport.sent.map(\.call), ["PATCH 0", "PATCH 100", "PATCH 200", "PATCH 100"])
        XCTAssertEqual(try rig.sent(3).body?.count, 100)
        XCTAssertEqual(try rig.sent(3).body, try rig.sent(1).body, "the same slice")
        let job = try XCTUnwrap(rig.uploader.store.load("job1"))
        XCTAssertEqual(job.tasks[try rig.sent(3).key], 100)
        XCTAssertNil(job.tasks[try rig.sent(1).key], "the failed task is forgotten")
        XCTAssertEqual(rig.notices(), [])
    }

    func testRepeatedFailuresOfOneChunkEndInAFailureNotification() throws {
        let rig = makeRig()
        _ = try enqueue(rig)
        for _ in 0...BackgroundUploader.maxFailures {
            rig.answer(try XCTUnwrap(rig.patch(at: 200)), .patched(status: 503, uploadOffset: nil, body: Data()))
        }
        XCTAssertEqual(rig.notices(), [.failed(file: "clip.mov", space: "design-review")])
        XCTAssertEqual(rig.notices().first?.body, "Couldn't send clip.mov to #design-review. Share it again.")
        XCTAssertNil(rig.uploader.store.load("job1"))
    }

    func testAServerWithoutOutOfOrderChunksStillFinishesInOrder() throws {
        // An older server: 409 with its offset for any chunk but the next.
        let rig = makeRig()
        _ = try enqueue(rig)
        rig.answer(try rig.sent(1), .patched(status: 409, uploadOffset: 0, body: Data()))
        rig.answer(try rig.sent(2), .patched(status: 409, uploadOffset: 0, body: Data()))
        XCTAssertEqual(rig.transport.sent.count, 3, "parked, not re-sent yet")
        rig.answer(try rig.sent(0), .patched(status: 204, uploadOffset: 100, body: Data()))
        XCTAssertEqual(rig.transport.sent.map(\.call).suffix(1), ["PATCH 100"])
        rig.answer(try XCTUnwrap(rig.patch(at: 100)), .patched(status: 204, uploadOffset: 200, body: Data()))
        rig.answer(try XCTUnwrap(rig.patch(at: 200)), .patched(status: 200, uploadOffset: 250, body: Data()))
        XCTAssertEqual(rig.notices(), [.sent(space: "design-review")])
    }

    // MARK: Share sheet

    private final class FakeUploader: LargeFileUploading {
        var enqueued: [(UploadReservation, String, Int64)] = []
        func enqueue(
            reservation: UploadReservation, host: String, file: URL, filename: String, byteSize: Int64, spaceName: String
        ) throws {
            enqueued.append((reservation, filename, byteSize))
        }
    }

    private func sheetModel(maxBytes: Int64, label: String, uploader: FakeUploader) -> ShareSheetModel {
        StubURLProtocol.respond = { request in
            switch request.url?.path {
            case "/api/app/spaces":
                return (200, Data(#"{"spaces":[{"id":"s1","name":"design-review","agents":[]}]}"#.utf8))
            case "/api/app/upload_config":
                return (
                    200,
                    Data(
                        #"{"max_upload_bytes":\#(maxBytes),"max_upload_label":"\#(label)","chunk_bytes":100,"multipart_max_bytes":8000000}"#.utf8)
                )
            case "/api/app/spaces/s1/uploads":
                return (201, Data(#"{"id":"r1","upload_url":"/chat/attachments/upload/t","chunk_bytes":100,"offset":0}"#.utf8))
            default:
                return (404, Data())
            }
        }
        let defaultsName = "LargeUploadTests.\(UUID().uuidString)"
        let model = ShareSheetModel(
            install: Install(host: "h.example.com"),
            client: SuiteAPIClient(session: StubURLProtocol.session(), tokens: MemoryTokenStore(tokens: ["h.example.com": "tok"])),
            lastSpace: UserDefaults(suiteName: defaultsName), uploader: uploader)
        model.start()
        let loaded = expectation(description: "loaded")
        func poll() {
            if model.phase == .ready && model.uploadConfig != nil { return loaded.fulfill() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        poll()
        wait(for: [loaded], timeout: 5)
        model.selectedSpaceID = "s1"
        return model
    }

    private func file(named name: String, bytes: Int) throws -> MultipartForm.FilePart {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return MultipartForm.FilePart(filename: name, mimeType: "video/quicktime", url: url)
    }

    func testOverTheServerLimitIsRefusedWithTheServerLabelBeforeAnyUpload() throws {
        let uploader = FakeUploader()
        let model = sheetModel(maxBytes: 1_000_000, label: "1 MB", uploader: uploader)
        model.payload = .file(try file(named: "quarterly-raw.mov", bytes: 2_000_000))

        XCTAssertEqual(model.banner, .overLimit(name: "quarterly-raw.mov", bytes: 2_000_000, label: "1 MB"))
        XCTAssertEqual(model.banner?.text, "quarterly-raw.mov is 2 MB. This Suite accepts files up to 1 MB.")
        XCTAssertFalse(model.canSend)
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url?.path.hasSuffix("/uploads") == true })
    }

    func testALargeFileIsReservedHandedOffAndTheSheetCloses() throws {
        let uploader = FakeUploader()
        let model = sheetModel(maxBytes: 1_000_000_000, label: "1 GB", uploader: uploader)
        model.payload = .file(try file(named: "launch-walkthrough.mov", bytes: 9_000_000))
        XCTAssertNil(model.banner)
        XCTAssertEqual(model.route, .chunked)

        let closed = expectation(description: "closed")
        model.send { closed.fulfill() }
        wait(for: [closed], timeout: 5)

        XCTAssertEqual(model.phase, .handedOff)
        XCTAssertEqual(ShareSheetModel.handedOffText, "Uploading in the background. You can close this.")
        XCTAssertEqual(uploader.enqueued.count, 1)
        XCTAssertEqual(uploader.enqueued.first?.0.id, "r1")
        XCTAssertEqual(uploader.enqueued.first?.2, 9_000_000)
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url?.path.hasSuffix("/messages") == true }, "no multipart body")
    }

    func testASmallFileKeepsTheMultipartPath() throws {
        let uploader = FakeUploader()
        let model = sheetModel(maxBytes: 1_000_000_000, label: "1 GB", uploader: uploader)
        model.payload = .file(try file(named: "small.pdf", bytes: 2_000_000))
        XCTAssertEqual(model.route, .multipart)
    }

    func testSentNotificationCopy() {
        XCTAssertEqual(BackgroundUploader.sentText("design-review"), "Sent to #design-review")
        XCTAssertEqual(BackgroundUploader.sentNotificationRequest("design-review").content.body, "Sent to #design-review")
    }
}
