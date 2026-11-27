import SwiftUI
import WidgetKit

// Home and lock screen widgets (canvas 01a10887, "Widgets"). My tasks and
// the overview are static; My approvals (ApprovalsWidget.swift) is
// interactive. The numeral is SF Pro Heavy; the widget target bundles no
// font (canvas Q5).

struct TasksWidget: Widget {
    var body: some WidgetConfiguration {
        // Kind unchanged (task 01a21e75 stage 3), so a placed widget survives
        // and takes the All installs default.
        AppIntentConfiguration(kind: WidgetKinds.tasks, intent: WidgetScopeIntent.self, provider: CountsProvider()) { entry in
            SingleCountView(kind: .tasks, entry: entry)
        }
        .configurationDisplayName("My tasks")
        .description("Open tasks assigned to you, across your Burrow installs or in one.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKinds.overview, intent: WidgetScopeIntent.self, provider: CountsProvider()) { entry in
            OverviewView(entry: entry)
        }
        .configurationDisplayName("My approvals and tasks")
        .description("Both counts, each opening its own page.")
        .supportedFamilies([.systemMedium, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

// MARK: - Views

struct SingleCountView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let kind: SlabKind
    let entry: CountsEntry
    /// Render tests only: `widgetFamily` cannot be set from outside WidgetKit.
    var family: WidgetFamily?

    var body: some View {
        switch family ?? environmentFamily {
        case .accessoryCircular:
            CircularAccessory(kind: kind, entry: entry)
                .widgetURL(entry.link(kind))
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        case .accessoryInline:
            InlineAccessory(kind: kind, entry: entry)
                .widgetURL(entry.link(kind))
                .containerBackground(.clear, for: .widget)
        default:
            SlabView(kind: kind, entry: entry, compact: true)
                .padding(8)
                .widgetURL(entry.link(kind))
                .containerBackground(BurrowColor.surface.color, for: .widget)
        }
    }
}

struct OverviewView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let entry: CountsEntry
    /// Render tests only: `widgetFamily` cannot be set from outside WidgetKit.
    var family: WidgetFamily?

    var body: some View {
        switch family ?? environmentFamily {
        case .accessoryRectangular:
            RectangularAccessory(entry: entry)
                .widgetURL(entry.link(.approvals))
                .containerBackground(.clear, for: .widget)
        default:
            HStack(spacing: 8) {
                ForEach(SlabKind.allCases, id: \.self) { kind in
                    Link(destination: entry.link(kind)) {
                        SlabView(kind: kind, entry: entry)
                    }
                }
            }
            .padding(8)
            .containerBackground(BurrowColor.surface.color, for: .widget)
        }
    }
}

/// The signature count slab: label top-left, then a slab filling the rest
/// with the numeral bottom-left and a one-line caption. Info (cyan) fill
/// ONLY when `slabState` is `.live`.
struct SlabView: View {
    let kind: SlabKind
    let entry: CountsEntry
    /// The small size: "2 installs" in place of the per-install breakdown.
    var compact = false

    var body: some View {
        let state = entry.state(kind)
        VStack(alignment: .leading, spacing: 0) {
            Text(kind.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(BurrowColor.onSurface.color)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 2) {
                Spacer(minLength: 0)
                if state != .signedOut, let count = entry.count(kind) {
                    Text("\(count)")
                        .font(.system(size: 56, weight: .heavy))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                Text(entry.caption(kind))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if state != .signedOut {
                    InstallDetailLine(entry: entry, kind: kind, compact: compact)
                }
            }
            .foregroundColor(state.usesLiveFill ? BurrowColor.onInfo.color : BurrowColor.onSurface.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .background(
                ContainerRelativeShape()
                    .fill(state.usesLiveFill ? BurrowColor.info.color : BurrowColor.surfaceMuted.color)
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(entry.spokenBreakdown(kind) ?? "")
    }
}

/// The All installs line under a count (canvas 01a21e80 "All installs"): a
/// failure line when an install failed or is signed out, else the pinned
/// marker, else the breakdown ("Alpha 5 · Lab 2"), or "2 installs" when it
/// is compact or the breakdown does not fit. Every variant is dropped WHOLE,
/// never truncated. Secondary type, never error red.
struct InstallDetailLine: View {
    let entry: CountsEntry
    let kind: SlabKind
    var compact = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(candidates.enumerated()), id: \.offset) { _, line in
                line.lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            Color.clear.frame(width: 0, height: 0)
        }
        .font(.system(size: 12))
        .opacity(0.8)
    }

    private var candidates: [Text] {
        let failures = entry.failures
        if !failures.isEmpty {
            let glyph = failures.first?.unreachable == true ? Text(Image(systemName: "icloud.slash")) + Text(" ") : Text("")
            return InstallFailure.line(failures).map { glyph + Text($0) }
        }
        if let pinned = entry.pinnedLabel { return [Text(pinned)] }
        var lines: [Text] = []
        if !compact, let breakdown = entry.breakdown(kind) { lines.append(Text(breakdown)) }
        if let count = entry.installCountLine { lines.append(Text(count)) }
        return lines
    }
}

// Lock-screen accessories are tinted by the system: no brand colour.

struct CircularAccessory: View {
    let kind: SlabKind
    let entry: CountsEntry

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: kind.glyph)
                .font(.system(size: 11, weight: .semibold))
            if entry.state(kind) == .signedOut {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 18, weight: .semibold))
            } else {
                Text(entry.count(kind).map(String.init) ?? "-")
                    .font(.system(size: 22, weight: .heavy))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .accessibilityLabel(accessoryLine(kind, entry))
    }
}

struct RectangularAccessory: View {
    let entry: CountsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !entry.signedIn {
                Text("Burrow").font(.headline)
                Text(SlabKind.approvals.caption(for: .signedOut, fetchedAt: nil))
            } else {
                Text(phrase(.approvals)).font(.headline).monospacedDigit()
                Text(phrase(.tasks)).monospacedDigit()
                if entry.state(.approvals) == .stale {
                    Text(SlabKind.approvals.caption(for: .stale, fetchedAt: entry.counts?.fetchedAt))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func phrase(_ kind: SlabKind) -> String {
        guard let count = entry.count(kind) else { return "- \(kind.noun(plural: true))" }
        return "\(count) \(kind.noun(plural: count != 1))"
    }
}

struct InlineAccessory: View {
    let kind: SlabKind
    let entry: CountsEntry

    var body: some View {
        Text(accessoryLine(kind, entry))
    }
}

/// One sentence for the inline accessory and VoiceOver.
func accessoryLine(_ kind: SlabKind, _ entry: CountsEntry) -> String {
    let state = entry.state(kind)
    switch state {
    case .signedOut:
        return kind.caption(for: .signedOut, fetchedAt: nil)
    case .stale:
        guard let count = entry.count(kind) else { return kind.caption(for: .stale, fetchedAt: nil) }
        return "\(count) \(kind.noun(plural: count != 1)), \(kind.caption(for: .stale, fetchedAt: entry.counts?.fetchedAt).lowercased())"
    case .zero:
        return kind.caption(for: .zero, fetchedAt: nil)
    case .live:
        let count = entry.count(kind) ?? 0
        return "\(count) \(kind.noun(plural: count != 1)) \(kind.caption(for: .live, fetchedAt: nil))"
    }
}

extension SlabKind {
    var glyph: String {
        switch self {
        case .approvals: return "checkmark.seal"
        case .tasks: return "checklist"
        }
    }

    func noun(plural: Bool) -> String {
        switch self {
        case .approvals: return plural ? "approvals" : "approval"
        case .tasks: return plural ? "tasks" : "task"
        }
    }
}
