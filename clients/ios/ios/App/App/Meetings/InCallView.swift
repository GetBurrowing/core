import AVKit
import SwiftUI
import UIKit

/// The native in-call screen (task 01a10db7 stage 4), drawn to the design
/// canvas 01a11166 "Burrow iOS v2: native meetings".
///
/// Every colour is a `BurrowColor` slot. Canvas -> iOS slot mapping:
///   base-100 -> surface, base-content -> onSurface, base-content/60 ->
///   muted, base-200 -> surfaceMuted, edge -> border, the canvas's cyan
///   "primary" (speaking ring, Resume / Try again fills) -> info + onInfo
///   (iOS `primary` is orange), error -> destructive as an ICON only.
/// Deviation: the canvas puts "answering" in a third accent distinct from
/// cyan; iOS has no such slot, so it is onSurface semibold, no colour.
///
/// Always dark: `InCallHostingController` forces `.dark` in both system
/// themes, because this screen sits beside the dark system call UI.
enum InCallStyle {
    /// The speaking ring. Cyan marks live call state.
    static let ring: BurrowColor = .info
    static let ringWidth: CGFloat = 2
    static let rowHeight: CGFloat = 64
    static let avatar: CGFloat = 40
    static let tile: CGFloat = 64
    static let gutter: CGFloat = 16
    static let dimmedOpacity: Double = 0.6
    /// Avatars, row glyphs and the control tiles stop growing here; names,
    /// the title and the status keep scaling.
    static let fixedGeometryCap: DynamicTypeSize = .xxxLarge
}

extension BurrowFont {
    /// Call title: Public Sans 800, 22 pt.
    static func callTitle() -> Font { .custom(family, size: 22, relativeTo: .title2).weight(.heavy) }
}

/// What the screen's controls do. Closures, so the view renders without a
/// call (render tests) and the app wires them to `CallController`.
struct InCallActions {
    var toggleMute: () -> Void = {}
    var leave: () -> Void = {}
    var resume: () -> Void = {}
    var tryAgain: () -> Void = {}
    var openFullMeeting: () -> Void = {}
    var openSpace: () -> Void = {}
    var done: () -> Void = {}
}

