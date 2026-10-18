import Foundation
import UserNotifications

/// One chunked upload in progress, persisted in the App Group so whichever
/// process is alive (the share extension, or the app the system relaunches
/// for the background session's events) can carry it on.
struct UploadJob: Codable, Equatable {
    var id: String
    var host: String
    /// Absolute `https://<host>/chat/attachments/upload/<token>`.
    var uploadURL: URL
    /// The shared file's name, for the failure notification.
    var filename: String
    var byteSize: Int64
    var chunkBytes: Int64
    var spaceName: String
    /// Background URLSession identifiers this job's tasks run on; the last
    /// one is where new tasks go (the extension's, then the app's).
    var sessionIDs: [String]
    /// The contiguous prefix from 0 the server last reported.
    var contiguous: Int64 = 0
    /// Chunk offsets the server has not acknowledged with a 2xx. Each has a
    /// slice file in the job directory until it is acknowledged.
    var pending: [Int64] = []
    /// Live tasks, keyed `<session identifier>#<task identifier>`, to the
    /// chunk offset each carries (`-1` for a HEAD). Rebuilt from the
    /// session's own task list after a relaunch.
    var tasks: [String: Int64] = [:]
    /// Chunks a 409 put aside because the server is not yet at them (a
    /// server without out-of-order chunks); each is re-sent once the
    /// contiguous offset reaches it.
    var parked: [Int64] = []
    /// Consecutive failures per chunk offset (`-1` for the HEAD).
    var failures: [Int64: Int] = [:]
    var updatedAt = Date()

    var sessionID: String { sessionIDs.last ?? "" }

    func chunkLength(_ offset: Int64) -> Int64 { min(chunkBytes, byteSize - offset) }
}

/// Which bytes a chunk carries.
enum ChunkPlan {
    /// The chunk starting at `offset`: exactly `min(chunkBytes, size - offset)`
    /// bytes, the length the server requires of an aligned chunk.
    static func range(offset: Int64, size: Int64, chunkBytes: Int64) -> Range<Int64> {
        offset..<min(offset + chunkBytes, size)
    }

    /// Every chunk of an upload, in order.
    static func ranges(size: Int64, chunkBytes: Int64) -> [Range<Int64>] {
        stride(from: Int64(0), to: size, by: Int(chunkBytes)).map { range(offset: $0, size: size, chunkBytes: chunkBytes) }
    }

    /// The chunks still to send when the server holds `contiguous` bytes:
    /// every chunk not wholly inside that prefix.
    static func remaining(size: Int64, chunkBytes: Int64, contiguous: Int64) -> [Range<Int64>] {
        ranges(size: size, chunkBytes: chunkBytes).filter { $0.upperBound > contiguous }
    }

    /// Copies `range` of `source` into its own file (streamed, 1 MiB at a
    /// time) so `uploadTask(with:fromFile:)` can send it from disk.
    static func writeChunk(from source: URL, range: Range<Int64>, to target: URL) throws {
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let out = try FileHandle(forWritingTo: target)
        defer { try? out.close() }
        guard !range.isEmpty else { return }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(range.lowerBound))
        var left = range.count
        while left > 0 {
            let data = try input.read(upToCount: min(left, 1 << 20)) ?? Data()
            if data.isEmpty { break }
            try out.write(contentsOf: data)
            left -= data.count
        }
        guard left == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }
}

/// What a request came back with.
enum UploadEvent: Equatable {
    case patched(status: Int, uploadOffset: Int64?, body: Data)
    case headed(status: Int, uploadOffset: Int64?)
    case transportError
}

/// The local notification an upload ends with.
enum UploadNotice: Equatable {
    case sent(space: String)
    /// 404 or 410: the reservation is gone (its sliding TTL lapsed while the
    /// connection was down).
    case expired(file: String, space: String)
    case failed(file: String, space: String)

    var body: String {
        switch self {
        case .sent(let space):
            return BackgroundUploader.sentText(space)
        case .expired(let file, let space):
            return "Couldn't send \(file) to #\(space): the upload expired after the connection was lost too long. Share it again."
        case .failed(let file, let space):
            return "Couldn't send \(file) to #\(space). Share it again."
        }
    }

    func request(trigger: UNNotificationTrigger? = nil) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.body = body
        content.sound = .default
        return UNNotificationRequest(identifier: "burrow.upload.\(UUID().uuidString)", content: content, trigger: trigger)
    }
}

