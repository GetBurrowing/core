import Foundation
import UIKit

/// The in-call invite banner (canvas "Burrow iOS v2: native meetings",
/// busy callee): a second ring never puts the current call on hold, it
/// shows this. One soft haptic, no ring; after 30 s it becomes a missed
/// invite.
@MainActor
final class RingWaiting: ObservableObject {
    static let shared = RingWaiting()

    /// How long the banner stays before the invite counts as missed.
    static let timeout: TimeInterval = 30

    @Published private(set) var current: RingInvite?
    /// The simulator's in-app incoming ring (see
    /// `RingCenter.systemEndsIncomingCalls`): the call UUID it answers.
    @Published private(set) var incoming: (invite: RingInvite, uuid: UUID)?

    var haptic: () -> Void = { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    /// Brings the in-call screen up so the banner is seen.
    var reveal: () -> Void = { CallController.shared.reopen() }
    var schedule: (_ after: TimeInterval, _ work: @escaping () -> Void) -> (() -> Void) = { after, work in
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: item)
        return { item.cancel() }
    }
    var onNotNow: (RingInvite) -> Void = { RingCenter.shared.declineWaiting($0) }
    var onSwitch: (RingInvite) -> Void = { RingCenter.shared.switchTo($0) }
    var onMissed: (RingInvite) -> Void = { RingCenter.shared.missWaiting($0) }
    var onAnswerIncoming: (UUID) -> Void = { uuid in RingCenter.shared.answer(uuid) { _ in } }
    var onDeclineIncoming: (UUID) -> Void = { RingCenter.shared.decline($0) }

    private var cancelTimeout: (() -> Void)?

    func show(_ invite: RingInvite) {
        guard current?.ringID != invite.ringID else { return }
        if let previous = current { onMissed(previous) }
        cancelTimeout?()
        current = invite
        haptic()
        reveal()
        cancelTimeout = schedule(Self.timeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.current?.ringID == invite.ringID else { return }
                self.current = nil
                self.onMissed(invite)
            }
        }
    }

    // MARK: In-app incoming ring (simulator degrade)

    /// RingCenter owns this ring's timeout; the prompt only shows it.
    func showIncoming(_ invite: RingInvite, uuid: UUID) {
        incoming = (invite, uuid)
        haptic()
    }

    func clearIncoming(ringID: String) {
        if incoming?.invite.ringID == ringID { incoming = nil }
    }

    func answerIncoming() {
        guard let uuid = incoming?.uuid else { return }
        incoming = nil
        onAnswerIncoming(uuid)
    }

    func declineIncoming() {
        guard let uuid = incoming?.uuid else { return }
        incoming = nil
        onDeclineIncoming(uuid)
    }

    func notNow() {
        guard let invite = take() else { return }
        onNotNow(invite)
    }

    func switchToInvite() {
        guard let invite = take() else { return }
        onSwitch(invite)
    }

    private func take() -> RingInvite? {
        cancelTimeout?()
        cancelTimeout = nil
        defer { current = nil }
        return current
    }
}
