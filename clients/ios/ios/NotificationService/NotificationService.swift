import UserNotifications

/// Burrow's Notification Service Extension.
///
/// Task 01a1261e stage 4: `PushContentPreparer` first. It decrypts a relayed
/// push's sealed preview with this install's key (or writes
/// `New message in <install>`), records the per-install unread count and sets
/// the summed badge. Task 01a111bb stage 4: then, for a chat notification,
/// the message and conversation entities (iOS 27) and the communication
/// notification with the sender's name.
///
/// Task 01a12773 stage 4: the sender's image (`AvatarNotificationDelivery`).
/// The communication notification is built with the in-app letter disc
/// FIRST and kept as the best attempt; then, when the payload names a
/// picture, ONE bounded avatar GET (`AvatarFetcher`: https only, the bearer
/// only to the install's own host, no redirects, 2.5 s total, 256 KB) and a
/// rebuild with it. If time runs out the letter version is delivered. The
/// content handler is called exactly once.
///
/// That GET is the only network request. Nothing is logged: no title, no
/// body, no ciphertext, no key, no url. A redacted payload (no ids) is
/// delivered as it arrived apart from the badge.
final class NotificationService: UNNotificationServiceExtension {
    private var delivery: AvatarNotificationDelivery?
    private let avatars = AvatarFetcher.live()

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let prepared = PushContentPreparer.live().prepare(request.content)
        let avatars = self.avatars
        let delivery = AvatarNotificationDelivery(
            fetch: { url, host in await avatars.fetch(url, installHost: host) },
            deliver: contentHandler)
        self.delivery = delivery
        delivery.start(prepared)
    }

    /// Out of time: deliver the best copy so far (once).
    override func serviceExtensionTimeWillExpire() {
        delivery?.expire()
    }
}