/// Where jobs and their chunk slices live.
struct UploadJobStore {
    let directory: URL

    static var shared: UploadJobStore {
        let base =
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: InstallStore.appGroup)
            ?? FileManager.default.temporaryDirectory
        return UploadJobStore(directory: base.appendingPathComponent("large-uploads", isDirectory: true))
    }

    func jobDirectory(_ id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }
    func chunkURL(_ id: String, offset: Int64) -> URL { jobDirectory(id).appendingPathComponent("chunk-\(offset).part") }

    func save(_ job: UploadJob) {
        try? FileManager.default.createDirectory(at: jobDirectory(job.id), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(job) {
            try? data.write(to: jobDirectory(job.id).appendingPathComponent("job.json"), options: .atomic)
        }
    }

    func load(_ id: String) -> UploadJob? {
        guard let data = try? Data(contentsOf: jobDirectory(id).appendingPathComponent("job.json")) else { return nil }
        return try? JSONDecoder().decode(UploadJob.self, from: data)
    }

    func ids() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: jobDirectory(id))
    }
}

/// Runs requests for jobs. Production: background URLSessions. Tests: a
/// recording fake that the test answers by hand.
protocol UploadTransport: AnyObject {
    /// Starts one task and returns its key, `<session identifier>#<task
    /// identifier>`. `description` is the task's `taskDescription`
    /// (`<job>|patch|<offset>` or `<job>|head`), which outlives a relaunch.
    @discardableResult
    func send(_ request: URLRequest, file: URL?, description: String, sessionID: String) -> String
    /// The live tasks of a session: key -> taskDescription.
    func liveTasks(sessionID: String, completion: @escaping ([String: String]) -> Void)
    /// Cancels every task of `jobID` in these sessions.
    func cancel(jobID: String, sessionIDs: [String])
}

/// What the share sheet hands a large file to.
protocol LargeFileUploading: AnyObject {
    func enqueue(
        reservation: UploadReservation, host: String, file: URL, filename: String, byteSize: Int64, spaceName: String
    ) throws
}

/// Chunked uploads that survive the share extension being torn down
/// (task 01a120be).
///
/// **Every chunk is queued at once, while the sender is still in the
/// foreground.** iOS rate-limits background tasks created by an app the
/// system relaunched while suspended (the review measured the gaps growing
/// 70 s, 126 s, 246 s, 485 s, 962 s), and a gap past the server's 900 s
/// sliding reservation TTL expired the upload at 26%. So the file is cut
/// into one slice file per chunk in the App Group, and each slice becomes
/// its own `uploadTask(with:fromFile:)` PATCH (`Upload-Offset = i *
/// chunk_bytes`, exactly `min(chunk_bytes, total - offset)` bytes) on a
/// background URLSession, all before the sheet closes. The server accepts
/// aligned chunks out of order, answers 204 for each and 200 (with the
/// message) for the one that completes coverage.
///
/// A slice is deleted when its chunk gets a 2xx. Only a chunk whose task
/// failed (transport error, 5xx) is re-created, alone. After a relaunch
/// the app rebuilds which chunks have live tasks from the session's own
/// task list, HEADs for the contiguous offset and queues only the chunks
/// at or past it that have none. When every chunk is acknowledged but the
/// 200 was lost, a zero-length PATCH at `total` fetches it. A 404 or 410
/// (the reservation expired) cancels the rest and posts "Couldn't send
/// <file> to #<space>: the upload expired…"; it never fails silently.
final class BackgroundUploader: NSObject, LargeFileUploading {
    static let sessionPrefix = "com.kobo-ai.burrow.upload."
    static let shared = BackgroundUploader(store: .shared, transport: nil)
    static let maxFailures = 8
    /// The `tasks` value for a HEAD.
    static let headMarker: Int64 = -1

    let store: UploadJobStore
    private(set) var transport: UploadTransport!
    private let queue = DispatchQueue(label: "com.kobo-ai.burrow.upload")
    /// Posts the notification an upload ends with.
    var notify: (UploadNotice) -> Void = { UNUserNotificationCenter.current().add($0.request()) }

    init(store: UploadJobStore, transport: UploadTransport?, sessionID: String? = nil) {
        self.store = store
        self.ownSessionID = sessionID ?? Self.sessionPrefix + (Bundle.main.bundleIdentifier ?? "app") + "." + UUID().uuidString
        super.init()
        self.transport = transport ?? BackgroundSessionTransport(uploader: self)
    }

