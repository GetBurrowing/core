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
struct BurrowApproveChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(BurrowColor.onPrimary.color)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minWidth: SnippetMetrics.buttonMinWidth, minHeight: SnippetMetrics.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: BurrowRadius.field, style: .continuous)
                    .fill(BurrowColor.primary.color)
            )
    }
}

/// Reject (and Cancel): a neutral outline (border slot), onSurface label.
/// Never the destructive red: rejecting is a normal choice, not a failure.
struct BurrowRejectChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(BurrowColor.onSurface.color)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minWidth: SnippetMetrics.buttonMinWidth, minHeight: SnippetMetrics.buttonHeight)
            .overlay(
                RoundedRectangle(cornerRadius: BurrowRadius.field, style: .continuous)
                    .stroke(BurrowColor.border.color, lineWidth: 1)
            )
    }
}

extension View {
    func burrowApproveChrome() -> some View { modifier(BurrowApproveChrome()) }
    func burrowRejectChrome() -> some View { modifier(BurrowRejectChrome()) }
}

struct BurrowApproveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.burrowApproveChrome().opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct BurrowRejectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.burrowRejectChrome().opacity(configuration.isPressed ? 0.8 : 1)
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
                    .foregroundStyle(BurrowColor.onSurface.color)
            } else {
                ForEach(Array(summary.rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: row.symbol)
                            .font(.body)
                            .foregroundStyle(BurrowColor.onSurface.color)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(BurrowColor.onSurface.color)
                                .lineLimit(1)
                            if let space = row.space {
                                Text(space)
                                    .font(.footnote)
                                    .foregroundStyle(BurrowColor.muted.color)
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
                        .foregroundStyle(BurrowColor.muted.color)
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
                .foregroundStyle(BurrowColor.muted.color)
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(BurrowColor.onSurface.color)
            if let space, !space.isEmpty {
                Text("in \(space)")
                    .font(.subheadline)
                    .foregroundStyle(BurrowColor.onSurface.color)
            }
            if let install, !install.isEmpty {
                Text("on \(install)")
                    .font(.subheadline)
                    .foregroundStyle(BurrowColor.muted.color)
            }
            Text(consequence)
                .font(.subheadline)
                .foregroundStyle(BurrowColor.onSurface.color)
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
                .foregroundStyle(BurrowColor.onSurface.color)
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .foregroundStyle(BurrowColor.onSurface.color)
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
                    .foregroundStyle(BurrowColor.onSurface.color)
                    .accessibilityHidden(true)
                Text(agent)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(BurrowColor.onSurface.color)
            }
            Text("\u{201C}\(question)\u{201D}")
                .font(.subheadline)
                .foregroundStyle(BurrowColor.muted.color)
                .lineLimit(1)
            switch state {
            case .working:
                HStack(spacing: 8) {
                    ProgressView()
                    Text(IntentCopy.agentWorking(agent: agent))
                        .font(.subheadline)
                        .foregroundStyle(BurrowColor.onSurface.color)
                }
            case .reply(let text):
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(BurrowColor.onSurface.color)
                    .fixedSize(horizontal: false, vertical: true)
            case .timedOut:
                Text(IntentCopy.agentTimedOutSnippet(agent: agent))
                    .font(.subheadline)
                    .foregroundStyle(BurrowColor.onSurface.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(SnippetMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
