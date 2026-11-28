import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The Voice turn's Live Activity (task 01a21e75 stage 5; canvas "Live
/// Activity", "Dynamic Island"): the Lock Screen, and the Dynamic Island
/// compact, minimal and expanded. The Dynamic Island is ALWAYS drawn in the
/// dark values on black.
@available(iOS 18, *)
struct VoiceLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceActivityAttributes.self) { context in
            VoiceLockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(BurrowColor.surface.color)
                .widgetURL(context.state.link(host: context.attributes.host).url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VoicePartnerMarker(name: context.attributes.partnerName, ringing: context.state.phase == .speaking)
                        .environment(\.colorScheme, .dark)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VoiceIslandCaption(attributes: context.attributes, state: context.state)
                        .environment(\.colorScheme, .dark)
                }
                DynamicIslandExpandedRegion(.center) {
                    VoiceTranscriptLine(state: context.state, partner: context.attributes.partnerName, lines: 1)
                        .environment(\.colorScheme, .dark)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VoiceControlsRow(attributes: context.attributes, state: context.state)
                        .environment(\.colorScheme, .dark)
                }
            } compactLeading: {
                VoiceIslandGlyph(attributes: context.attributes, state: context.state).environment(\.colorScheme, .dark)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                VoiceIslandGlyph(attributes: context.attributes, state: context.state).environment(\.colorScheme, .dark)
            }
            .widgetURL(context.state.link(host: context.attributes.host).url)
        }
    }
}

/// The Lock Screen: the header (partner marker, partner, install), the
/// caption, the transcript or the newest reply sentence, then Cancel on
/// the left and the disc on the right. VoiceOver reads them in that order.
@available(iOS 18, *)
struct VoiceLockScreenView: View {
    let attributes: VoiceActivityAttributes
    let state: VoiceActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VoicePartnerMarker(name: attributes.partnerName, ringing: state.phase == .speaking)
                VoicePartnerLine(attributes: attributes)
                Spacer(minLength: 4)
                VoiceCaption(state: state)
            }
            VoiceTranscriptLine(state: state, partner: attributes.partnerName, lines: 2)
            VoiceControlsRow(attributes: attributes, state: state)
        }
        .padding(16)
    }
}

/// "<partner> · <install>": the install truncates first, the partner never.
struct VoicePartnerLine: View {
    let attributes: VoiceActivityAttributes

