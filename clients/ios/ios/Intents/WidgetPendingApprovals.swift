import Foundation
import WidgetKit

// Why the widget's approve is sent from the timeline, not from Confirm
// (review of 0774fd1a, case 01a10dbd-ee84-700d step 1).
//
// ConfirmApprovalIntent runs in the widget extension, and WidgetKit does not
// redraw an interactive widget while its intent's `perform` is running: a
// reload asked for inside `perform` is held until `perform` returns. Measured
// on a placed iPad widget with the approve POST slowed by 3 s: the Confirm
// strip stayed up for the whole request and Approving never drew. So Confirm
// only uses up the arm, writes Approving and a pending record, and returns.
// The redraw that follows runs ApprovalsProvider.timeline, which claims the
// record (once, across processes), returns the Approving entry at once, and
// sends the single POST; the result asks for one more redraw.

/// One confirmed approve, waiting to be sent. Ids and times only: never a
/// token, a title or a note.
struct PendingApprove: Codable, Equatable {
    /// `<host>|<uuid>`.
    let id: String
    let confirmedAt: Date
    /// The claim of the one timeline run that sends it. A claimed record is
    /// never claimed again.
    var claim: String?

    /// Older than this with no result, it is Couldn't approve and is never
    /// sent (a confirm must not turn into a send long after the tap).
    static let maxAge: TimeInterval = 60

    func isExpired(at date: Date) -> Bool {
        date.timeIntervalSince(confirmedAt) >= Self.maxAge || date < confirmedAt
    }
}

/// The pending approves, in one JSON file in the App Group container. Every
/// read-modify-write holds an exclusive `flock` on a lock file beside it, so
/// adding and claiming are atomic across the app, the widget extension and
/// concurrent timeline runs in one process (each `open` gets its own lock).
struct PendingApproveStore {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory =
            directory
            ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: InstallStore.appGroup)
            ?? FileManager.default.temporaryDirectory
    }

    private var fileURL: URL { directory.appendingPathComponent("widget-pending-approves.v1.json") }
    private var lockPath: String { directory.appendingPathComponent("widget-pending-approves.v1.lock").path }

    /// Runs `body` on the records under the exclusive lock and writes them
    /// back if `body` changed them.
    @discardableResult
    func update<T>(_ body: (inout [String: PendingApprove]) -> T) -> T {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer {
            if fd >= 0 {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }
        let before = read()
        var records = before
        let result = body(&records)
        if records != before { write(records) }
        return result
    }

    func all() -> [String: PendingApprove] {
        update { $0 }
    }

    private func read() -> [String: PendingApprove] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: PendingApprove].self, from: data)) ?? [:]
    }

    private func write(_ records: [String: PendingApprove]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// A record one timeline run claimed: it, and only it, sends that approve.
struct ClaimedApprove: Equatable {
    let id: String
    let claim: String
}

/// Sends the approves Confirm left pending. Runs in the widget's timeline.
struct WidgetApprovalSender {
    enum SendResult: Equatable {
        case approved
        case alreadyHandled(by: String?)
        case failed
    }

    var client: SuiteAPIClient = .shared
    var installs: InstallStore = .shared
    var store = WidgetApprovalStore()
    var pending = PendingApproveStore()
    var now: () -> Date = Date.init
    var reload: () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.approvals) }

    /// Claims every unclaimed, unexpired pending approve for `host`. Any of
    /// `host`'s records that has expired (claimed or not) becomes Couldn't
    /// approve and is dropped WITHOUT being sent. Another host's records are
    /// left alone: only the widget configured to a host acts for it.
    func claim(host: String) -> [ClaimedApprove] {
        let token = UUID().uuidString
        let at = now()
        let (claimed, expired) = pending.update { records -> ([ClaimedApprove], [String]) in
            var claimed: [ClaimedApprove] = []
            var expired: [String] = []
            for (id, record) in records where EntityRef(id)?.host == host {
                if record.isExpired(at: at) {
                    expired.append(id)
                    records[id] = nil
                } else if record.claim == nil {
                    records[id]?.claim = token
                    claimed.append(ClaimedApprove(id: id, claim: token))
                }
            }
            return (claimed.sorted { $0.id < $1.id }, expired)
        }
        for id in expired { store.mark(id, .failed, now: at) }
        return claimed
    }

    /// The single approve POST for a claimed record, to its own host with
    /// that host's bearer. Writes the result, then drops the record.
    func send(_ claimed: ClaimedApprove) async -> SendResult {
        let result: SendResult
        if let ref = EntityRef(claimed.id), installs.installs.contains(where: { $0.host == ref.host }) {
            do {
                switch try await client.approve(host: ref.host, approvalID: ref.uuid) {
                case .done:
                    IntentLog.route("widget_approve", host: ref.host, status: 200)
                    result = .approved
                case .alreadyHandled(let by):
                    IntentLog.route("widget_approve", host: ref.host, status: 409)
                    result = .alreadyHandled(by: by)
                }
            } catch {
                IntentLog.route("widget_approve", host: ref.host, status: EntityCatalog.status(of: error))
                result = .failed
            }
        } else {
            result = .failed
        }
        switch result {
        case .approved: store.mark(claimed.id, .approved, now: now())
        case .alreadyHandled(let by): store.mark(claimed.id, .alreadyHandled(by: by), now: now())
        case .failed: store.mark(claimed.id, .failed, now: now())
        }
        pending.update { records in
            if records[claimed.id]?.claim == claimed.claim { records[claimed.id] = nil }
        }
        return result
    }

    /// Claims and sends, then asks for the redraw that shows the result.
    /// What a timeline run does, awaited (tests use this directly).
    @discardableResult
    func run(host: String) async -> [SendResult] {
        await send(claim(host: host))
    }

    func send(_ claims: [ClaimedApprove]) async -> [SendResult] {
        guard !claims.isEmpty else { return [] }
        var results: [SendResult] = []
        for claimed in claims { results.append(await send(claimed)) }
        reload()
        return results
    }

    /// The timeline's path: claim now, send WITHOUT holding up the timeline,
    /// so the entry it returns (Approving) is drawn while the request is in
    /// flight. The extension is kept alive for the request; if the system
    /// refuses that, nothing is sent and the record expires to Couldn't
    /// approve.
    func startSending(host: String) {
        let claims = claim(host: host)
        guard !claims.isEmpty else { return }
        let sender = self
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Send a confirmed approval") { expired in
            guard !expired else { return }
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                _ = await sender.send(claims)
                done.signal()
            }
            done.wait()
        }
    }
}
