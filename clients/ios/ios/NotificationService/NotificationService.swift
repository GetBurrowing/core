import UserNotifications

/// Burrow's Notification Service Extension (task 01a111bb stage 4). For a
/// chat notification it names the message and conversation entities
/// (iOS 27) and makes it a communication notification with the sender's
/// name. It makes no network request and logs nothing: no title, no body.
/// A redacted payload (no ids) is delivered exactly as it arrived.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        original = request.content
        contentHandler(CommunicationNotification.build(request.content))
    }

    /// Out of time: deliver what arrived.
    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let original { contentHandler(original) }
    }
}
