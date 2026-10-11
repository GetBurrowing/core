import Foundation
import UserNotifications

/// The Notification Service Extension's delivery order for a chat push
/// (task 01a12773 stage 4), in Shared so the app's tests drive the same code
/// the extension runs:
///
/// 1. Build the communication notification with the LETTER fallback first
///    and keep it as `bestAttempt`: already a proper communication
///    notification, so running out of time still shows the sender properly.
/// 2. Only if the payload names a picture: fetch it (bounded by
///    `AvatarFetcher`, 2.5 s) and rebuild with it.
/// 3. `expire()` (from `serviceExtensionTimeWillExpire`) delivers
///    `bestAttempt`.
///
/// `deliver` runs EXACTLY ONCE, whichever of the fetch and the expiry
/// finishes first; the other is dropped.
final class AvatarNotificationDelivery {
    private let lock = NSLock()
    private var delivered = false
    private let deliver: (UNNotificationContent) -> Void
    private let fetch: (URL, String) async -> Data?
    private(set) var bestAttempt: UNNotificationContent?

    init(fetch: @escaping (URL, String) async -> Data?, deliver: @escaping (UNNotificationContent) -> Void) {
        self.fetch = fetch
        self.deliver = deliver
    }

    /// Starts delivery of `prepared` (the output of `PushContentPreparer`).
    func start(_ prepared: UNNotificationContent) {
        let fallback = CommunicationNotification.build(prepared)
        bestAttempt = fallback
        guard let payload = CommunicationPayload(userInfo: prepared.userInfo), let url = payload.avatarURL else {
            finish(fallback)
            return
        }
        Task {
            let picture = await fetch(url, payload.host)
            finish(picture == nil ? fallback : CommunicationNotification.build(prepared, picture: picture))
        }
    }

    /// Out of time: deliver the best copy so far, unless already delivered.
    func expire() {
        if let bestAttempt { finish(bestAttempt) }
    }

    private func finish(_ content: UNNotificationContent) {
        lock.lock()
        let first = !delivered
        delivered = true
        lock.unlock()
        if first { deliver(content) }
    }
}
