import SwiftUI
import WidgetKit

// Shared pieces of the four feed widgets (task 01a21e75 stage 4; canvas
// 01a21e80 "Type", "Palette", "All installs"). Canvas slots on the app's
// colour sets: base-100 is `surface`, base-content `onSurface`, secondary
// `muted` (6.39:1 light, 7.51:1 dark on `surface`, the canvas ratios), info
// `info`. Type maps to Dynamic Type text styles so it scales. SF, since the
// extension bundles no Public Sans.

enum FeedType {
    /// Headers, 13pt semibold (Footnote).
    static let header = Font.footnote.weight(.semibold)
    /// The count: 34pt small, 28pt medium, semibold, tabular figures.
    static let countSmall = Font.largeTitle.weight(.semibold).monospacedDigit()
    static let countMedium = Font.title.weight(.semibold).monospacedDigit()
    /// Row titles 15pt semibold, summaries 15pt regular (Subheadline).
    static let rowTitle = Font.subheadline.weight(.semibold)
    static let summary = Font.subheadline
    /// Times and install lines, 12pt (Caption 1).
    static let caption = Font.caption
}

enum FeedCopy {
    static let signIn = "Sign in to Burrow"
    static let notLoaded = "Not loaded yet"
}

/// Text in the canvas `secondary` slot.
struct Secondary: View {
    let text: String
    var font: Font = FeedType.caption

    var body: some View {
        Text(text).font(font).foregroundStyle(BurrowColor.muted.color)
    }
}

/// The header's second line: "<install> only" when pinned, else the
/// breakdown ("Alpha 5 · Lab 2 (2h ago)"), else "3 installs" when the
/// breakdown does not fit, else nothing. Dropped WHOLE, never truncated.
struct FeedHeaderDetail: View {
    let entry: FeedEntry
    let section: FeedSection

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if let pinned = entry.pinnedLabel {
                one(pinned)
            } else {
                if let breakdown = entry.breakdown(section) { one(breakdown) }
                if let count = entry.installCountLine { one(count) }
            }
            if let updated = entry.updatedLine { one(updated) }
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private func one(_ text: String) -> some View {
        Secondary(text: text).lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }
}

/// "Can't reach Lab" (cloud-slash glyph) or "Signed out of Lab" (no glyph),
/// two joined by " · " with the second dropped whole when it does not fit.
/// Secondary, never error red.
struct FeedFailureLine: View {
    let failures: [InstallFailure]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(InstallFailure.line(failures).enumerated()), id: \.offset) { _, text in
                HStack(spacing: 4) {
                    if failures.first?.unreachable == true {
                        Image(systemName: "icloud.slash").accessibilityHidden(true)
                    }
                    Text(text).lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            Color.clear.frame(width: 0, height: 0)
        }
        .font(FeedType.caption)
        .foregroundStyle(BurrowColor.muted.color)
    }
}

/// Title (Footnote) on the left, its install line under it, the count on
/// the right; the title truncates before the count, which never does.
struct FeedHeader: View {
    let title: String
    let entry: FeedEntry
    let section: FeedSection
    /// Nil hides the count (the empty state shows none).
    let count: Int?

    var body: some View {
        // Top-aligned, so the 28pt count sits beside the two header lines
        // instead of adding height above them (canvas height budget:
        // header 34 + 2 rows x 40 + gaps within about 126pt).
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(FeedType.header).foregroundStyle(BurrowColor.onSurface.color).lineLimit(1)
                FeedHeaderDetail(entry: entry, section: section)
            }
            .layoutPriority(0)
            Spacer(minLength: 4)
            if let count {
                Text("\(count)").font(FeedType.countMedium).foregroundStyle(BurrowColor.onSurface.color).fixedSize().layoutPriority(1)
                    .padding(.top, -4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        guard let count else { return title }
        var line = "\(title), \(count)"
        if let breakdown = entry.spokenBreakdown(section) { line += ": \(breakdown)" }
        if let pinned = entry.pinnedLabel { line += ", \(pinned)" }
        return line + "."
    }
}

/// One secondary line shown whole or not at all ("2 installs", "Alpha
/// only", "Updated 2h ago"): never truncated (task 01a21e75 stage 7).
struct DropWhole: View {
    let text: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Secondary(text: text).lineLimit(1).fixedSize().neverTruncates("small.line")
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

/// The signed-out and not-loaded lines that replace a widget's content.
struct FeedPlaceholder: View {
    let text: String
    var font: Font = FeedType.summary

    var body: some View {
        Secondary(text: text, font: font)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension View {
    /// The feed widgets' ground.
    func feedBackground() -> some View {
        containerBackground(BurrowColor.surface.color, for: .widget)
    }
}

/// A small feed widget: title, then the count (34pt) at the bottom with
/// one secondary line under it. Blocked for you and Shipped today.
struct FeedSmallCount: View {
    let title: String
    let entry: FeedEntry
    let section: FeedSection
    let empty: String
    /// The secondary line under the count when nothing else claims it
    /// (Shipped today's newest title).
    var detail: String?

    var body: some View {
        let count = entry.count(section)
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(FeedType.header).foregroundStyle(BurrowColor.onSurface.color).lineLimit(2)
            Spacer(minLength: 4)
            if !entry.signedIn {
                Secondary(text: FeedCopy.signIn, font: FeedType.summary).lineLimit(2)
            } else if entry.notLoaded {
                Secondary(text: FeedCopy.notLoaded, font: FeedType.summary).lineLimit(2)
            } else if count == 0 {
                Secondary(text: empty, font: FeedType.summary).lineLimit(3)
            } else {
                Text("\(count)").font(FeedType.countSmall).foregroundStyle(BurrowColor.onSurface.color).lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            line
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    /// Failure line, else pinned marker, else "2 installs", else "Updated
    /// …", else the detail (newest title; hidden when there is no room).
    @ViewBuilder private var line: some View {
        if entry.signedIn {
            if !entry.failures.isEmpty {
                FeedFailureLine(failures: entry.failures)
            } else if let pinned = entry.pinnedLabel {
                DropWhole(text: pinned)
            } else if let installs = entry.installCountLine {
                DropWhole(text: installs)
            } else if let updated = entry.updatedLine {
                DropWhole(text: updated)
            } else if let detail, entry.count(section) > 0 {
                ViewThatFits(in: .vertical) {
                    Secondary(text: detail, font: FeedType.caption).lineLimit(2).privacySensitive()
                    Color.clear.frame(height: 0)
                }
            }
        }
    }
}
