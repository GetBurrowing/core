import SwiftUI
import WidgetKit

/// Recent (task 01a21e75 stage 4): the four most active conversations, with
/// unread dots, each opening that space in its own install. No header, so
/// the space goes to a fourth row.
struct RecentWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKinds.recent, intent: WidgetScopeIntent.self, provider: FeedProvider()) { entry in
            RecentWidgetView(entry: entry)
        }
        .configurationDisplayName("Recent")
        .description("Your most active conversations, with unread dots.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

struct RecentWidgetView: View {
    static let empty = "No conversations yet"
    let entry: FeedEntry
    var family: WidgetFamily?

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(entry.link(path: "/"))
            .feedBackground()
    }

    @ViewBuilder private var content: some View {
        if !entry.signedIn {
            FeedPlaceholder(text: entry.signInLine)
        } else if entry.notLoaded {
            FeedPlaceholder(text: entry.notLoadedLine)
        } else if entry.recentRows.isEmpty {
            FeedPlaceholder(text: Self.empty)
        } else {
            // 4 rows, then 3, then 2 when they do not fit.
            ViewThatFits(in: .vertical) {
                rows(4)
                rows(3)
                rows(2)
                rows(1)
            }
        }
    }

    /// `n` lines: rows, with the last replaced by the failure line, the
    /// pinned marker ("Alpha only") or "Updated 2h ago" when one applies.
    private func rows(_ n: Int) -> some View {
        let footer: AnyView? =
            !entry.failures.isEmpty
            ? AnyView(FeedFailureLine(failures: entry.failures))
            : entry.pinnedLabel.map { AnyView(Secondary(text: $0).lineLimit(1)) } ?? entry.updatedLine.map { AnyView(Secondary(text: $0).lineLimit(1)) }
        let shown = Array(entry.recentRows.prefix(footer == nil ? n : n - 1))
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(shown) { row in
                Link(destination: row.link) { RecentRowView(row: row) }.staysInside("recent.row.\(row.id)")
            }
            if let footer { footer.frame(minHeight: 24, alignment: .leading) }
        }
    }
}

struct RecentRowView: View {
    let row: FeedEntry.Recent

    var body: some View {
        HStack(spacing: 8) {
            mark
            // The install label is dropped whole before the name truncates.
            ViewThatFits(in: .horizontal) {
                if let label = row.installLabel {
                    HStack(spacing: 8) {
                        name.fixedSize().neverTruncates("recent.name.withInstall")
                        Spacer(minLength: 4)
                        Secondary(text: label).lineLimit(1).fixedSize()
                    }
                }
                HStack(spacing: 8) {
                    name.lineLimit(1)
                    Spacer(minLength: 4)
                }
            }
            Circle()
                .fill(row.row.unread ? BurrowColor.info.color : Color.clear)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        }
        // At least 24pt, and taller at large text, so the list's
        // ViewThatFits drops rows instead of overlapping them.
        .frame(minHeight: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var name: some View {
        Text(row.row.name).font(FeedType.rowTitle).foregroundStyle(BurrowColor.onSurface.color).privacySensitive()
            .noOverlap("recent.names", "\(row.id)")
    }

    /// A 20pt mark: # for a channel, a person or agent glyph for a DM.
    private var mark: some View {
        Image(systemName: glyph)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(BurrowColor.onSurface.color)
            .frame(width: 20, height: 20)
            .background(Circle().fill(BurrowColor.surfaceMuted.color))
            .accessibilityHidden(true)
    }

    private var glyph: String {
        switch (row.row.kind, row.row.counterpart?.type) {
        case ("channel", _): return "number"
        case ("group", _): return "person.2.fill"
        case (_, "agent"): return "sparkles"
        default: return "person.fill"
        }
    }

    /// "Agents, on Alpha, unread": unread is never the dot alone.
    private var spoken: String {
        var parts = [row.row.name]
        if let label = row.installLabel { parts.append("on \(label)") }
        if row.row.unread { parts.append("unread") }
        return parts.joined(separator: ", ")
    }
}
