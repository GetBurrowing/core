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
/// It makes no network request and logs nothing: no title, no body, no
/// ciphertext, no key. A redacted payload (no ids) is delivered as it arrived
/// apart from the badge.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let prepared = PushContentPreparer.live().prepare(request.content)
        // If time runs out during the communication step, deliver the
        // prepared copy: decrypted or the fallback, never the relay's
        // placeholder text.
        bestAttempt = prepared
        contentHandler(CommunicationNotification.build(prepared))
    }

    /// Out of time: deliver the best copy so far.
    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttempt { contentHandler(bestAttempt) }
    }
}
