import AppIntents
import Foundation
import WidgetKit

// The approvals widget's buttons (task 01a10db6 stage 4). WidgetKit cannot
// present `requestConfirmation`, so the widget's two-tap confirm strip IS
// the confirmation, enforced here: Confirm queues an approve only for an arm
// of that exact `<host>|<id>` made under 8 s ago, and otherwise queues
// nothing; the widget's timeline sends what was queued (WidgetPendingApprovals
// .swift explains why the send is not in Confirm). None
// of these is discoverable: Siri and Shortcuts can only reach ApproveIntent,
// which asks `requestConfirmation`.

/// The work behind the widget buttons, testable without WidgetKit.
struct WidgetApprovalActions {
    enum ConfirmResult: Equatable {
        /// No arm for this row inside the window: nothing was queued.
        case notArmed
        /// Approving is written and the approve is pending: the widget's
        /// next timeline run sends it (WidgetApprovalSender).
        case queued
    }

    var client: SuiteAPIClient = .shared
    var installs: InstallStore = .shared
    var store = WidgetApprovalStore()
    var pending = PendingApproveStore()
    var now: () -> Date = Date.init
    /// Asks WidgetKit to redraw the approvals widget. WidgetKit holds it
    /// until `perform` returns, which is why Confirm sends nothing itself.
    var reload: () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.approvals) }

    func arm(_ id: String) {
        guard EntityRef(id) != nil else { return }
        store.arm(id, now: now())
    }

    func cancel(_ id: String) {
        if store.armed(now: now())?.id == id { store.disarm() }
    }

    /// Only if the row was armed under 8 s ago: uses the arm up, writes
    /// Approving (before the arm goes, so the row is never Live in between)
    /// and a pending record for that exact `<host>|<id>`, all under the
    /// pending store's lock, so two taps cannot both pass. Makes NO network
    /// request: returning lets WidgetKit redraw, and that redraw's timeline
    /// sends the one POST while Approving is on screen.
    func confirm(_ id: String) -> ConfirmResult {
        defer { reload() }
        guard let ref = EntityRef(id), installs.installs.contains(where: { $0.host == ref.host }) else { return .notArmed }
        let at = now()
        let queued = pending.update { records -> Bool in
            guard records[id] == nil, store.takeArmMarkingApproving(for: id, now: at) else { return false }
            records[id] = PendingApprove(id: id, confirmedAt: at, claim: nil)
            return true
        }
        return queued ? .queued : .notArmed
    }
}

/// First tap: the row becomes "Approve {title}?" with Confirm and Cancel.
struct ArmApprovalIntent: AppIntent {
    static var title: LocalizedStringResource = "Arm Approval"
    static var isDiscoverable = false

    @Parameter(title: "Approval")
    var approvalID: String

    init() {}

    init(approvalID: String) { self.approvalID = approvalID }

    func perform() async throws -> some IntentResult {
        WidgetApprovalActions().arm(approvalID)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.approvals)
        return .result()
    }
}

/// Second tap, on the strip: approves, if and only if armed.
struct ConfirmApprovalIntent: AppIntent {
    static var title: LocalizedStringResource = "Confirm Approval"
    static var isDiscoverable = false

    @Parameter(title: "Approval")
    var approvalID: String

    init() {}

    init(approvalID: String) { self.approvalID = approvalID }

    /// Returns without any network call, so WidgetKit redraws with
    /// Approving; the timeline that redraw runs sends the approve.
    func perform() async throws -> some IntentResult {
        _ = WidgetApprovalActions().confirm(approvalID)
        return .result()
    }
}

struct CancelArmIntent: AppIntent {
    static var title: LocalizedStringResource = "Cancel Approval"
    static var isDiscoverable = false

    @Parameter(title: "Approval")
    var approvalID: String

    init() {}

    init(approvalID: String) { self.approvalID = approvalID }

    func perform() async throws -> some IntentResult {
        WidgetApprovalActions().cancel(approvalID)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.approvals)
        return .result()
    }
}

/// The What's waiting control: opens the approvals list of the selected
/// install. Not discoverable; Shortcuts has Show My Approvals.
@available(iOS 18, *)
struct OpenWaitingIntent: AppIntent {
    static var title: LocalizedStringResource = "Open What's Waiting"
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult & OpensIntent {
        let installs = InstallStore.shared
        guard let host = installs.selectedHost else {
            return .result(opensIntent: OpenURLIntent(URL(string: "\(DeepLink.scheme)://\(DeepLink.action)")!))
        }
        return .result(opensIntent: OpenURLIntent(DeepLink(host: host, path: SlabKind.approvals.path).url))
    }
}
