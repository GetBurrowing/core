import SwiftUI

// Siri and Shortcuts snippets (canvas 01a10db8, Layout intent and Palette
// deltas). They sit on the system card's own material: no background of
// their own, base-content (`onSurface`) text, no primary-coloured text.
// Primary appears only as the Approve fill, behind an `onPrimary` label.
// Type is the system font (the iOS rule for snippets). No App Intents types
// here, so the views render in ExtensionRenderTests.

enum SnippetMetrics {
    static let padding: CGFloat = 16
    static let rowHeight: CGFloat = 44
    static let buttonHeight: CGFloat = 40
    static let buttonMinWidth: CGFloat = 72
}

/// Approve: primary fill, onPrimary label, field radius, at least 72 x
/// 40 pt. The only primary colour in a row.
struct SuiteApproveChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(SuiteColor.onPrimary.color)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minWidth: SnippetMetrics.buttonMinWidth, minHeight: SnippetMetrics.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: SuiteRadius.field, style: .continuous)
                    .fill(SuiteColor.primary.color)
            )
    }
}

/// Reject (and Cancel): a neutral outline (border slot), onSurface label.
/// Never the destructive red: rejecting is a normal choice, not a failure.
struct SuiteRejectChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(SuiteColor.onSurface.color)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minWidth: SnippetMetrics.buttonMinWidth, minHeight: SnippetMetrics.buttonHeight)
            .overlay(
                RoundedRectangle(cornerRadius: SuiteRadius.field, style: .continuous)
                    .stroke(SuiteColor.border.color, lineWidth: 1)
            )
    }
}

extension View {
    func suiteApproveChrome() -> some View { modifier(SuiteApproveChrome()) }
    func suiteRejectChrome() -> some View { modifier(SuiteRejectChrome()) }
}

struct SuiteApproveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.suiteApproveChrome().opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SuiteRejectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.suiteRejectChrome().opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// "What's waiting": up to three rows (symbol, title, space), then "And N
/// more". Approval rows carry the caller's Approve and Reject buttons.
struct WaitingSnippetView<Actions: View>: View {
    let summary: WaitingSummary
    let actions: (WaitingSummary.Row) -> Actions

    init(summary: WaitingSummary, @ViewBuilder actions: @escaping (WaitingSummary.Row) -> Actions) {
        self.summary = summary
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if summary.isEmpty {
                Text(IntentCopy.nothingWaiting)
                    .font(.body)
                    .foregroundStyle(SuiteColor.onSurface.color)
            } else {
                ForEach(Array(summary.rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: row.symbol)
                            .font(.body)
                            .foregroundStyle(SuiteColor.onSurface.color)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(SuiteColor.onSurface.color)
                                .lineLimit(1)
                            if let space = row.space {
                                Text(space)
                                    .font(.footnote)
                                    .foregroundStyle(SuiteColor.muted.color)
                                    .lineLimit(1)
                            }
                            // Under the title, so a snippet-width row never
                            // truncates the title to make room for buttons.
                            actions(row)
                                .padding(.top, 4)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: SnippetMetrics.rowHeight)
                }
                if summary.more > 0 {
                    Text(IntentCopy.andMore(summary.more))
                        .font(.footnote)
                        .foregroundStyle(SuiteColor.muted.color)
                }
            }
        }
        .padding(SnippetMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension WaitingSnippetView where Actions == EmptyView {
    init(summary: WaitingSummary) {
        self.init(summary: summary) { _ in EmptyView() }
    }
}

/// Above the system Confirm and Cancel: the item, its space, the
/// consequence, and the install when more than one is saved.
struct ConfirmSnippetView: View {
    let heading: String
    let title: String
    let space: String?
    let install: String?
    let consequence: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(SuiteColor.muted.color)
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(SuiteColor.onSurface.color)
            if let space, !space.isEmpty {
                Text("in \(space)")
                    .font(.subheadline)
                    .foregroundStyle(SuiteColor.onSurface.color)
            }
            if let install, !install.isEmpty {
                Text("on \(install)")
                    .font(.subheadline)
                    .foregroundStyle(SuiteColor.muted.color)
            }
            Text(consequence)
                .font(.subheadline)
                .foregroundStyle(SuiteColor.onSurface.color)
                .padding(.top, 4)
        }
        .padding(SnippetMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func approve(isPlan: Bool, title: String, space: String?, install: String?) -> ConfirmSnippetView {
        ConfirmSnippetView(
            heading: isPlan ? "Approve this plan?" : "Approve this review?", title: title, space: space, install: install,
            consequence: isPlan ? "Agents start building as soon as you approve." : "The agent carries on as soon as you approve.")
    }

    static func reject(isPlan: Bool, title: String, space: String?, install: String?) -> ConfirmSnippetView {
        ConfirmSnippetView(
            heading: isPlan ? "Reject this plan?" : "Reject this review?", title: title, space: space, install: install,
            consequence: "It goes back to the agent with your note.")
    }

    static func send(message: String, space: String, install: String?) -> ConfirmSnippetView {
        ConfirmSnippetView(heading: "Send to \(space)?", title: message, space: nil, install: install, consequence: "")
    }
}

/// A one-line result: checkmark plus words ("Sent to {Space}.").
struct DoneSnippetView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(SuiteColor.onSurface.color)
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .foregroundStyle(SuiteColor.onSurface.color)
        }
        .padding(SnippetMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Ask an agent: agent name, the question echoed on one line, then the
/// reply, a spinner while working, or the timed-out note.
struct AskAgentSnippetView: View {
    enum State: Equatable {
        case working
        case reply(String)
        case timedOut
    }

    let agent: String
    let question: String
    let state: State

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .foregroundStyle(SuiteColor.onSurface.color)
                    .accessibilityHidden(true)
                Text(agent)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(SuiteColor.onSurface.color)
            }
            Text("\u{201C}\(question)\u{201D}")
                .font(.subheadline)
                .foregroundStyle(SuiteColor.muted.color)
                .lineLimit(1)
            switch state {
            case .working:
                HStack(spacing: 8) {
                    ProgressView()
                    Text(IntentCopy.agentWorking(agent: agent))
                        .font(.subheadline)
                        .foregroundStyle(SuiteColor.onSurface.color)
                }
            case .reply(let text):
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(SuiteColor.onSurface.color)
                    .fixedSize(horizontal: false, vertical: true)
            case .timedOut:
                Text(IntentCopy.agentTimedOutSnippet(agent: agent))
                    .font(.subheadline)
                    .foregroundStyle(SuiteColor.onSurface.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(SnippetMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
