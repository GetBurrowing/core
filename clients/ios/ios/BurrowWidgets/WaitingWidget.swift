import SwiftUI
import WidgetKit

/// Waiting on you (task 01a21e75 stage 4): agent messages that tag the
/// person and are unanswered, newest first. One number and at most two
/// rows; each row names who is asking, gives one line of what they need,
/// and opens that thread in its own install. No orange anywhere.
struct WaitingWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKinds.waiting, intent: WidgetScopeIntent.self, provider: FeedProvider()) { entry in
            WaitingWidgetView(entry: entry)
        }
        .configurationDisplayName("Waiting on you")
        .description("Agents waiting for your answer, newest first.")
        .supportedFamilies([.systemMedium, .accessoryCircular, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct WaitingWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let entry: FeedEntry
    /// Render tests only: `widgetFamily` cannot be set from outside WidgetKit.
    var family: WidgetFamily?

    var body: some View {
        switch family ?? environmentFamily {
        case .accessoryCircular:
            WaitingCircular(entry: entry)
                .widgetURL(entry.link(path: "/inbox"))
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        case .accessoryRectangular:
            WaitingRectangular(entry: entry)
                .widgetURL(entry.waitingRows.first?.link ?? entry.link(path: "/inbox"))
                .containerBackground(.clear, for: .widget)
        default:
            WaitingMedium(entry: entry)
                .padding(16)
                .widgetURL(entry.link(path: "/inbox"))
                .feedBackground()
        }
    }
}

struct WaitingMedium: View {
    static let title = "Waiting on you"
    static let empty = "Nothing waiting on you"
    let entry: FeedEntry

    var body: some View {
        let count = entry.count(.waiting)
        VStack(alignment: .leading, spacing: 6) {
            FeedHeader(title: Self.title, entry: entry, section: .waiting, count: entry.signedIn && !entry.notLoaded && count > 0 ? count : nil)
            if !entry.signedIn {
                FeedPlaceholder(text: entry.signInLine)
            } else if entry.notLoaded {
                FeedPlaceholder(text: entry.notLoadedLine)
            } else if count == 0 {
                FeedPlaceholder(text: Self.empty)
            } else {
                // Two rows, then one when two do not fit; the count says the
                // rest, so there is no "+N more".
                ViewThatFits(in: .vertical) {
                    rows(2)
                    rows(1)
                    // Not even one row fits (the largest text sizes): the
                    // header and count alone, never clipped.
                    Color.clear.frame(height: 0)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// `n` rows; a failure line replaces the last one.
    private func rows(_ n: Int) -> some View {
        let failing = !entry.failures.isEmpty && n > 1
        let shown = Array(entry.waitingRows.prefix(failing ? n - 1 : n))
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(shown) { row in
                Link(destination: row.link) { WaitingRowView(row: row, entry: entry) }
            }
            if failing { FeedFailureLine(failures: entry.failures) }
        }
    }
}

struct WaitingRowView: View {
    let row: FeedEntry.Waiting
    let entry: FeedEntry

    private var asker: String { row.row.asker ?? "An agent" }
    private var name: some View {
        Text(asker).font(FeedType.rowTitle).foregroundStyle(BurrowColor.onSurface.color).privacySensitive()
    }

    private var time: String { entry.updatedLine ?? FeedEntry.shortAgo(row.row.date, now: entry.date) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The install label is dropped whole before the name truncates;
            // the time never truncates.
            ViewThatFits(in: .horizontal) {
                if let label = row.installLabel {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        name.fixedSize().neverTruncates("waiting.row.name.withInstall")
                        Spacer(minLength: 4)
                        Secondary(text: "\(label) · \(time)").lineLimit(1).fixedSize()
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    name.lineLimit(1)
                    Spacer(minLength: 4)
                    Secondary(text: time).lineLimit(1).fixedSize().neverTruncates("waiting.row.time")
                }
            }
            Secondary(text: row.row.summary, font: FeedType.summary).lineLimit(1).privacySensitive()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        let install = row.installLabel.map { ", on \($0)" } ?? ""
        let when = row.row.date.map { ", \(CountsEntry.agoSpoken($0, now: entry.date))" } ?? ""
        return "\(asker)\(install)\(when): \(row.row.summary)"
    }
}

/// Lock Screen circular: the total only, under the mention mark.
struct WaitingCircular: View {
    let entry: FeedEntry

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "at").font(.system(size: 11, weight: .semibold))
            if !entry.signedIn {
                Image(systemName: "person.crop.circle.badge.exclamationmark").font(.system(size: 18, weight: .semibold))
            } else {
                Text(entry.notLoaded ? "-" : "\(entry.count(.waiting))")
                    .font(.system(size: 22, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.signedIn ? "Waiting on you, \(entry.count(.waiting))." : FeedCopy.signIn)
    }
}

/// Lock Screen rectangular: "Waiting on you · 7" (pinned "Waiting on you ·
/// Alpha · 7") and the newest row, "Build agent · 4m" ("Build agent · Alpha
/// · 4m" with several installs); the name is redacted on a locked phone.
struct WaitingRectangular: View {
    let entry: FeedEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !entry.signedIn {
                Text(WaitingMedium.title).font(.headline)
                Text(entry.signInLine)
            } else {
                titleLine
                if entry.count(.waiting) == 0 {
                    Text(entry.notLoaded ? entry.notLoadedLine : WaitingMedium.empty).lineLimit(1)
                } else if let row = entry.waitingRows.first {
                    // The install label is dropped whole before the name truncates.
                    ViewThatFits(in: .horizontal) {
                        line(row, withInstall: true).fixedSize()
                        line(row, withInstall: false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Waiting on you · Alpha · 7" when pinned and it fits, else "Waiting
    /// on you · 7": the install is dropped whole, then the title truncates;
    /// the count never does.
    private var titleLine: some View {
        let pinned = entry.pinnedLabel.map { $0.replacingOccurrences(of: " only", with: "") }
        let count = Text("\(entry.count(.waiting))").monospacedDigit().fixedSize().neverTruncates("waiting.rect.count")
        return ViewThatFits(in: .horizontal) {
            if let pinned {
                HStack(spacing: 0) {
                    Text("\(WaitingMedium.title) · \(pinned) · ").fixedSize()
                    count
                }
            }
            HStack(spacing: 0) {
                Text("\(WaitingMedium.title) · ").lineLimit(1)
                count
            }
        }
        .font(.headline)
    }

    private func line(_ row: FeedEntry.Waiting, withInstall: Bool) -> some View {
        let install = withInstall ? row.installLabel.map { " · \($0)" } ?? "" : ""
        return HStack(spacing: 0) {
            Text(row.row.asker ?? "An agent").lineLimit(1).privacySensitive()
            Text("\(install) · \(FeedEntry.shortAgo(row.row.date, now: entry.date))").lineLimit(1).fixedSize()
        }
    }
}
