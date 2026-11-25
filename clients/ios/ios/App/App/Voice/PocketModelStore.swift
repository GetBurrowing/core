import CryptoKit
import Foundation

/// Fetches one file over HTTP, appending to a staging file (task 01a20fdd
/// stage 2). `HTTPRangeFetcher` is the real one; tests inject a fake.
protocol PocketFileFetching: AnyObject, Sendable {
    /// Appends the bytes of `url` from `offset` on to `staging`, creating it
    /// when absent. A server that ignores the range sends the whole file, and
    /// the staging file is then rewritten from zero. `progress` gets the
    /// staging file's total size each time it grows.
    func fetch(_ url: URL, to staging: URL, from offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws
}

/// What the store needs from the Pocket TTS engine: load (and compile) it once
/// the files are in place. `SystemPocketEngine` is the real one.
@MainActor
protocol PocketEngineLoading: AnyObject {
    func load() async throws
}

/// The Pocket TTS model files on this phone: absent until first use, then
/// downloaded from the pinned Hugging Face revisions (PocketTTSManifest),
/// checked, and loaded (task 01a20fdd stage 2).
///
/// - Never bundled in the app binary; fetched on FIRST USE only.
/// - `Library/Application Support/PocketTTS/<revision>/<path>`, excluded from
///   backup. Not Caches: iOS can evict 450 MB of caches mid-use.
/// - Each file lands as `<path>.part` and is moved into place only once its
///   size and SHA-256 match the manifest. A mismatch deletes the part and
///   fails with `checksum`; nothing unverified is ever in place.
/// - An interrupted download resumes from the part's size (HTTP Range).
/// - No auth token: the repos are ungated, so there is no secret to leak.
@MainActor
final class PocketModelStore {
    enum State: Equatable {
        case absent
        case downloading(received: Int64, total: Int64)
        case compiling
        case ready
        case failed(String)

        var name: String {
            switch self {
            case .absent: "absent"
            case .downloading: "downloading"
            case .compiling: "compiling"
            case .ready: "ready"
            case .failed: "failed"
            }
        }
    }

    private(set) var state: State = .absent {
        didSet { if state != oldValue { onChange?(state) } }
    }
    /// Every state change, including each progress step (never backwards).
    var onChange: ((State) -> Void)?

    let root: URL
    let files: [PocketTTSFile]
    let total: Int64
    private let fetcher: any PocketFileFetching
    private let engine: any PocketEngineLoading
    private let urlFor: (PocketTTSFile) -> URL?
    private var job: Task<Void, Never>?

    init(
        root: URL, files: [PocketTTSFile] = PocketTTSManifest.files, fetcher: any PocketFileFetching, engine: any PocketEngineLoading,
        urlFor: @escaping (PocketTTSFile) -> URL? = PocketTTSManifest.url(for:)
    ) {
        self.root = root
        self.files = files
        self.total = files.reduce(Int64(0)) { $0 + Int64($1.size) }
        self.fetcher = fetcher
        self.engine = engine
        self.urlFor = urlFor
        state = allPresent() ? .ready : .absent
    }