    var body: some View {
        HStack(spacing: 0) {
            Text(attributes.partnerName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BurrowColor.onSurface.color)
                .lineLimit(1)
                .layoutPriority(2)
            if let install = attributes.installLabel, !install.isEmpty {
                Text(" · \(install)")
                    .font(.subheadline)
                    .foregroundStyle(BurrowColor.muted.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The partner marker: a dot, ringed while the reply is spoken.
struct VoicePartnerMarker: View {
    let name: String
    let ringing: Bool

    var body: some View {
        ZStack {
            Circle().fill(BurrowColor.onSurface.color).frame(width: 10, height: 10)
            if ringing { Circle().strokeBorder(BurrowColor.info.color, lineWidth: 2).frame(width: 20, height: 20) }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// The phase caption. "Not sent" in the error colour. Never truncates.
struct VoiceCaption: View {
    let state: VoiceActivityState

    var body: some View {
        if !state.caption.isEmpty {
            Text(state.caption)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(state.phase == .notSent ? BurrowColor.destructive.color : BurrowColor.muted.color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// The expanded island's trailing caption, with the install, which is
/// dropped first.
@available(iOS 18, *)
struct VoiceIslandCaption: View {
    let attributes: VoiceActivityAttributes
    let state: VoiceActivityState

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                VoiceCaption(state: state)
                if let install = attributes.installLabel, !install.isEmpty {
                    Text(install).font(.footnote).foregroundStyle(BurrowColor.muted.color).lineLimit(1).fixedSize()
                }
            }
            VoiceCaption(state: state)
        }
    }
}

/// The transcript (secondary while forming, base-content once sent), or the
/// newest reply sentence. The reply is privacy-sensitive: on a locked phone
/// it reads "<partner> replied" (the sponsor's question is open; that is
/// the default until answered).
struct VoiceTranscriptLine: View {
    @Environment(\.redactionReasons) private var redaction
    let state: VoiceActivityState
    let partner: String
    let lines: Int

    var body: some View {
        if let reply = state.replySentence, [.speaking, .finished, .ended].contains(state.phase) {
            Group {
                if redaction.contains(.privacy) {
                    Text("\(partner) replied")
                } else {
                    Text(reply).privacySensitive()
                }
            }
            .font(.subheadline)
            .foregroundStyle(BurrowColor.onSurface.color)
            .lineLimit(lines)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !state.transcriptTail.isEmpty {
            Text(state.transcriptTail)
                .font(.subheadline)
                .foregroundStyle(state.phase == .listening ? BurrowColor.muted.color : BurrowColor.onSurface.color)
                .lineLimit(1)
                .truncationMode(.head)
                .privacySensitive()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Cancel on the left (base-content text) and the disc on the right. No
/// buttons once the turn is over.
@available(iOS 18, *)
struct VoiceControlsRow: View {
    let attributes: VoiceActivityAttributes
    let state: VoiceActivityState
    var discSize: CGFloat = 44

    var body: some View {
        if !state.phase.isOver {
            HStack {
                if VoiceActivityButtons.showsCancel(state.phase) {
                    Button(intent: CancelVoiceTurnIntent()) {
                        Text("Cancel").font(.subheadline.weight(.semibold)).foregroundStyle(BurrowColor.onSurface.color).fixedSize()
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 8)
                trailing
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        let name = attributes.partnerName
        switch VoiceActivityButtons.disc(state.phase) {
        case .send:
            Button(intent: SendVoiceTurnIntent()) { VoiceDisc(style: .filled(BurrowColor.primary.color), glyph: .send, size: discSize) }
                .buttonStyle(.plain)
                .accessibilityLabel("Send to \(name)")
        case .retry:
            Button(intent: SendVoiceTurnIntent()) {
                Text("Retry").font(.subheadline.weight(.semibold)).foregroundStyle(BurrowColor.onSurface.color).fixedSize()
            }
            .buttonStyle(.plain)
        case .inactiveFilled:
            VoiceDisc(style: .filled(BurrowColor.muted.color), glyph: .send, size: discSize)
        case .inactiveOutline:
            VoiceDisc(style: .outline(BurrowColor.muted.color), glyph: .mic, size: discSize)
        case .talkOutline:
            Button(intent: StartVoiceTurnIntent()) { VoiceDisc(style: .outline(BurrowColor.onSurface.color), glyph: .mic, size: discSize) }
                .buttonStyle(.plain)
                .accessibilityLabel("Talk to \(name)")
        case .talkFilled:
            Button(intent: StartVoiceTurnIntent()) { VoiceDisc(style: .filled(BurrowColor.primary.color), glyph: .mic, size: discSize) }
                .buttonStyle(.plain)
                .accessibilityLabel("Talk to \(name)")
        case .none:
            EmptyView()
        }
    }
}

/// The compact and minimal glyph: the mic in primary while listening, the
/// ringed partner marker while speaking, else the mic in secondary.
@available(iOS 18, *)
struct VoiceIslandGlyph: View {
    let attributes: VoiceActivityAttributes
    let state: VoiceActivityState

    var body: some View {
        switch state.phase {
        case .speaking:
            VoicePartnerMarker(name: attributes.partnerName, ringing: true)
        case .listening:
            Image(systemName: "mic.fill").foregroundStyle(BurrowColor.primary.color).accessibilityLabel("Listening")
        default:
            Image(systemName: "mic.fill").foregroundStyle(BurrowColor.muted.color).accessibilityLabel(state.caption)
        }
    }
}
