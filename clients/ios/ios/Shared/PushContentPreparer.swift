import CryptoKit
import Foundation
import UserNotifications

/// What the Notification Service Extension does to every push BEFORE the
/// communication-notification step (task 01a1261e stage 4). Compiled into
/// the app too so it is unit-tested there. No network, no logging: never a
/// title, a body, a blob or a key.
///
/// 1. A relayed push (it carries no `kind`; the relay sends only
///    `install_host`, `unread_count`, `unread_as_of` and `sealed`): open
///    `sealed` with that install's key and rebuild the notification from the
///    inner data map (title, body, category, thread, routing keys). If it is
///    missing or does not open, the body reads `New message in <install>`:
///    never ciphertext, never blank.
/// 2. Any push carrying `unread_count` / `unread_as_of` (relayed or direct)
///    updates `InstallUnreadStore`, and the badge becomes the SUM over
///    installs.
/// 3. With more than one install signed in, the install's name becomes the
///    subtitle. (iOS draws the app name in the header and offers no API to
///    append to it, so the canvas's `BURROW . Acme` header is a subtitle.)
///    A chat push becomes a communication notification, which draws no
///    subtitle, so the name also goes in `userInfo[installLabelKey]` for
///    `CommunicationNotification`'s conversation name.
struct PushContentPreparer {
    var privateKey: (String) -> Curve25519.KeyAgreement.PrivateKey?
    var unread: InstallUnreadStore
    var installs: () -> [Install]
    var isSignedIn: (String) -> Bool

    static func live() -> PushContentPreparer {
        let keys = PushKeyStore.shared
        let tokens = KeychainTokenStore.shared
        return PushContentPreparer(
            privateKey: { keys.privateKey(for: $0) },
            unread: InstallUnreadStore.shared,
            installs: { InstallStore.shared.installs },
            isSignedIn: { tokens.token(for: $0) != nil })
    }

    /// The `userInfo` key for the install's name when two or more installs
    /// are signed in; read by `CommunicationPayload`.
    static let installLabelKey = "install_label"

    static func fallbackBody(_ installName: String) -> String { "New message in \(installName)" }

    /// The kinds' iOS categories, as `Platform.Push.Notification.category_for/1`.
    static func category(forKind kind: String?) -> String? {
        switch kind {
        case "chat_mention": return "SUITE_MENTION"
        case "meeting_ring_waiting": return "SUITE_RING_WAITING"
        case "task_plan_review", "review_request_pending": return "SUITE_OPEN"
        default: return nil
        }
    }

    func prepare(_ content: UNNotificationContent) -> UNNotificationContent {
        guard let mutable = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        let userInfo = content.userInfo
        let host = (userInfo["install_host"] as? String).flatMap(InstallStore.normalizeHost)
        let saved = installs()

        if let host, userInfo["kind"] == nil {
            reveal(mutable, userInfo: userInfo, host: host, name: displayName(host, saved))
        }

        if let host, let count = Self.intValue(userInfo["unread_count"]),
            let asOf = InstallUnreadStore.parseDate(userInfo["unread_as_of"])
        {
            unread.write(count: count, asOf: asOf, for: host)
            mutable.badge = NSNumber(value: unread.total)
        }

        if let host, saved.filter({ isSignedIn($0.host) }).count > 1 {
            let name = displayName(host, saved)
            if mutable.subtitle.isEmpty { mutable.subtitle = name }
            // A communication notification does not draw the subtitle:
            // `CommunicationNotification` carries this in the conversation name.
            mutable.userInfo[Self.installLabelKey] = name
        }
        return mutable
    }

    private func reveal(_ content: UNMutableNotificationContent, userInfo: [AnyHashable: Any], host: String, name: String) {
        guard let sealed = userInfo["sealed"] as? String, !sealed.isEmpty,
            let key = privateKey(host),
            let data = PushSeal.open(sealed, installHost: host, key: key)
        else {
            content.body = Self.fallbackBody(name)
            return
        }
        if let title = data["title"], !title.isEmpty { content.title = title }
        // The install drops `body` to fit the 3,072-byte cap: still never blank.
        content.body = data["body"].flatMap { $0.isEmpty ? nil : $0 } ?? Self.fallbackBody(name)
        if let category = data["category"] ?? Self.category(forKind: data["kind"]) {
            content.categoryIdentifier = category
        }
        // The inner map's thread id is the bare space id / `approvals`; the
        // install prefix keeps two installs' threads apart.
        if let thread = data["thread_id"], !thread.isEmpty {
            content.threadIdentifier = "\(host):\(thread)"
        }
        var merged = userInfo
        merged.removeValue(forKey: "sealed")
        for (key, value) in data where !["install_host", "unread_count", "unread_as_of"].contains(key) {
            merged[key] = value
        }
        merged["install_host"] = host
        content.userInfo = merged
    }

    private func displayName(_ host: String, _ saved: [Install]) -> String {
        saved.first { $0.host == host }?.displayName ?? host
    }

    static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let text as String: return Int(text)
        default: return nil
        }
    }
}
