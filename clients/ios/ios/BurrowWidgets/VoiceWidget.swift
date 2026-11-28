import AppIntents
import SwiftUI
import WidgetKit

/// The Voice tile (task 01a21e75 stage 5; canvas "Voice tile"): one tap
/// talks to the last partner. The whole tile is the button. iOS 18 runs
/// the turn in the background (StartVoiceTurnIntent); iOS 17 opens Voice
/// already listening (OpenVoiceIntent).
struct VoiceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.voice, provider: VoiceTileProvider()) { entry in
            VoiceTileView(entry: entry)
        }
        .configurationDisplayName("Voice")
        .description("Talk to the agent you talked to last.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct VoiceTileEntry: TimelineEntry {
    let date: Date
    let model: VoiceTileModel
    let partner: String?
}

struct VoiceTileProvider: TimelineProvider {
    func placeholder(in context: Context) -> VoiceTileEntry { Self.entry(signedIn: true, partner: nil, install: nil, listening: false) }

    func getSnapshot(in context: Context, completion: @escaping (VoiceTileEntry) -> Void) { completion(Self.current()) }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VoiceTileEntry>) -> Void) {
        let entry = Self.current()
        // A listening mark goes stale after VoiceTurnStatusStore.validFor.
        let next = entry.model.kind == .listening ? Date().addingTimeInterval(VoiceTurnStatusStore.validFor) : Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    static func entry(signedIn: Bool, partner: String?, install: String?, listening: Bool) -> VoiceTileEntry {
        VoiceTileEntry(date: Date(), model: .make(signedIn: signedIn, partner: partner, install: install, listening: listening), partner: partner)
    }

    /// From the App Group only: no fetch.
    static func current() -> VoiceTileEntry {
        let installs = InstallStore.shared.installs
        let signedIn = Set(installs.map(\.host).filter { BurrowAPIClient.shared.isSignedIn(host: $0) })
        let partner = VoicePartnerCache().partner.flatMap { signedIn.contains($0.host) ? $0 : nil }
        let install = partner.flatMap { InstallLabel.label(for: $0.host, installs: installs, signedIn: signedIn) }
        return entry(signedIn: !signedIn.isEmpty, partner: partner?.name, install: install, listening: VoiceTurnStatusStore().isListening())
    }
}

struct VoiceTileView: View {
    let entry: VoiceTileEntry

    var body: some View {
        Group {
            if entry.model.kind == .signedOut {
                VoiceTileContent(model: entry.model)
                    .widgetURL(URL(string: "\(DeepLink.scheme)://"))
            } else if #available(iOS 18, *) {
                Button(intent: StartVoiceTurnIntent()) { VoiceTileContent(model: entry.model) }
                    .buttonStyle(.plain)
            } else {
                Button(intent: OpenVoiceIntent()) { VoiceTileContent(model: entry.model) }
                    .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.model.accessibilityLabel(partner: entry.partner))
        .accessibilityAddTraits(.isButton)
        .feedBackground()
    }
}

/// The tile's disc and lines. Public for the render tests.
struct VoiceTileContent: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let model: VoiceTileModel

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            VoiceDisc(style: discStyle, glyph: model.kind == .listening ? .send : .mic, size: discSize)
            VStack(spacing: 2) {
                Text(model.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BurrowColor.onSurface.color)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.9)
                // "on <install>" is dropped first at large text.
                if let detail = model.detail, !typeSize.isAccessibilitySize {
                    Text(detail).font(.caption).foregroundStyle(BurrowColor.muted.color).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
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
