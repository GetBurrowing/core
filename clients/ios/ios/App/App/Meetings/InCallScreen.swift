import Combine
import SwiftUI

/// The in-call screen bound to the app's one call (`CallController.shared`):
/// the clock, the 3 s notes, and the controls' actions. The drawing is
/// `InCallView`, which renders without a call in the render tests.
struct InCallScreen: View {
    @ObservedObject var controller: CallController
    @ObservedObject var waiting: RingWaiting = .shared
    @State private var now = Date()
    @State private var note: String?
    @State private var noteClear: DispatchWorkItem?

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        InCallView(
            model: InCallModel.make(state: controller.state, elapsed: controller.state.elapsed(at: now)),
            ended: ended,
            note: note,
            actions: InCallActions(
                toggleMute: { controller.setMuted(!controller.state.isMuted) },
                leave: { controller.leave() },
                resume: { controller.resume() },
                tryAgain: { controller.tryAgain() },
                openFullMeeting: { controller.openFullMeeting() },
                openSpace: { controller.openSpace() },
                done: { controller.dismissEnded() }
            )
        )
        .overlay(alignment: .top) {
            if let invite = waiting.current {
                RingBanner(invite: invite, notNow: { waiting.notNow() }, switchCall: { waiting.switchToInvite() })
                    .padding(.horizontal, InCallStyle.gutter)
                    .padding(.top, 8)
                    .frame(maxWidth: BurrowLayout.sheetWidth)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: waiting.current)
        .onReceive(clock) { now = $0 }
        .onChange(of: controller.state.route) { old, new in
            // "Audio moved to {route}" when the route changes mid-call,
            // never for the first route.
            if old != nil, let new, old != new { show(InCallCopy.routeMoved(new)) }
        }
        .onChange(of: controller.state.micPausedSince) { old, new in
            if old != nil, new == nil { show(InCallCopy.siriPaused) }
        }
    }

    private var ended: EndedModel? {
        guard case .ended(let reason) = controller.state.phase else { return nil }
        return EndedModel.make(reason: reason, elapsed: controller.endedElapsed)
    }

    private func show(_ text: String) {
        noteClear?.cancel()
        note = text
        let clear = DispatchWorkItem { note = nil }
        noteClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: clear)
    }
}
