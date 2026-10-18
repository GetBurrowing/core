import XCTest

@testable import App

/// The widget's two-tap confirm (stage 4): Confirm sends only for an arm of
/// that exact row under 8 s old, to the row's own install with its bearer.
final class WidgetApprovalTests: XCTestCase {
    private let a = "a.example.com"
    private let b = "b.example.com"
    private let uuid = "ab000000-0000-4000-8000-000000000001"
    private let other = "ab000000-0000-4000-8000-000000000002"
    private var defaultsName = ""
    private var pendingDirectory = FileManager.default.temporaryDirectory
    private var clock = Date(timeIntervalSince1970: 2_000_000)

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        defaultsName = "WidgetApprovalTests.\(UUID().uuidString)"
        pendingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(defaultsName, isDirectory: true)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: pendingDirectory)
        super.tearDown()
    }

    private var defaults: UserDefaults { UserDefaults(suiteName: defaultsName)! }

    private func actions(hosts: [String] = ["a.example.com", "b.example.com"]) -> WidgetApprovalActions {
        let store = InstallStore(defaults: defaults)
        let removeHook = InstallStore.didRemove
        InstallStore.didRemove = nil
        defer { InstallStore.didRemove = removeHook }
        for host in hosts { store.add(host: host) }
        return WidgetApprovalActions(
            client: SuiteAPIClient(session: StubURLProtocol.session(), tokens: MemoryTokenStore(tokens: [a: "token-for-a", b: "token-for-b"])),
            installs: store, store: WidgetApprovalStore(defaults: defaults), pending: PendingApproveStore(directory: pendingDirectory),
            now: { [unowned self] in self.clock }, reload: {})
    }

    /// What a timeline run uses: the same stores, client and clock as the
    /// Confirm that queued the approve. Each call opens the pending store
    /// afresh, the way a second widget process would.
    private func sender(for actions: WidgetApprovalActions) -> WidgetApprovalSender {
        WidgetApprovalSender(
            client: actions.client, installs: actions.installs, store: actions.store, pending: PendingApproveStore(directory: pendingDirectory),
            now: { [unowned self] in self.clock }, reload: {})
    }

    /// Confirm, then the timeline run the redraw causes: every request the
    /// approve can ever make.
    private func confirmThenTimeline(_ actions: WidgetApprovalActions, _ row: String) async -> WidgetApprovalActions.ConfirmResult {
        let result = actions.confirm(row)
        await sender(for: actions).run(host: EntityRef(row)!.host)
        return result
    }

    private var posts: [URLRequest] { StubURLProtocol.requests.filter { $0.httpMethod == "POST" } }

    private func id(_ host: String, _ uuid: String) -> String { EntityRef(host: host, uuid: uuid).id }

    private func approval(_ uuid: String, title: String = "Burrow iOS intents plan") -> SuiteApproval {
        SuiteApproval(
            id: uuid, kind: "plan", title: title, spaceName: "Burrow iOS", spacePathSegment: nil, taskID: "7a000000-0000-4000-8000-000000000001",
            insertedAt: nil, summary: "Add App Intents")
    }

    // MARK: Confirm sends nothing unless armed for that row, under 8 s

    func testConfirmWithNoArmMakesNoRequest() async {
        let result = await confirmThenTimeline(actions(), id(b, uuid))
        XCTAssertEqual(result, .notArmed)
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }

    func testConfirmAfterTheArmExpiredMakesNoRequest() async {
        let actions = actions()
        actions.arm(id(b, uuid))
        clock = clock.addingTimeInterval(9)
        let result = await confirmThenTimeline(actions, id(b, uuid))
        XCTAssertEqual(result, .notArmed)
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }

    func testConfirmAtExactlyEightSecondsMakesNoRequest() async {
        let actions = actions()
        actions.arm(id(b, uuid))
        clock = clock.addingTimeInterval(WidgetApprovalStore.armWindow)
        let result = await confirmThenTimeline(actions, id(b, uuid))
        XCTAssertEqual(result, .notArmed)
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }

    func testConfirmForADifferentRowMakesNoRequest() async {
        let actions = actions()
        actions.arm(id(b, other))
        clock = clock.addingTimeInterval(2)
        let wrongRow = await confirmThenTimeline(actions, id(b, uuid))
        let wrongHost = await confirmThenTimeline(actions, id(a, other))
        XCTAssertEqual(wrongRow, .notArmed)
        XCTAssertEqual(wrongHost, .notArmed, "the arm names the host too")
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }

    func testCancelledArmMakesNoRequest() async {
        let actions = actions()
        actions.arm(id(b, uuid))
        actions.cancel(id(b, uuid))
        let result = await confirmThenTimeline(actions, id(b, uuid))
        XCTAssertEqual(result, .notArmed)
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }

    /// Install A is used first (the e03cc922 lesson); B's confirm must carry
    /// only B's bearer, exactly once, and a second tap sends nothing.
    func testConfirmWithinEightSecondsPostsOnceToTheRowsHostWithItsBearer() async throws {
        let actions = actions()
        StubURLProtocol.respond = { _ in (200, Data(#"{"approvals":[],"status":"approved"}"#.utf8)) }
        _ = try await actions.client.approvals(host: a)
        let usedA = StubURLProtocol.requests.count

        actions.arm(id(b, uuid))
        clock = clock.addingTimeInterval(7.5)
        let first = actions.confirm(id(b, uuid))
        let second = actions.confirm(id(b, uuid))
        let sentResults = await sender(for: actions).run(host: b)
        let again = await sender(for: actions).run(host: b)

        XCTAssertEqual(first, .queued)
        XCTAssertEqual(second, .notArmed, "the arm is used up by the first confirm")
        XCTAssertEqual(sentResults, [.approved])
        XCTAssertEqual(again, [], "a second timeline run finds nothing to send")
        let sent = Array(StubURLProtocol.requests.dropFirst(usedA))
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.httpMethod, "POST")
        XCTAssertEqual(sent.first?.url?.host, b)
        XCTAssertEqual(sent.first?.url?.path, "/api/app/approvals/\(uuid)/approve")
        XCTAssertEqual(sent.first?.value(forHTTPHeaderField: "Authorization"), "Bearer token-for-b")
        XCTAssertEqual(actions.store.marks()[id(b, uuid)]?.state, .approved)
    }

    func testAnUnknownHostIsNeverSent() async {
        let actions = actions(hosts: [a])
        actions.arm(id(b, uuid))
        let result = await confirmThenTimeline(actions, id(b, uuid))
        XCTAssertEqual(result, .notArmed)
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }

    // MARK: Outcomes and what the row shows

    func testConflictIsAlreadyHandledAndKeepsTheRowUntilTheNextRefresh() async {
        let actions = actions()
        StubURLProtocol.respond = { _ in (409, Data(#"{"error":"already_handled","by":"Alex Rivera"}"#.utf8)) }
        actions.arm(id(b, uuid))
        let result = await confirmThenTimeline(actions, id(b, uuid))
        XCTAssertEqual(result, .queued)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(actions.store.marks()[id(b, uuid)]?.state, .alreadyHandled(by: "Alex Rivera"))

        // The reload right after Confirm: the server no longer lists it.
        let marks = actions.store.marks()
        let merged = ApprovalsCache.merge(fetched: [], previous: [approval(uuid)], host: b, marks: marks, now: clock)
        let cached = CachedApprovals(approvals: merged, fetchedAt: clock)
        let entries = ApprovalsTimeline.entries(now: clock, host: b, installName: nil, signedIn: true, cached: cached, arm: nil, marks: marks)
        XCTAssertEqual(entries.first?.rows.map(\.display), [.alreadyHandled(by: "Alex Rivera")])
        let later = entries.first { $0.date >= clock.addingTimeInterval(WidgetApprovalStore.settledHold) }
        XCTAssertEqual(later?.rows.count, 0, "the row leaves on the next refresh")
        XCTAssertEqual(IntentCopy.alreadyHandled(by: "Alex Rivera"), "Already approved by Alex Rivera.")
    }

    func testFailedPostKeepsTheRowAsFailed() async {
        let actions = actions()
        StubURLProtocol.respond = { _ in (503, Data()) }
        actions.arm(id(b, uuid))
        let result = await confirmThenTimeline(actions, id(b, uuid))
        XCTAssertEqual(result, .queued)
        XCTAssertEqual(actions.store.marks()[id(b, uuid)]?.state, .failed)
        XCTAssertEqual(PendingApproveStore(directory: pendingDirectory).all(), [:], "a failed send is not retried")

        let marks = actions.store.marks()
        let merged = ApprovalsCache.merge(fetched: [approval(uuid)], previous: [approval(uuid)], host: b, marks: marks, now: clock)
        let entry = ApprovalsTimeline.entry(
            at: clock, host: b, installName: nil, signedIn: true, cached: CachedApprovals(approvals: merged, fetchedAt: clock), arm: nil, marks: marks)
        XCTAssertEqual(entry.rows.map(\.display), [.failed])
        XCTAssertEqual(entry.count, 1)
    }

    func testApprovedShowsForOneRefreshThenTheRowLeavesAndTheCountDrops() {
        let store = WidgetApprovalStore(defaults: defaults)
        store.mark(id(b, uuid), .approved, now: clock)
        let cached = CachedApprovals(
            approvals: ApprovalsCache.merge(
                fetched: [approval(other)], previous: [approval(uuid), approval(other)], host: b, marks: store.marks(), now: clock),
            fetchedAt: clock)
        let entries = ApprovalsTimeline.entries(now: clock, host: b, installName: nil, signedIn: true, cached: cached, arm: nil, marks: store.marks())
        XCTAssertEqual(entries.first?.rows.map(\.display), [.approved, .live], "the approved row keeps its place")
        XCTAssertEqual(entries.first?.count, 2)
        let after = entries.first { $0.date == clock.addingTimeInterval(WidgetApprovalStore.settledHold) }
        XCTAssertEqual(after?.rows.map(\.approval.id), [other])
        XCTAssertEqual(after?.count, 1)
    }

    func testTheStripRevertsAtEightSeconds() {
        let arm = WidgetArm(id: id(b, uuid), at: clock)
        let cached = CachedApprovals(approvals: [approval(uuid), approval(other)], fetchedAt: clock)
        let entries = ApprovalsTimeline.entries(
            now: clock.addingTimeInterval(0.5), host: b, installName: nil, signedIn: true, cached: cached, arm: arm, marks: [:])
        XCTAssertEqual(entries.first?.rows.map(\.display), [.confirming, .live], "only the armed row confirms")
        let reverted = entries.first { $0.date == clock.addingTimeInterval(WidgetApprovalStore.armWindow) }
        XCTAssertEqual(reverted?.rows.map(\.display), [.live, .live])
    }

    func testStaleRowsHaveNoButtonsAndTheSlabStopsBeingLive() {
        let cached = CachedApprovals(approvals: [approval(uuid)], fetchedAt: clock)
        let fresh = ApprovalsTimeline.entry(at: clock, host: b, installName: nil, signedIn: true, cached: cached, arm: nil, marks: [:])
        XCTAssertEqual(fresh.slab, .live)
        let old = ApprovalsTimeline.entry(
            at: clock.addingTimeInterval(SlabState.staleAfter + 1), host: b, installName: nil, signedIn: true, cached: cached,
            arm: WidgetArm(id: id(b, uuid), at: clock.addingTimeInterval(SlabState.staleAfter)), marks: [:])
        XCTAssertEqual(old.rows.map(\.display), [.stale], "a stale row cannot even be armed")
        XCTAssertEqual(old.slab, .stale)
        let signedOut = ApprovalsTimeline.entry(at: clock, host: b, installName: nil, signedIn: false, cached: cached, arm: nil, marks: [:])
        XCTAssertEqual(signedOut.slab, .signedOut)
        XCTAssertEqual(signedOut.rows.count, 0)
    }

    func testRejectAndRowTapOpenTheTask() {
        let cached = CachedApprovals(approvals: [approval(uuid)], fetchedAt: clock)
        let entry = ApprovalsTimeline.entry(at: clock, host: b, installName: nil, signedIn: true, cached: cached, arm: nil, marks: [:])
        let row = try? XCTUnwrap(entry.rows.first)
        XCTAssertEqual(row.map(entry.taskURL), DeepLink(host: b, path: "/tasks/7a000000-0000-4000-8000-000000000001").url)
    }

    // MARK: Approving is drawn (review of 5b5c9895, finding 2)

    /// Every App Group write during Confirm is sampled as the widget would
    /// read it. Between Confirming and Approving the row must never read
    /// Live: the Approving mark goes in before the arm comes out.
    func testTheRowNeverReadsLiveBetweenConfirmingAndApproving() async {
        let sampling = SamplingDefaults(suiteName: defaultsName)!
        let row = id(b, uuid)
        let cached = CachedApprovals(approvals: [approval(uuid)], fetchedAt: clock)
        var seen: [ApprovalsEntry.Display] = []
        sampling.onWrite = { [unowned self] in
            let store = WidgetApprovalStore(defaults: sampling)
            let entry = ApprovalsTimeline.entry(
                at: self.clock, host: self.b, installName: nil, signedIn: true, cached: cached, arm: store.armed(now: self.clock), marks: store.marks())
            if let display = entry.rows.first?.display, seen.last != display { seen.append(display) }
        }
        var actions = actions()
        actions.store = WidgetApprovalStore(defaults: sampling)
        StubURLProtocol.respond = { _ in (200, Data(#"{"status":"approved"}"#.utf8)) }

        actions.arm(row)
        clock = clock.addingTimeInterval(1)
        let result = await confirmThenTimeline(actions, row)

        XCTAssertEqual(result, .queued)
        XCTAssertEqual(seen, [.confirming, .approving, .approved])
    }

    /// Review of 0774fd1a: WidgetKit holds any redraw until Confirm's
    /// `perform` returns, so Confirm must return before the network. It makes
    /// no request, leaves Approving and one pending record for that row, and
    /// its redraw reads Approving.
    func testConfirmMakesNoRequestAndLeavesApprovingAndAPendingRecord() {
        let row = id(b, uuid)
        var actions = actions()
        let cached = CachedApprovals(approvals: [approval(uuid)], fetchedAt: clock)
        var redraws: [String] = []
        let store = actions.store
        actions.reload = { [unowned self] in
            let entry = ApprovalsTimeline.entry(
                at: self.clock, host: self.b, installName: nil, signedIn: true, cached: cached, arm: store.armed(now: self.clock), marks: store.marks())
            redraws.append(entry.rows.first.map { "\($0.display)" } ?? "none")
        }

        actions.arm(row)
        clock = clock.addingTimeInterval(2)
        let result = actions.confirm(row)

        XCTAssertEqual(result, .queued)
        XCTAssertEqual(StubURLProtocol.requests.count, 0, "Confirm itself sends nothing")
        XCTAssertEqual(redraws, ["approving"])
        XCTAssertEqual(actions.store.marks()[row]?.state, .approving)
        XCTAssertNil(actions.store.armed(now: clock), "the arm is used up")
        XCTAssertEqual(PendingApproveStore(directory: pendingDirectory).all(), [row: PendingApprove(id: row, confirmedAt: clock, claim: nil)])
    }

    /// The timeline run sends the one POST, then asks for the redraw that
    /// shows the result, and drops the pending record.
    func testTheTimelineSendsThePendingApproveThenRedrawsWithTheResult() async {
        let row = id(b, uuid)
        let actions = actions()
        let lock = NSLock()
        var events: [String] = []
        func log(_ event: String) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }
        StubURLProtocol.respond = { request in
            log("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            return (200, Data(#"{"status":"approved"}"#.utf8))
        }
        var sender = sender(for: actions)
        let store = actions.store
        sender.reload = { log("reload:\(store.marks()[row].map { "\($0.state)" } ?? "none")") }

        actions.arm(row)
        XCTAssertEqual(actions.confirm(row), .queued)
        let results = await sender.run(host: b)

        XCTAssertEqual(results, [.approved])
        XCTAssertEqual(events, ["POST /api/app/approvals/\(uuid)/approve", "reload:approved"])
        XCTAssertEqual(PendingApproveStore(directory: pendingDirectory).all(), [:])
    }

    /// The timeline can run twice at once (two placed widgets, or a reload
    /// landing mid-run) and in different processes: the claim is a
    /// compare-and-set under a file lock, so exactly one POST goes out.
    func testConcurrentTimelineRunsSendExactlyOnePost() async {
        let row = id(b, uuid)
        let actions = actions()
        StubURLProtocol.respond = { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return (200, Data(#"{"status":"approved"}"#.utf8))
        }
        actions.arm(row)
        XCTAssertEqual(actions.confirm(row), .queued)

        let senders = (0..<8).map { _ in sender(for: actions) }
        let results = await withTaskGroup(of: [WidgetApprovalSender.SendResult].self) { group in
            for sender in senders { group.addTask { await sender.run(host: self.b) } }
            var all: [WidgetApprovalSender.SendResult] = []
            for await results in group { all += results }
            return all
        }

        XCTAssertEqual(results, [.approved])
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.value(forHTTPHeaderField: "Authorization"), "Bearer token-for-b")
    }

    /// A confirmed approve that no timeline sent within the window becomes
    /// Couldn't approve and is never sent, claimed or not.
    func testAStalePendingApproveFailsAndIsNeverSent() async {
        let unclaimed = id(b, uuid)
        let claimed = id(b, other)
        let actions = actions()
        actions.arm(unclaimed)
        XCTAssertEqual(actions.confirm(unclaimed), .queued)
        actions.arm(claimed)
        XCTAssertEqual(actions.confirm(claimed), .queued)
        // A run claimed this one, then its process died before sending.
        XCTAssertEqual(
            sender(for: actions).pending.update { records -> Bool in
                records[claimed]?.claim = "dead-run"
                return records[claimed] != nil
            }, true)

        clock = clock.addingTimeInterval(PendingApprove.maxAge)
        let results = await sender(for: actions).run(host: b)

        XCTAssertEqual(results, [])
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
        XCTAssertEqual(actions.store.marks()[unclaimed]?.state, .failed)
        XCTAssertEqual(actions.store.marks()[claimed]?.state, .failed)
        XCTAssertEqual(PendingApproveStore(directory: pendingDirectory).all(), [:])
    }

    /// Only the widget configured to a host sends that host's approves.
    func testAnotherInstallsTimelineDoesNotSendIt() async {
        let row = id(b, uuid)
        let actions = actions()
        actions.arm(row)
        XCTAssertEqual(actions.confirm(row), .queued)
        let results = await sender(for: actions).run(host: a)
        XCTAssertEqual(results, [])
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
        XCTAssertEqual(PendingApproveStore(directory: pendingDirectory).all().keys.sorted(), [row])
    }

    /// With no result inside the window the row reads Couldn't approve; the
    /// scheduled entry shows it even if no timeline runs.
    func testAnApprovingRowWithNoResultReadsFailedAfterTheWindow() {
        let row = id(b, uuid)
        let marks = [row: WidgetRowMark(state: .approving, at: clock)]
        let cached = CachedApprovals(approvals: [approval(uuid)], fetchedAt: clock)
        let entries = ApprovalsTimeline.entries(now: clock, host: b, installName: nil, signedIn: true, cached: cached, arm: nil, marks: marks)
        XCTAssertEqual(entries.first?.rows.map(\.display), [.approving])
        let after = entries.first { $0.date == clock.addingTimeInterval(PendingApprove.maxAge) }
        XCTAssertEqual(after?.rows.map(\.display), [.failed])
    }

    /// The refresh racing the in-flight POST may already miss the row: it
    /// stays, as Approving, until the server answers.
    func testMergeKeepsAnApprovingRowInPlace() {
        let p1 = approval("ab000000-0000-4000-8000-0000000000a1")
        let p2 = approval("ab000000-0000-4000-8000-0000000000a2")
        let marks = [id(b, p1.id): WidgetRowMark(state: .approving, at: clock)]
        let merged = ApprovalsCache.merge(fetched: [p2], previous: [p1, p2], host: b, marks: marks, now: clock)
        XCTAssertEqual(merged.map(\.id), [p1.id, p2.id])
    }

    func testANotArmedConfirmStillRedrawsAndSendsNothing() async {
        var reloads = 0
        var actions = actions()
        actions.reload = { reloads += 1 }
        _ = await confirmThenTimeline(actions, id(b, uuid))
        XCTAssertEqual(reloads, 1, "the strip may have reverted; redraw")
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }

    /// Approved and Already handled rows stay where they were when the
    /// refresh after Confirm no longer lists them.
    func testMergeKeepsASettledRowInItsOriginalPosition() {
        let p1 = approval("ab000000-0000-4000-8000-0000000000a1")
        let p2 = approval("ab000000-0000-4000-8000-0000000000a2")
        let p3 = approval("ab000000-0000-4000-8000-0000000000a3")
        let previous = [p1, p2, p3]
        func merged(settled: SuiteApproval, state: WidgetRowState = .approved) -> [String] {
            let marks = [id(b, settled.id): WidgetRowMark(state: state, at: clock)]
            return ApprovalsCache.merge(fetched: previous.filter { $0 != settled }, previous: previous, host: b, marks: marks, now: clock).map(\.id)
        }
        let order = previous.map(\.id)
        XCTAssertEqual(merged(settled: p1), order, "the top row stays on top")
        XCTAssertEqual(merged(settled: p2), order)
        XCTAssertEqual(merged(settled: p3), order)
        XCTAssertEqual(merged(settled: p1, state: .alreadyHandled(by: "Review User")), order)

        // A new row the server adds keeps the server's place.
        let p4 = approval("ab000000-0000-4000-8000-0000000000a4")
        let marks = [id(b, p1.id): WidgetRowMark(state: .approved, at: clock)]
        let withNew = ApprovalsCache.merge(fetched: [p4, p2, p3], previous: previous, host: b, marks: marks, now: clock).map(\.id)
        XCTAssertEqual(withNew, [p1.id, p4.id, p2.id, p3.id])
    }

    // MARK: Controls

    func testControlCopy() {
        XCTAssertEqual(
            ControlCopy.waiting(signedIn: true, approvals: 3, install: nil), ControlCopy(symbol: "tray.full", label: "Waiting", value: "3 approvals"))
        XCTAssertEqual(ControlCopy.waiting(signedIn: true, approvals: 0, install: nil).value, "Nothing waiting")
        XCTAssertEqual(ControlCopy.waiting(signedIn: true, approvals: 0, install: nil).symbol, "tray")
        XCTAssertEqual(ControlCopy.waiting(signedIn: false, approvals: 3, install: nil).value, "Sign in to Burrow")
        XCTAssertEqual(ControlCopy.waiting(signedIn: true, approvals: 1, install: "Legacy Suite").value, "1 approval, Legacy Suite")
        XCTAssertEqual(
            ControlCopy.startMeeting(lastSpace: "Burrow iOS", install: nil),
            ControlCopy(symbol: "video.badge.plus", label: "Start meeting", value: "in Burrow iOS"))
        XCTAssertEqual(ControlCopy.startMeeting(lastSpace: nil, install: nil).value, "")
    }

    func testStartMeetingRemembersTheSpaceNamePerHost() {
        let spaces = LastMeetingSpaceStore(defaults: defaults)
        spaces.set("s1", name: "Burrow iOS", for: a)
        XCTAssertEqual(spaces.spaceName(for: a), "Burrow iOS")
        XCTAssertNil(spaces.spaceName(for: b))
        spaces.remove(for: a)
        XCTAssertNil(spaces.spaceName(for: a))
    }

    func testOnlyTheIntentsSiriCanReachAreDiscoverable() {
        XCTAssertFalse(ArmApprovalIntent.isDiscoverable)
        XCTAssertFalse(ConfirmApprovalIntent.isDiscoverable)
        XCTAssertFalse(CancelArmIntent.isDiscoverable)
        XCTAssertTrue(ApproveIntent.isDiscoverable)
    }
}

/// UserDefaults that runs `onWrite` after every write, so a test can read
/// the store the way the widget would at each intermediate moment.
final class SamplingDefaults: UserDefaults {
    var onWrite: (() -> Void)?

    override func set(_ value: Any?, forKey defaultName: String) {
        super.set(value, forKey: defaultName)
        onWrite?()
    }

    override func removeObject(forKey defaultName: String) {
        super.removeObject(forKey: defaultName)
        onWrite?()
    }
}
