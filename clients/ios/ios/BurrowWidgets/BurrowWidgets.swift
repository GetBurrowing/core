import SwiftUI
import WidgetKit

// Home and lock screen widgets (canvas 01a10887, "Widgets"). My tasks and
// the overview are static; My approvals (ApprovalsWidget.swift) is
// interactive. The numeral is SF Pro Heavy; the widget target bundles no
// font (canvas Q5).

struct TasksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.kobo-ai.burrow.widgets.tasks", provider: CountsProvider()) { entry in
            SingleCountView(kind: .tasks, entry: entry)
        }
        .configurationDisplayName("My tasks")
        .description("Open tasks assigned to you in the selected Burrow install.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.kobo-ai.burrow.widgets.overview", provider: CountsProvider()) { entry in
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
            SlabView(kind: kind, entry: entry)
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