    /// This process's own session identifier (the extension and the app
    /// cannot share one while both are alive).
    let ownSessionID: String

    /// Slices the file into the App Group and queues a task for every chunk
    /// the reservation does not already hold. Synchronous, so the sheet only
    /// closes once every task exists. The reservation's `offset` is the
    /// server's contiguous offset at the moment it answered, so no HEAD is
    /// needed first.
    func enqueue(
        reservation: UploadReservation, host: String, file: URL, filename: String, byteSize: Int64, spaceName: String
    ) throws {
        guard let url = Self.absoluteUploadURL(reservation.uploadURL, host: host), reservation.chunkBytes > 0 else {
            throw BurrowAPIClient.Failure.badResponse
        }
        var job = UploadJob(
            id: reservation.id, host: host, uploadURL: url, filename: filename, byteSize: byteSize, chunkBytes: reservation.chunkBytes,
            spaceName: spaceName, sessionIDs: [ownSessionID], contiguous: reservation.offset)
        let chunks = ChunkPlan.remaining(size: byteSize, chunkBytes: job.chunkBytes, contiguous: job.contiguous)
        do {
            try FileManager.default.createDirectory(at: store.jobDirectory(job.id), withIntermediateDirectories: true)
            for range in chunks {
                try ChunkPlan.writeChunk(from: file, range: range, to: store.chunkURL(job.id, offset: range.lowerBound))
            }
        } catch {
            store.remove(job.id)
            throw error
        }
        // The slices are the only copy the upload needs.
        try? FileManager.default.removeItem(at: file)
        job.pending = chunks.map(\.lowerBound)
        queue.sync {
            for offset in job.pending { sendChunk(offset, job: &job) }
            store.save(job)
        }
    }

    /// The app's launch: reconcile any job no live process has touched for
    /// a while with its sessions' live tasks, then HEAD for the server's
    /// contiguous offset and queue what is missing.
    func resumePending(olderThan age: TimeInterval = 120) {
        queue.async {
            for id in self.store.ids() {
                guard var job = self.store.load(id) else {
                    // A job this build cannot read (an older format) can
                    // never finish: drop its files.
                    self.store.remove(id)
                    continue
                }
                guard Date().timeIntervalSince(job.updatedAt) > age else { continue }
                if job.sessionID != self.ownSessionID { job.sessionIDs.append(self.ownSessionID) }
                job.updatedAt = Date()
                self.store.save(job)
                self.reconcile(job.id, sessions: job.sessionIDs, live: [:])
            }
        }
    }

    /// Collects the live tasks of every session the job has used, then
    /// rebuilds its task map from them and HEADs.
    private func reconcile(_ id: String, sessions: [String], live: [String: String]) {
        if let session = sessions.first {
            return transport.liveTasks(sessionID: session) { found in
                self.reconcile(id, sessions: Array(sessions.dropFirst()), live: live.merging(found) { a, _ in a })
            }
        }
        queue.async {
            guard var job = self.store.load(id) else { return }
            job.tasks = [:]
            for (key, description) in live {
                let parts = description.split(separator: "|")
                guard parts.count == 3, parts[0] == id, let offset = Int64(parts[2]) else { continue }
                job.tasks[key] = offset
            }
            self.sendHead(job: &job)
            self.store.save(job)
        }
    }

    /// Test seam: waits until every queued step has run.
    func drain() { queue.sync {} }

    /// One task came back. `description` is its taskDescription; `taskKey`
    /// its `<session>#<task>` key.
    func handle(taskKey: String?, description: String, event: UploadEvent) {
        queue.async {
            let parts = description.split(separator: "|")
            guard parts.count >= 2, var job = self.store.load(String(parts[0])) else { return }
            var chunk = parts.count == 3 ? Int64(parts[2]) : nil
            if let taskKey, let mapped = job.tasks.removeValue(forKey: taskKey), chunk == nil, mapped >= 0 { chunk = mapped }
            job.updatedAt = Date()
            if parts[1] == "head" {
                self.headed(event, job: &job)
            } else if let chunk {
                self.patched(event, chunk: chunk, job: &job)
            }
        }
    }

    // MARK: Rules

