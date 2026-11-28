import AppIntents
import SwiftUI
import WidgetKit

/// The Voice widget (task 01a21e75 stage 5; device rev 3). Small: one tap
/// talks to the configured agent ("Last used" by default); the whole tile is
/// the button. Medium: the big mic on the left, and up to three recent
/// agents across installs on the right, each a one-tap turn with that
/// agent. iOS 18 runs the turn in the background (StartVoiceTurnIntent); iOS
/// 17 opens Voice already listening (OpenVoiceIntent). Long-pressing to edit
/// the widget is the system's own gesture and cannot be turned off; the tap
/// targets are as large as each size allows.
struct VoiceWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKinds.voice, intent: VoiceWidgetIntent.self, provider: VoiceTileProvider()) { entry in
            VoiceTileView(entry: entry)
        }
        .configurationDisplayName("Voice")
        .description("Talk to an agent in one tap: the one you talked to last, or the one you pick.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct VoiceTileEntry: TimelineEntry {
    let date: Date
    let model: VoiceTileModel
    let partner: String?
    /// The configured agent; nil or `lastUsed` talks to the last partner.
    var agent: VoiceAgentEntity? = nil
    /// The medium size's recent agents.
    var rows: [VoiceRecentRow] = []
}

struct VoiceTileProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> VoiceTileEntry { Self.entry(signedIn: true, partner: nil, install: nil, listening: false) }

    func snapshot(for configuration: VoiceWidgetIntent, in context: Context) async -> VoiceTileEntry {
        Self.current(agent: configuration.agent)
    }

    func timeline(for configuration: VoiceWidgetIntent, in context: Context) async -> Timeline<VoiceTileEntry> {
        let entry = Self.current(agent: configuration.agent)
        // A listening mark goes stale after VoiceTurnStatusStore.validFor.
        let next = entry.model.kind == .listening ? Date().addingTimeInterval(VoiceTurnStatusStore.validFor) : Date().addingTimeInterval(3600)
        return Timeline(entries: [entry], policy: .after(next))
    }

    static func entry(signedIn: Bool, partner: String?, install: String?, listening: Bool) -> VoiceTileEntry {
        VoiceTileEntry(date: Date(), model: .make(signedIn: signedIn, partner: partner, install: install, listening: listening), partner: partner)
    }

    /// From the App Group only: no fetch.
    static func current(agent: VoiceAgentEntity?) -> VoiceTileEntry {
        let installs = InstallStore.shared.installs
        let signedIn = Set(installs.map(\.host).filter { BurrowAPIClient.shared.isSignedIn(host: $0) })
        let target = agent?.choice ?? VoicePartnerCache().partner
        let partner = target.flatMap { signedIn.contains($0.host) ? $0 : nil }
        let install = partner.flatMap { InstallLabel.label(for: $0.host, installs: installs, signedIn: signedIn) }
        var entry = entry(signedIn: !signedIn.isEmpty, partner: partner?.name, install: install, listening: VoiceTurnStatusStore().isListening())
        entry.agent = agent
        entry.rows = VoiceRecentRow.rows(
            VoicePartnerHistory().keep(hosts: signedIn), excluding: partner,
            label: { InstallLabel.label(for: $0, installs: installs, signedIn: signedIn) })
        return entry
    }
}

struct VoiceTileView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let entry: VoiceTileEntry
    /// Render tests only: `widgetFamily` cannot be set from outside WidgetKit.
    var family: WidgetFamily?

    var body: some View {
        Group {
            if entry.model.kind == .signedOut {
                VoiceTileContent(model: entry.model)
                    .widgetURL(URL(string: "\(DeepLink.scheme)://"))
            } else if (family ?? environmentFamily) == .systemMedium {
                HStack(spacing: 0) {
                    micButton.frame(maxWidth: .infinity, maxHeight: .infinity)
                    VoiceRecentList(rows: entry.rows) { row in rowButton(row) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                micButton
            }
        }
        .feedBackground()
    }

    private var micButton: some View {
        start(entry.agent) { VoiceTileContent(model: entry.model) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.model.accessibilityLabel(partner: entry.partner))
            .accessibilityAddTraits(.isButton)
    }

    private func rowButton(_ row: VoiceRecentRow) -> some View {
        start(VoiceAgentEntity(row.partner)) { VoiceRecentRowView(row: row) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.spoken)
            .accessibilityAddTraits(.isButton)
    }

    /// A button that starts a turn with `agent`.
    @ViewBuilder private func start<Label: View>(_ agent: VoiceAgentEntity?, @ViewBuilder label: () -> Label) -> some View {
        if #available(iOS 18, *) {
            Button(intent: StartVoiceTurnIntent(agent: agent), label: label).buttonStyle(.plain)
        } else {
            Button(intent: OpenVoiceIntent(), label: label).buttonStyle(.plain)
        }
    }
}