struct InCallView: View {
    let model: InCallModel
    var ended: EndedModel?
    /// A 3 s one-liner: "Audio moved to {route}" or "Mic was paused for Siri".
    var note: String?
    var actions = InCallActions()
    /// The Audio tile's route picker. Off in render tests, which cannot draw it.
    var showsRoutePicker = true

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if let ended {
                EndedView(model: ended, actions: actions)
            } else {
                call
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BurrowColor.surface.color.ignoresSafeArea())
    }

    private var regular: Bool { sizeClass == .regular }

    private var call: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, InCallStyle.gutter)
                .padding(.top, InCallStyle.gutter)
                .padding(.bottom, 8)
            Rectangle().fill(BurrowColor.border.color).frame(height: 1)
            ScrollView {
                participantLists
                    .opacity(model.dimsList ? InCallStyle.dimmedOpacity : 1)
                    .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity)
            if let alone = model.aloneText {
                Text(alone)
                    .font(BurrowFont.body())
                    .foregroundStyle(BurrowColor.muted.color)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 16)
                    .accessibilityIdentifier("incall-alone")
            }
            bottom
                .padding(.horizontal, InCallStyle.gutter)
                .padding(.bottom, InCallStyle.gutter)
        }
        .frame(maxWidth: regular ? BurrowLayout.sheetWidth : .infinity)
        .frame(maxWidth: .infinity)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.title)
                .font(BurrowFont.callTitle())
                .foregroundStyle(BurrowColor.onSurface.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("incall-title")
            HStack(spacing: 6) {
                if model.statusKind == .connecting || model.statusKind == .reconnecting {
                    ProgressView().controlSize(.mini).tint(BurrowColor.muted.color)
                }
                if model.statusKind == .poorConnection {
                    Image(systemName: "wifi.exclamationmark")
                        .font(BurrowFont.caption())
                        .foregroundStyle(BurrowColor.onSurface.color)
                }
                Text(model.status)
                    .font(BurrowFont.caption())
                    .monospacedDigit()
                    .foregroundStyle(model.statusKind == .poorConnection ? BurrowColor.onSurface.color : BurrowColor.muted.color)
                    .accessibilityIdentifier("incall-status")
            }
            if let note = model.mutedByHostNote ?? note {
                Text(note)
                    .font(BurrowFont.caption())
                    .foregroundStyle(BurrowColor.muted.color)
                    .accessibilityIdentifier("incall-note")
            }
        }
    }

    // MARK: Lists

    @ViewBuilder private var participantLists: some View {
        if regular {
            HStack(alignment: .top, spacing: InCallStyle.gutter) {
                section(InCallCopy.agentsHeader, model.agents).frame(maxWidth: .infinity, alignment: .top)
                section(InCallCopy.peopleHeader, model.people).frame(maxWidth: .infinity, alignment: .top)
            }
            .padding(.horizontal, InCallStyle.gutter)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !model.agents.isEmpty { section(InCallCopy.agentsHeader, model.agents) }
                section(InCallCopy.peopleHeader, model.people)
            }
            .padding(.horizontal, InCallStyle.gutter)
        }
    }

    private func section(_ title: String, _ rows: [InCallModel.Row]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(BurrowFont.caption(.semibold))
                .foregroundStyle(BurrowColor.muted.color)
                .padding(.vertical, 8)
            ForEach(rows) { row in
                ParticipantRow(row: row)
            }
        }
    }

    // MARK: Bottom: recovery, link, tiles

    private var bottom: some View {
        VStack(spacing: 16) {
            if model.lostConnection {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(BurrowColor.destructive.color)
                    Text(InCallCopy.lostConnection)
                        .font(BurrowFont.body())
                        .foregroundStyle(BurrowColor.onSurface.color)
                    Spacer(minLength: 0)
                }
                .accessibilityIdentifier("incall-lost-connection")
            }
            if let recovery = model.recovery {
                Button(action: recovery == .resume ? actions.resume : actions.tryAgain) {
                    Text(recovery == .resume ? InCallCopy.resume : InCallCopy.tryAgain)
                        .font(BurrowFont.body(.semibold))
                        .foregroundStyle(BurrowColor.onInfo.color)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(BurrowColor.info.color, in: RoundedRectangle(cornerRadius: BurrowRadius.field, style: .continuous))
                }
                .accessibilityIdentifier("incall-recovery")
            }
            Button(action: actions.openFullMeeting) {
                HStack(spacing: 4) {
                    Text(InCallCopy.openFullMeeting)
                    Image(systemName: "chevron.right")
                }
                .font(BurrowFont.body())
                .foregroundStyle(BurrowColor.onSurface.color)
                .frame(minHeight: 44)
            }
            .accessibilityIdentifier("incall-open-full")
            HStack(spacing: 0) {
                ControlTile(
                    glyph: model.isMuted ? "mic.slash.fill" : "mic.fill",
                    label: model.isMuted ? InCallCopy.muted : InCallCopy.mute,
                    inverted: model.isMuted, glyphColor: nil, action: actions.toggleMute
                )
                .accessibilityIdentifier("incall-mute")
                .frame(maxWidth: .infinity)
                AudioTile(routeName: model.routeName, showsPicker: showsRoutePicker)
                    .frame(maxWidth: .infinity)
                ControlTile(
                    glyph: "phone.down.fill", label: InCallCopy.leave, inverted: false,
                    glyphColor: BurrowColor.destructive, action: actions.leave
                )
                .accessibilityIdentifier("incall-leave")
                .frame(maxWidth: .infinity)
            }
            .dynamicTypeSize(...InCallStyle.fixedGeometryCap)
        }
    }
}

// MARK: - Row

struct ParticipantRow: View {
    let row: InCallModel.Row
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Wrapped names grow the row downward; the avatar and mic stay on
        // the first line (top-aligned at accessibility sizes).
        HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
            Avatar(initial: row.initial, isSpeaking: row.isSpeaking)
                // Fixed geometry stops growing at xxxLarge; the name keeps
                // scaling and wraps instead.
                .dynamicTypeSize(...InCallStyle.fixedGeometryCap)
            nameBlock
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            // Its own fixed column: a long name at AX5 wraps beside it and
            // never runs under it.
            Image(systemName: row.isMuted ? "mic.slash" : "mic")
                .font(BurrowFont.body())
                .foregroundStyle(BurrowColor.muted.color)
                .dynamicTypeSize(...InCallStyle.fixedGeometryCap)
                .frame(minWidth: 28)
                .fixedSize()
                .accessibilityIdentifier("incall-row-mic")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(minHeight: InCallStyle.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: BurrowRadius.field, style: .continuous)
                .fill(row.isSpeaking ? BurrowColor.surfaceMuted.color : BurrowColor.surface.color)
        )
        .accessibilityElement(children: .combine)
    }

    private var name: some View {
        Text(row.name)
            .font(BurrowFont.body(.semibold))
            .foregroundStyle(BurrowColor.onSurface.color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("incall-row-name")
    }

    @ViewBuilder private var tag: some View {
        if row.isAgent {
            Text(InCallCopy.agentTag)
                .font(BurrowFont.caption())
                .foregroundStyle(BurrowColor.muted.color)
        }
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Accessibility sizes: the Agent tag gets its own line rather
            // than squeezing the name.
            if typeSize.isAccessibilitySize {
                name
                tag
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    name
                    tag
                }
            }
            if let answering = row.answering {
                Text(answering)
                    .font(BurrowFont.caption(.semibold))
                    .foregroundStyle(BurrowColor.onSurface.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("incall-answering")
            }
        }
    }
}

