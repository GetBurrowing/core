import Foundation

/// The summary "What's waiting" speaks and shows.
struct WaitingSummary: Equatable {
    struct Row: Equatable {
        enum Kind: Equatable { case plan, review, task }
        let kind: Kind
        let title: String
        let space: String?
        /// The approval's entity id, for the row's Approve and Reject.
        let approvalID: String?

        var symbol: String {
            switch kind {
            case .plan, .review: return "checkmark.seal"
            case .task: return "checklist"
            }
        }
    }

    static let maxRows = 3

    let approvals: Int
    let tasks: Int
    let rows: [Row]
    let more: Int

    var isEmpty: Bool { approvals + tasks == 0 }

    var dialog: String {
        IntentCopy.waiting(approvals: approvals, tasks: tasks, firstTitle: rows.first?.title)
    }

    init(approvals: [(id: String, approval: SuiteApproval)], tasks: [SuiteTask]) {
        let all =
            approvals.map { item in
                Row(kind: item.approval.isPlan ? .plan : .review, title: item.approval.title, space: item.approval.spaceName, approvalID: item.id)
            } + tasks.map { Row(kind: .task, title: $0.title, space: $0.projectName, approvalID: nil) }
        self.approvals = approvals.count
        self.tasks = tasks.count
        rows = Array(all.prefix(Self.maxRows))
        more = max(0, all.count - Self.maxRows)
    }
}