    private func patched(_ event: UploadEvent, chunk: Int64, job: inout UploadJob) {
        var status = 0
        var server: Int64?
        if case .patched(let s, let offset, _) = event { (status, server) = (s, offset) }
        switch status {
        case 200:
            return finish(job, .sent(space: job.spaceName))
        case 204 where chunk == job.byteSize, 409 where chunk == job.byteSize && server == job.byteSize:
            // The completing probe found the upload already finalized.
            return finish(job, .sent(space: job.spaceName))
        case 204:
            acknowledge(chunk, job: &job)
            if let server { adopt(server, job: &job) }
        case 409:
            // A server that only takes the next chunk in order: adopt its
            // offset and send this chunk again once it gets there.
            if let server { adopt(server, job: &job) }
            if job.pending.contains(chunk) && !job.parked.contains(chunk) { job.parked.append(chunk) }
        case 404, 410:
            return finish(job, .expired(file: job.filename, space: job.spaceName))
        case 0, 408, 429, 500...:
            job.failures[chunk, default: 0] += 1
            guard job.failures[chunk, default: 0] <= Self.maxFailures else {
                return finish(job, .failed(file: job.filename, space: job.spaceName))
            }
            // Only this chunk is re-created; the other chunks' tasks are
            // untouched.
            sendChunk(chunk, job: &job)
        default:
            return finish(job, .failed(file: job.filename, space: job.spaceName))
        }
        settle(&job)
    }

    private func headed(_ event: UploadEvent, job: inout UploadJob) {
        switch event {
        case .headed(let status, let server?) where (200..<300).contains(status):
            job.failures[Self.headMarker] = nil
            adopt(server, job: &job)
            // Queue every remaining chunk that has no live task.
            let live = Set(job.tasks.values)
            for offset in job.pending where !live.contains(offset) && !job.parked.contains(offset) {
                sendChunk(offset, job: &job)
            }
        case .headed(let status, _) where status == 404 || status == 410:
            return finish(job, .expired(file: job.filename, space: job.spaceName))
        case .headed(let status, _) where status == 0 || status >= 500 || (200..<300).contains(status):
            fallthrough
        case .transportError:
            job.failures[Self.headMarker, default: 0] += 1
            guard job.failures[Self.headMarker, default: 0] <= Self.maxFailures else {
                return finish(job, .failed(file: job.filename, space: job.spaceName))
            }
            sendHead(job: &job)
        default:
            return finish(job, .failed(file: job.filename, space: job.spaceName))
        }
        settle(&job)
    }

    /// The server holds `[0, server)`: every chunk inside it is done.
    private func adopt(_ server: Int64, job: inout UploadJob) {
        job.contiguous = max(job.contiguous, min(server, job.byteSize))
        for offset in job.pending where offset + job.chunkLength(offset) <= job.contiguous {
            acknowledge(offset, job: &job)
        }
    }

    private func acknowledge(_ chunk: Int64, job: inout UploadJob) {
        job.pending.removeAll { $0 == chunk }
        job.parked.removeAll { $0 == chunk }
        job.failures[chunk] = nil
        try? FileManager.default.removeItem(at: store.chunkURL(job.id, offset: chunk))
    }

    /// After a step: re-send a parked chunk the server has reached, finish
    /// when the server has acknowledged every byte, else save.
    private func settle(_ job: inout UploadJob) {
        if job.pending.isEmpty {
            // Every byte is acknowledged but no 200 was seen (its response
            // was lost): a zero-length PATCH at `total` gets the server's
            // 200 and JSON. Sent once; its own retries go through `patched`.
            if !job.tasks.values.contains(job.byteSize) {
                FileManager.default.createFile(atPath: store.chunkURL(job.id, offset: job.byteSize).path, contents: Data())
                sendChunk(job.byteSize, job: &job)
            }
            return store.save(job)
        }
        for offset in job.parked where offset <= job.contiguous {
            job.parked.removeAll { $0 == offset }
            sendChunk(offset, job: &job)
        }
        store.save(job)
    }

    private func finish(_ job: UploadJob, _ notice: UploadNotice) {
        transport.cancel(jobID: job.id, sessionIDs: job.sessionIDs)
        store.remove(job.id)
        notify(notice)
    }

    // MARK: Requests

    private func sendChunk(_ offset: Int64, job: inout UploadJob) {
        var request = URLRequest(url: job.uploadURL)
        request.httpMethod = "PATCH"
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        let key = transport.send(
            request, file: store.chunkURL(job.id, offset: offset), description: "\(job.id)|patch|\(offset)", sessionID: job.sessionID)
        job.tasks[key] = offset
    }

