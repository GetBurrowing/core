import AppIntents
import SwiftUI
import WidgetKit

// The interactive My approvals widget (task 01a10db6 stage 4; canvas
// 01a10db8 "Layout intent" and "States"). Small and lock-screen families
// render exactly as v1. Medium shows 2 items, large 4 plus See all, and
// iPad extra-large the full count slab beside 4 items with a plan summary.
//
// Colour: Approve is the only primary (orange) in a row; Reject and Cancel
// are a border outline; the header count is `info` (cyan) only when live
// and above zero; failure tone is on the icon only.

struct ApprovalsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKinds.approvals, intent: ApprovalsWidgetIntent.self, provider: ApprovalsProvider()) { entry in
            ApprovalsWidgetView(entry: entry)
        }
        .configurationDisplayName("My approvals")
        .description("Approvals waiting on you in one Burrow install. Approve takes two taps.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryCircular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

enum ApprovalsLayout {
    static let rowSpacing: CGFloat = 8
    static let buttonSpacing: CGFloat = 8
    static let padding: CGFloat = 12

    static func maxRows(_ family: WidgetFamily) -> Int {
        switch family {
        case .systemMedium: return 2
        default: return 4
        }
    }
}

struct ApprovalsWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let entry: ApprovalsEntry
    /// Render tests only: `widgetFamily` cannot be set from outside WidgetKit.
    var family: WidgetFamily?

    var body: some View {
        let family = family ?? environmentFamily
        switch family {
        case .systemSmall, .accessoryCircular, .accessoryInline, .accessoryRectangular:
            SingleCountView(kind: .approvals, entry: entry.countsEntry, family: family)
        case .systemExtraLarge:
            // The full-size count slab on the left third, 4 items right.
            GeometryReader { geometry in
                HStack(spacing: ApprovalsLayout.padding) {
                    Link(destination: entry.inboxURL) {
                        SlabView(kind: .approvals, entry: entry.countsEntry)
                    }
                    .frame(width: (geometry.size.width - ApprovalsLayout.padding) / 3)
                    ApprovalsList(entry: entry, maxRows: 4, showsSummary: true, showsHeader: false)
                }
            }
            .padding(ApprovalsLayout.padding)
            .containerBackground(SuiteColor.surface.color, for: .widget)
        default:
            ApprovalsList(entry: entry, maxRows: ApprovalsLayout.maxRows(family), showsSummary: false, showsHeader: true)
                .padding(ApprovalsLayout.padding)
                .containerBackground(SuiteColor.surface.color, for: .widget)
        }
    }
}

/// Header, rows, and (when there are more) See all.
struct ApprovalsList: View {
    let entry: ApprovalsEntry
    let maxRows: Int
    let showsSummary: Bool
    let showsHeader: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ApprovalsLayout.rowSpacing) {
            if showsHeader { ApprovalsHeader(entry: entry) }
            switch entry.slab {
            case .signedOut, .zero:
                Link(destination: entry.inboxURL) {
                    Text(SlabKind.approvals.caption(for: entry.slab, fetchedAt: nil))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SuiteColor.onSurface.color)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            case .live, .stale:
                ForEach(entry.rows.prefix(maxRows)) { row in
                    ApprovalRowView(entry: entry, row: row, showsSummary: showsSummary)
                }
                if entry.slab == .stale {
                    Text(SlabKind.approvals.caption(for: .stale, fetchedAt: entry.fetchedAt))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SuiteColor.muted.color)
                }
                Spacer(minLength: 0)
                if maxRows > 2, entry.rows.count > maxRows {
                    Link(destination: entry.inboxURL) {
                        HStack {
                            Text("See all \(entry.rows.count)")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SuiteColor.onSurface.color)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Label left; install pill (multi-install only) and the count block right.
struct ApprovalsHeader: View {
    let entry: ApprovalsEntry

    var body: some View {
        HStack(spacing: 8) {
            Text(SlabKind.approvals.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SuiteColor.onSurface.color)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let install = entry.installName {
                Text(install)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SuiteColor.onSurface.color)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(SuiteColor.surfaceMuted.color))
            }
            if entry.slab != .signedOut {
                let live = entry.slab.usesLiveFill
                Text("\(entry.count)")
                    .font(.system(size: 15, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(live ? SuiteColor.onInfo.color : SuiteColor.onSurface.color)
                    .frame(minWidth: 28, minHeight: 24)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(live ? SuiteColor.info.color : SuiteColor.surfaceMuted.color))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ApprovalRowView: View {
    let entry: ApprovalsEntry
    let row: ApprovalsEntry.Row
    let showsSummary: Bool

    var body: some View {
        HStack(spacing: ApprovalsLayout.buttonSpacing) {
            switch row.display {
            case .confirming:
                Text("Approve \(row.approval.title)?")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SuiteColor.onSurface.color)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Confirm makes this prompt out of date until Approving draws.
                    .invalidatableContent()
                Button(intent: ConfirmApprovalIntent(approvalID: row.id)) { Text("Confirm").suiteApproveChrome() }
                    .buttonStyle(.plain)
                Button(intent: CancelArmIntent(approvalID: row.id)) { Text("Cancel").suiteRejectChrome() }
                    .buttonStyle(.plain)
            case .failed:
                Link(destination: entry.taskURL(row)) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(SuiteColor.destructive.color)
                            .accessibilityHidden(true)
                        titleBlock(note: "Couldn't approve. Tap to open.")
                    }
                }
            default:
                Link(destination: entry.taskURL(row)) { titleBlock(note: nil) }
                trailing
            }
        }
        .frame(minHeight: SnippetMetrics.buttonHeight)
    }

    @ViewBuilder private var trailing: some View {
        switch row.display {
        case .live:
            Button(intent: ArmApprovalIntent(approvalID: row.id)) { Text("Approve").suiteApproveChrome() }
                .buttonStyle(.plain)
            // A rejection needs a note: Reject opens the task in the app.
            Link(destination: entry.taskURL(row)) { Text("Reject").suiteRejectChrome() }
        case .approving:
            // A widget cannot animate; a static symbol stands for the spinner.
            status(Image(systemName: "hourglass").foregroundStyle(SuiteColor.onSurface.color), "Approving")
        case .approved:
            status(Image(systemName: "checkmark.circle.fill").foregroundStyle(SuiteColor.onSurface.color), "Approved")
        case .alreadyHandled(let by):
            Text(IntentCopy.alreadyHandled(by: by))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SuiteColor.onSurface.color)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        case .stale, .confirming, .failed:
            // A stale row cannot be acted on: no buttons.
            EmptyView()
        }
    }

    private func status<Icon: View>(_ icon: Icon, _ text: String) -> some View {
        HStack(spacing: 6) {
            icon.accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SuiteColor.onSurface.color)
        }
    }

    private func titleBlock(note: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.approval.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SuiteColor.onSurface.color)
                .lineLimit(1)
            if let note {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(SuiteColor.onSurface.color)
                    .lineLimit(1)
            } else if let space = row.approval.spaceName {
                Text(space)
                    .font(.system(size: 13))
                    .foregroundStyle(SuiteColor.muted.color)
                    .lineLimit(1)
            }
            if showsSummary, note == nil, let summary = row.approval.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(SuiteColor.muted.color)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
