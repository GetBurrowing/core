import AppIntents
import Foundation
import Intents
import UserNotifications

// Communication notifications (task 01a111bb stage 4), built in the
// Notification Service Extension and unit-tested in the app. Compiled into
// the app, the widgets and the extension; nothing here touches the network
// or logs.

/// The ids a chat push carries beside `aps`
/// (`Platform.Push.Notification.to_apns_payload/1`). Present only for a full
/// payload: a redacted one has no ids and yields nil.
struct CommunicationPayload: Equatable {
    static let kinds: Set<String> = ["chat_message", "chat_mention"]

    let host: String
    let spaceID: String
    let messageID: String
    let authorID: String
    let authorType: String?
    let authorName: String?
    let spaceName: String?
    /// The install's name, set by `PushContentPreparer` only while two or
    /// more installs are signed in (task 01a1261e).
    let installLabel: String?

    init?(userInfo: [AnyHashable: Any]) {
        func uuid(_ key: String) -> String? {
            guard let value = userInfo[key] as? String, UUID(uuidString: value) != nil else { return nil }
            return value.lowercased()
        }
        func text(_ key: String) -> String? {
            guard let value = (userInfo[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        guard let kind = userInfo["kind"] as? String, Self.kinds.contains(kind),
            let host = text("install_host").flatMap(InstallStore.normalizeHost), !host.isEmpty,
            let spaceID = uuid("space_id"), let messageID = uuid("message_id"), let authorID = uuid("author_id")
        else { return nil }
        self.host = host
        self.spaceID = spaceID
        self.messageID = messageID
        self.authorID = authorID
        authorType = text("author_type")
        authorName = text("author_name")
        spaceName = text("space_name")
        installLabel = text(PushContentPreparer.installLabelKey)
    }

    /// Every id is `<install_host>|<uuid>` from the PAYLOAD's host, never
    /// from whichever install happens to be selected.
    var messageEntityID: String { EntityRef(host: host, uuid: messageID).id }
    var conversationEntityID: String { EntityRef(host: host, uuid: spaceID).id }
    var senderID: String { EntityRef(host: host, uuid: authorID).id }
}

enum CommunicationNotification {
    /// The content to deliver: a full chat payload gains entity ids (iOS 27)
    /// and becomes a communication notification; anything else is returned
    /// untouched (the same object).
    static func build(_ content: UNNotificationContent) -> UNNotificationContent {
        guard let payload = CommunicationPayload(userInfo: content.userInfo) else { return content }
        var result = (try? content.updating(from: sendMessageIntent(payload))) ?? content
        if #available(iOS 27, *), let mutable = result.mutableCopy() as? UNMutableNotificationContent {
            mutable.appEntityIdentifiers = entityIdentifiers(payload)
            result = mutable
        }
        return result
    }

    @available(iOS 27, *)
    static func entityIdentifiers(_ payload: CommunicationPayload) -> [EntityIdentifier] {
        [
            EntityIdentifier(for: MessageEntity.self, identifier: payload.messageEntityID),
            EntityIdentifier(for: ConversationEntity.self, identifier: payload.conversationEntityID),
        ]
    }

    /// The incoming message as an intent: the sender (display name and the
    /// `<host>|<uuid>` handle only) and the conversation. No content: the
    /// notification's own body is what shows.
    static func sendMessageIntent(_ payload: CommunicationPayload) -> INSendMessageIntent {
        let sender = INPerson(
            personHandle: INPersonHandle(value: payload.senderID, type: .unknown), nameComponents: nil,
            displayName: payload.authorName, image: nil, contactIdentifier: nil, customIdentifier: payload.senderID)
        // A DM's conversation name is the other person's name: it has no
        // space name of its own (see `conversationName` for the install).
        let space = payload.spaceName.flatMap { $0 == payload.authorName ? nil : $0 }
        let name = conversationName(space: space, sender: payload.authorName, install: payload.installLabel)
        return INSendMessageIntent(
            recipients: groupRecipients(payload.installLabel, sender: sender), outgoingMessageType: .outgoingMessageText,
            content: nil, speakableGroupName: name.map { INSpeakableString(spokenPhrase: $0) },
            conversationIdentifier: payload.conversationEntityID, serviceName: nil, sender: sender, attachments: nil)
    }

    /// A communication notification draws the sender and the body only:
    /// `content.subtitle` and `content.title` are dropped (measured on iOS
    /// 27, task 01a1261e). With two or more installs signed in the install
    /// travels in the conversation name, as Android's `launch · B`: a space
    /// reads `<space> · <install>`, a DM `<sender> · <install>`. One install:
    /// the space name alone, a DM none.
    static func conversationName(space: String?, sender: String?, install: String?) -> String? {
        guard let install else { return space }
        guard let base = space ?? sender else { return install }
        return "\(base) · \(install)"
    }

    /// iOS 27 draws the conversation name (as the line under the sender) only
    /// for a GROUP, which it infers from more than one recipient: with no
    /// recipients the name is dropped, so before this a space's name never
    /// showed either (measured, task 01a1261e). No recipient list travels in
    /// the push, so while the install must show, the recipients are the
    /// sender plus this device. One install signed in: none, as before.
    static func groupRecipients(_ install: String?, sender: INPerson) -> [INPerson]? {
        guard install != nil else { return nil }
        let me = INPerson(
            personHandle: INPersonHandle(value: nil, type: .unknown), nameComponents: nil, displayName: nil, image: nil,
            contactIdentifier: nil, customIdentifier: nil, isMe: true)
        return [sender, me]
    }
}