/// 40 pt at the default size; the speaking ring sits on it.
struct Avatar: View {
    let initial: String
    let isSpeaking: Bool
    @ScaledMetric(relativeTo: .body) private var size = InCallStyle.avatar

    var body: some View {
        ZStack {
            Circle().fill(BurrowColor.surfaceMuted.color)
            Text(initial)
                .font(BurrowFont.body(.semibold))
                .foregroundStyle(BurrowColor.onSurface.color)
        }
        .frame(width: size, height: size)
        .overlay {
            if isSpeaking {
                Circle()
                    .strokeBorder(InCallStyle.ring.color, lineWidth: InCallStyle.ringWidth)
                    .accessibilityIdentifier("incall-ring")
            }
        }
    }
}

// MARK: - Tiles

struct ControlTile: View {
    let glyph: String
    let label: String
    /// Muted: an onSurface fill with a surface glyph.
    let inverted: Bool
    let glyphColor: BurrowColor?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: glyph)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle((glyphColor ?? (inverted ? .surface : .onSurface)).color)
                    .frame(width: InCallStyle.tile, height: InCallStyle.tile)
                    .background(
                        (inverted ? BurrowColor.onSurface : BurrowColor.surfaceMuted).color,
                        in: RoundedRectangle(cornerRadius: BurrowRadius.field, style: .continuous))
                Text(label)
                    .font(BurrowFont.caption())
                    .foregroundStyle(BurrowColor.onSurface.color)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

/// The Audio tile: the system route picker under a tile whose glyph and
/// label follow the current route.
struct AudioTile: View {
    let routeName: String?
    let showsPicker: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: BurrowRadius.field, style: .continuous)
                    .fill(BurrowColor.surfaceMuted.color)
                Image(systemName: Self.glyph(for: routeName))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(BurrowColor.onSurface.color)
                if showsPicker {
                    RoutePicker().opacity(0.02)
                }
            }
            .frame(width: InCallStyle.tile, height: InCallStyle.tile)
            Text(routeName ?? InCallCopy.audio)
                .font(BurrowFont.caption())
                .foregroundStyle(BurrowColor.onSurface.color)
                .lineLimit(1)
                .accessibilityIdentifier("incall-audio-label")
        }
    }

    static func glyph(for route: String?) -> String {
        let name = route?.lowercased() ?? ""
        if name.contains("airpods") || name.contains("headphone") || name.contains("bluetooth") { return "airpods" }
        if name.contains("speaker") { return "speaker.wave.2.fill" }
        if name.contains("iphone") || name.contains("receiver") { return "iphone" }
        return "speaker.wave.2.fill"
    }
}

private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Ended

struct EndedView: View {
    let model: EndedModel
    let actions: InCallActions

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(model.title)
                .font(BurrowFont.callTitle())
                .foregroundStyle(BurrowColor.onSurface.color)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("incall-ended-title")
            if let duration = model.duration {
                Text(duration)
                    .font(BurrowFont.caption())
                    .monospacedDigit()
                    .foregroundStyle(BurrowColor.muted.color)
            }
            if model.showsOpenSpace {
                Button(action: actions.openSpace) {
                    HStack(spacing: 4) {
                        Text(InCallCopy.openSpace)
                        Image(systemName: "chevron.right")
                    }
                    .font(BurrowFont.body())
                    .foregroundStyle(BurrowColor.onSurface.color)
                    .frame(minHeight: 44)
                }
            }
            Spacer()
            Button(action: actions.done) {
                Text(InCallCopy.done)
                    .font(BurrowFont.body(.semibold))
                    .foregroundStyle(BurrowColor.onSurface.color)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(BurrowColor.surfaceMuted.color, in: RoundedRectangle(cornerRadius: BurrowRadius.field, style: .continuous))
            }
            .accessibilityIdentifier("incall-done")
        }
        .padding(InCallStyle.gutter)
        .frame(maxWidth: BurrowLayout.sheetWidth)
    }
}

// MARK: - Host

/// Hosts the in-call screen, forced dark in both system themes.
final class InCallHostingController<Content: View>: UIHostingController<Content> {
    override init(rootView: Content) {
        super.init(rootView: rootView)
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = BurrowColor.surface.uiColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}