    /// `Library/Application Support/PocketTTS`.
    nonisolated static func defaultRoot() -> URL {
        let support =
            (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("PocketTTS", isDirectory: true)
    }

    nonisolated static func directory(for repo: PocketTTSFile.Repo, under root: URL) -> URL {
        root.appendingPathComponent(PocketTTSManifest.revision(of: repo), isDirectory: true)
    }

    func localURL(_ file: PocketTTSFile) -> URL {
        Self.directory(for: file.repo, under: root).appendingPathComponent(file.path)
    }

    /// The model data the page shows: `{state, received, total, reason}`.
    var data: [String: Any] {
        var received: Int64 = 0
        var reason: Any = NSNull()
        switch state {
        case .downloading(let got, _): received = got
        case .compiling, .ready: received = total
        case .failed(let why): reason = why
        case .absent: break
        }
        return ["state": state.name, "received": received, "total": total, "reason": reason]
    }

    /// Starts the download (or only the load, if the files are there).
    /// Idempotent while one is running or the model is ready.
    func prepare() {
        switch state {
        case .downloading, .compiling, .ready: return
        case .absent, .failed: break
        }
        guard job == nil else { return }
        job = Task { [weak self] in
            await self?.run()
            self?.job = nil
        }
    }

    /// Waits for the running download, if any (tests).
    func waitForJob() async { await job?.value }

    /// The last `downloading` figure sent: progress never goes backwards.
    private var reported: Int64 = -1

    private func report(_ received: Int64) {
        guard received > reported else { return }
        reported = received
        state = .downloading(received: received, total: total)
    }

    private func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    private func allPresent() -> Bool {
        files.allSatisfy { size(of: localURL($0)) == Int64($0.size) }
    }

    private func run() async {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            Self.excludeFromBackup(root)
        } catch {
            state = .failed("storage")
            return
        }
        var done: Int64 = 0
        reported = -1
        report(0)
        let begun = Date()
        let missing = files.filter { size(of: localURL($0)) != Int64($0.size) }.reduce(Int64(0)) { $0 + Int64($1.size) }
        VoiceTrace.log("model download start missing_bytes=\(missing) total=\(total)")
        for file in files {
            let local = localURL(file)
            if size(of: local) == Int64(file.size) {
                done += Int64(file.size)
                report(done)
                continue
            }
            guard let url = urlFor(file) else {
                state = .failed("network")
                return
            }
            let staging = local.appendingPathExtension("part")
            do {
                try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                var offset = size(of: staging) ?? 0
                if offset > Int64(file.size) {
                    try? FileManager.default.removeItem(at: staging)
                    offset = 0
                }
                report(done + offset)
                if offset < Int64(file.size) {
                    let base = done
                    let progress = AsyncStream<Int64>.makeStream()
                    let limit = Int64(file.size)
                    let consumer = Task { @MainActor [weak self] in
                        for await have in progress.stream { self?.report(base + min(have, limit)) }
                    }
                    defer { consumer.cancel() }
                    do {
                        try await fetcher.fetch(url, to: staging, from: offset) { progress.continuation.yield($0) }
                        progress.continuation.finish()
                        await consumer.value
                    } catch {
                        progress.continuation.finish()
                        throw error
                    }
                }
            } catch {
                state = .failed("network")
                return
            }
            guard size(of: staging) == Int64(file.size), (try? Self.sha256(of: staging)) == file.sha256 else {
                // Never moved into place: the next attempt starts this file over.
                try? FileManager.default.removeItem(at: staging)
                state = .failed("checksum")
                return
            }
            do {
                try? FileManager.default.removeItem(at: local)
                try FileManager.default.moveItem(at: staging, to: local)
                Self.excludeFromBackup(local)
            } catch {
                state = .failed("storage")
                return
            }
            done += Int64(file.size)
            report(done)
        }
        VoiceTrace.log("model download done ms=\(Int(Date().timeIntervalSince(begun) * 1000))")
        state = .compiling
        let compiling = Date()
        do {
            try await engine.load()
            VoiceTrace.log("model load ms=\(Int(Date().timeIntervalSince(compiling) * 1000)) footprint_mb=\(VoiceTrace.footprintMB())")
            state = .ready
        } catch {
            state = .failed("load")
        }
    }

    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Streaming digest: the largest file is 151 MB.
    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The loader for a voice's store (task 01a20fdd stage 4): a voice is one
/// embedding file, which the engine reads when the voice is first used, so
/// once the file is checked and in place there is nothing to load.
@MainActor
final class PocketVoiceFileLoader: PocketEngineLoading {
    func load() async throws {}
}

enum PocketFetchError: Error {
    case http(Int)
    case noResponse
}

/// HTTP GET with `Range: bytes=<offset>-`, appending to the staging file as
/// bytes arrive, so a download cut off by the network or the app being killed
/// resumes where it stopped. One session per fetch, invalidated after.
final class HTTPRangeFetcher: PocketFileFetching, @unchecked Sendable {
    func fetch(_ url: URL, to staging: URL, from offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let delegate = RangeDownload(staging: staging, offset: offset, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }
}

/// Unchecked: every callback arrives on the session's serial delegate queue.
private final class RangeDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let staging: URL
    let offset: Int64
    let progress: @Sendable (Int64) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var failure: Error?

    init(staging: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.staging = staging
        self.offset = offset
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            failure = PocketFetchError.noResponse
            return completionHandler(.cancel)
        }
        let append = http.statusCode == 206 && offset > 0
        guard append || http.statusCode == 200 else {
            failure = PocketFetchError.http(http.statusCode)
            return completionHandler(.cancel)
        }
        if !append || !FileManager.default.fileExists(atPath: staging.path) {
            FileManager.default.createFile(atPath: staging.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: staging)
            if append {
                written = Int64(try handle.seekToEnd())
            } else {
                try handle.truncate(atOffset: 0)
                written = 0
            }
            self.handle = handle
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            progress(written)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let result: Result<Void, Error> = (failure ?? error).map { .failure($0) } ?? .success(())
        continuation?.resume(with: result)
        continuation = nil
    }
}