/// The medium Voice widget's right half: up to three recent agents, as many
/// as fit (3, then 2, then 1), each row a full-width tap target.
struct VoiceRecentList<RowButton: View>: View {
    let rows: [VoiceRecentRow]
    let button: (VoiceRecentRow) -> RowButton

    var body: some View {
        Group {
            if rows.isEmpty {
                Secondary(text: VoiceRecentRow.emptyLine, font: FeedType.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                ViewThatFits(in: .vertical) {
                    list(3)
                    list(2)
                    list(1)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.trailing, 12)
    }

    private func list(_ n: Int) -> some View {
        VStack(spacing: 4) {
            ForEach(rows.prefix(n)) { row in button(row) }
        }
        .frame(maxHeight: .infinity)
    }
}

/// One recent agent: the name, and the install with several installs
/// (dropped whole before the name truncates).
struct VoiceRecentRowView: View {
    let row: VoiceRecentRow

    var body: some View {
        HStack(spacing: 8) {
            // Base-content, not orange: the big mic is the one orange thing.
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BurrowColor.onSurface.color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(BurrowColor.surfaceMuted.color))
            ViewThatFits(in: .horizontal) {
                if let install = row.installLabel {
                    VStack(alignment: .leading, spacing: 0) {
                        name.fixedSize().neverTruncates("voice.row.name.withInstall")
                        Secondary(text: install).lineLimit(1).fixedSize()
                    }
                }
                name.lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .noOverlap("voice.rows", row.id)
    }

    private var name: some View {
        Text(row.partner.name).font(FeedType.rowTitle).foregroundStyle(BurrowColor.onSurface.color).privacySensitive()
    }
}

/// The tile's disc and lines. Public for the render tests.
struct VoiceTileContent: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let model: VoiceTileModel

    var body: some View {
        // "on <install>" is dropped whole first, then the disc shrinks to
        // 44pt, then the title is dropped whole (the tile stays one button,
        // labelled for VoiceOver): the title is never cut (stage 7).
        ViewThatFits(in: .vertical) {
            if let detail = model.detail {
                stack(disc: discSize) {
                    title
                    Text(detail).font(.caption).foregroundStyle(BurrowColor.muted.color).fixedSize()
                }
            }
            stack(disc: discSize) { title }
            stack(disc: CGFloat(VoiceTileModel.minimumDisc)) { title }
            stack(disc: CGFloat(VoiceTileModel.minimumDisc)) { EmptyView() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var title: some View {
        Text(model.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(BurrowColor.onSurface.color)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .neverCut("voice.tile.title")
    }

    private func stack<Lines: View>(disc: CGFloat, @ViewBuilder lines: () -> Lines) -> some View {
        VStack(spacing: 10) {
            VoiceDisc(style: discStyle, glyph: model.kind == .listening ? .send : .mic, size: disc)
            VStack(spacing: 2) { lines() }
        }
        .frame(maxWidth: .infinity)
    }

    private var discSize: CGFloat {
        let size = typeSize.isAccessibilitySize ? min(model.discSize, 52) : model.discSize
        return max(CGFloat(size), CGFloat(VoiceTileModel.minimumDisc))
    }

    private var discStyle: VoiceDisc.Style { model.kind == .signedOut ? .outline(BurrowColor.muted.color) : .filled(BurrowColor.primary.color) }
}

/// The Voice disc: the tile's and the Live Activity's one control.
struct VoiceDisc: View {
    enum Style {
        case filled(Color)
        case outline(Color)
    }

    enum Glyph {
        case mic, send

        var symbol: String { self == .mic ? "mic.fill" : "arrow.up" }
    }

    let style: Style
    let glyph: Glyph
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            switch style {
            case .filled(let color):
                Circle().fill(color)
                Image(systemName: glyph.symbol).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(BurrowColor.onPrimary.color)
            case .outline(let color):
                Circle().strokeBorder(color, lineWidth: 2)
                Image(systemName: glyph.symbol).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
