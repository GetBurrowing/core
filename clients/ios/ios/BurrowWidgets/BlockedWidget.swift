import SwiftUI
import WidgetKit

/// Blocked for you (task 01a21e75 stage 4): blocked tasks the person
/// sponsors or is assigned, in projects they can see. A count, and on the
/// medium size the top two with a short reason, each opening its task.
/// Neutral type, never red or orange: it counts work you can unblock.
struct BlockedWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKinds.blocked, intent: WidgetScopeIntent.self, provider: FeedProvider()) { entry in
            BlockedWidgetView(entry: entry)
        }
        .configurationDisplayName("Blocked for you")
        .description("Blocked tasks you can act on, with why.")
        // Lock Screen too (device rev 4): on the phone Waiting, approvals
        // and tasks were all 0, so every Lock Screen widget read empty
        // while this count was not.
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct BlockedWidgetView: View {
    static let title = "Blocked for you"
    static let empty = "Nothing blocked for you"

    @Environment(\.widgetFamily) private var environmentFamily
    let entry: FeedEntry
    var family: WidgetFamily?

    var body: some View {
        switch family ?? environmentFamily {
        case .accessoryCircular:
            BlockedCircular(entry: entry)
                .widgetURL(entry.link(path: "/tasks"))
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        case .accessoryRectangular:
            BlockedRectangular(entry: entry)
                .widgetURL(entry.blockedRows.first?.link ?? entry.link(path: "/tasks"))
                .containerBackground(.clear, for: .widget)
        case .systemSmall:
            FeedSmallCount(title: Self.title, entry: entry, section: .blocked, empty: Self.empty)
                .padding(16)
                .widgetURL(entry.signedIn ? (entry.blockedRows.first?.link ?? entry.link(path: "/tasks")) : FeedEntry.appURL)
                .feedBackground()
        default:
            BlockedMedium(entry: entry)
                .padding(16)
                .widgetURL(entry.link(path: "/tasks"))
                .feedBackground()
        }
    }
}

struct BlockedMedium: View {
    let entry: FeedEntry

    var body: some View {
        let count = entry.count(.blocked)
        VStack(alignment: .leading, spacing: 6) {
            FeedHeader(
                title: BlockedWidgetView.title, entry: entry, section: .blocked,
                count: entry.signedIn && !entry.notLoaded && count > 0 ? count : nil)
            if !entry.signedIn {
                FeedPlaceholder(text: entry.signInLine)
            } else if entry.notLoaded {
                FeedPlaceholder(text: entry.notLoadedLine)
            } else if count == 0 {
                FeedPlaceholder(text: BlockedWidgetView.empty)
            } else {
                ViewThatFits(in: .vertical) {
                    rows(2)
                    rows(1)
                    Color.clear.frame(height: 0)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func title(_ row: FeedEntry.Blocked) -> some View {
        Text(row.row.title).font(FeedType.rowTitle).foregroundStyle(BurrowColor.onSurface.color).privacySensitive()
    }

    private func rows(_ n: Int) -> some View {
        let failing = !entry.failures.isEmpty && n > 1
        let shown = Array(entry.blockedRows.prefix(failing ? n - 1 : n))
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(shown) { row in
                Link(destination: row.link) {
                    VStack(alignment: .leading, spacing: 0) {
                        // The install label is dropped whole before the title truncates.
                        ViewThatFits(in: .horizontal) {
                            if let label = row.installLabel {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    title(row).fixedSize().neverTruncates("blocked.title.withInstall")
                                    Spacer(minLength: 4)
                                    Secondary(text: label).lineLimit(1).fixedSize()
                                }
                            }
                            title(row).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let reason = row.row.reason {
                            Secondary(text: reason, font: FeedType.summary).lineLimit(1).privacySensitive()
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if failing { FeedFailureLine(failures: entry.failures) }
        }
    }
}

/// Lock Screen circular: the total only, under the blocked mark. Tinted by
/// the system, so no colour.
struct BlockedCircular: View {
    let entry: FeedEntry

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "hand.raised").font(.system(size: 11, weight: .semibold))
            if !entry.signedIn {
                Image(systemName: "person.crop.circle.badge.exclamationmark").font(.system(size: 18, weight: .semibold))
            } else {
                Text(entry.notLoaded ? "-" : "\(entry.count(.blocked))")
                    .font(.system(size: 22, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.signedIn ? "Blocked for you, \(entry.count(.blocked))." : FeedCopy.signIn)
    }
}

/// Lock Screen rectangular: "Blocked · 14" and the top task's title, which
/// is redacted on a locked phone; the title line and count never are.
struct BlockedRectangular: View {
    static let title = "Blocked"
    let entry: FeedEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !entry.signedIn {
                Text(BlockedWidgetView.title).font(.headline)
                Text(entry.signInLine)
            } else {
                HStack(spacing: 0) {
                    Text("\(BlockedWidgetView.title) · ").lineLimit(1)
                    Text("\(entry.count(.blocked))").monospacedDigit().fixedSize().neverTruncates("blocked.rect.count")
                }
                .font(.headline)
                if entry.count(.blocked) == 0 {
                    Text(entry.notLoaded ? entry.notLoadedLine : BlockedWidgetView.empty).lineLimit(1)
                } else if let row = entry.blockedRows.first {
                    Text(row.row.title).lineLimit(1).privacySensitive()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