    private func sendHead(job: inout UploadJob) {
        var request = URLRequest(url: job.uploadURL)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let key = transport.send(request, file: nil, description: "\(job.id)|head", sessionID: job.sessionID)
        job.tasks[key] = Self.headMarker
    }

    static func absoluteUploadURL(_ path: String, host: String) -> URL? {
        if path.hasPrefix("https://") { return URL(string: path) }
        return URL(string: "https://\(host)\(path.hasPrefix("/") ? path : "/" + path)")
    }

    static func uploadOffset(_ response: URLResponse?) -> Int64? {
        (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Upload-Offset").flatMap { Int64($0) }
    }

    /// "Sent to #<space>".
    static func sentText(_ spaceName: String) -> String { "Sent to #\(spaceName)" }

    static func sentNotificationRequest(_ spaceName: String, trigger: UNNotificationTrigger? = nil) -> UNNotificationRequest {
        UploadNotice.sent(space: spaceName).request(trigger: trigger)
    }

    // MARK: App relaunch for background events

    private var completionHandlers: [String: () -> Void] = [:]

    /// From `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    func reconnect(sessionID: String, completionHandler: @escaping () -> Void) {
        guard sessionID.hasPrefix(Self.sessionPrefix) else { return completionHandler() }
        DispatchQueue.main.async {
            self.completionHandlers[sessionID] = completionHandler
            (self.transport as? BackgroundSessionTransport)?.attach(sessionID: sessionID)
        }
    }

    fileprivate func sessionFinishedEvents(_ sessionID: String) {
        DispatchQueue.main.async {
            self.completionHandlers.removeValue(forKey: sessionID)?()
        }
    }
}

/// The production transport: one background URLSession per identifier.
final class BackgroundSessionTransport: NSObject, UploadTransport, URLSessionDataDelegate, URLSessionDownloadDelegate {
    private weak var uploader: BackgroundUploader?
    private var sessions: [String: URLSession] = [:]
    private var bodies: [String: Data] = [:]
    private let lock = NSLock()

    init(uploader: BackgroundUploader) {
        self.uploader = uploader
    }

    func attach(sessionID: String) { _ = session(sessionID) }

    private func session(_ id: String) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[id] { return existing }
        let config = URLSessionConfiguration.background(withIdentifier: id)
        config.sharedContainerIdentifier = InstallStore.appGroup
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        let made = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        sessions[id] = made
        return made
    }

    private static func key(_ session: URLSession, _ task: URLSessionTask) -> String {
        "\(session.configuration.identifier ?? "")#\(task.taskIdentifier)"
    }

    func send(_ request: URLRequest, file: URL?, description: String, sessionID: String) -> String {
        let s = session(sessionID)
        // Background sessions run upload and download tasks only, so the
        // HEAD is a download task with an empty body.
        let task: URLSessionTask = file.map { s.uploadTask(with: request, fromFile: $0) } ?? s.downloadTask(with: request)
        task.taskDescription = description
        task.resume()
        return Self.key(s, task)
    }

    func liveTasks(sessionID: String, completion: @escaping ([String: String]) -> Void) {
        let s = session(sessionID)
        s.getAllTasks { tasks in
            var live: [String: String] = [:]
            for task in tasks where task.state == .running || task.state == .suspended {
                live[Self.key(s, task)] = task.taskDescription ?? ""
            }
            completion(live)
        }
    }

    func cancel(jobID: String, sessionIDs: [String]) {
        for id in sessionIDs {
            session(id).getAllTasks { tasks in
                for task in tasks where task.taskDescription?.hasPrefix(jobID + "|") == true { task.cancel() }
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        bodies[Self.key(session, dataTask), default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = Self.key(session, task)
        lock.lock()
        let body = bodies.removeValue(forKey: key) ?? Data()
        lock.unlock()
        guard let description = task.taskDescription else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let offset = BackgroundUploader.uploadOffset(task.response)
        let event: UploadEvent
        if error != nil && status == 0 {
            event = .transportError
        } else if description.hasSuffix("|head") {
            event = .headed(status: status, uploadOffset: offset)
        } else {
            event = .patched(status: status, uploadOffset: offset, body: body)
        }
        uploader?.handle(taskKey: key, description: description, event: event)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        if let id = session.configuration.identifier { uploader?.sessionFinishedEvents(id) }
    }
}
