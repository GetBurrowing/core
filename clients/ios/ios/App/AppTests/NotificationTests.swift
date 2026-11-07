import CryptoKit
import Intents
import UIKit
import UserNotifications
import XCTest

@testable import App

final class NotificationTests: XCTestCase {
    func testCategoryIdentifiersMatchTheServerPayload() {
        let categories = Dictionary(uniqueKeysWithValues: BurrowNotificationCategory.all().map { ($0.identifier, $0) })
        // Platform.Push.Notification maps chat_mention -> SUITE_MENTION,
        // approvals -> SUITE_OPEN and meeting_ring_waiting ->
        // SUITE_RING_WAITING (task 01a10db7 stage 5; no actions: it becomes
        // the in-call banner).
        // Task 01a14ba1: the BURROW_* names are registered BESIDE them, so
        // a server sending either set draws the same actions.
        XCTAssertEqual(
            Set(categories.keys),
            [
                "SUITE_MENTION", "SUITE_OPEN", "SUITE_RING_WAITING",
                "BURROW_MENTION", "BURROW_OPEN", "BURROW_RING_WAITING",
            ])

        let sets: [(prefix: String, reply: String, open: String)] = [
            ("SUITE", "SUITE_REPLY", "SUITE_OPEN_ACTION"),
            ("BURROW", "BURROW_REPLY", "BURROW_OPEN_ACTION"),
        ]
        for set in sets {
            XCTAssertEqual(categories["\(set.prefix)_RING_WAITING"]!.actions, [], set.prefix)

            let mention = categories["\(set.prefix)_MENTION"]!
            XCTAssertEqual(mention.actions.map(\.identifier), [set.reply, set.open], set.prefix)
            XCTAssertEqual(mention.actions.map(\.title), ["Reply", "Open"], set.prefix)
            let reply = mention.actions[0]
            XCTAssertTrue(reply is UNTextInputNotificationAction, set.prefix)
            XCTAssertFalse(reply.options.contains(.foreground), "Reply must not open the app")
            XCTAssertTrue(reply.options.contains(.authenticationRequired), set.prefix)
            XCTAssertTrue(mention.actions[1].options.contains(.foreground), set.prefix)

            let open = categories["\(set.prefix)_OPEN"]!
            XCTAssertEqual(open.actions.map(\.identifier), [set.open], set.prefix)
            XCTAssertEqual(open.actions.map(\.title), ["Open"], set.prefix)
            XCTAssertEqual(open.categorySummaryFormat, "%u approvals", set.prefix)
        }
    }

    func testReplyAndRingMatchBothNames() {
        XCTAssertTrue(BurrowNotificationCategory.isReply("SUITE_REPLY"))
        XCTAssertTrue(BurrowNotificationCategory.isReply("BURROW_REPLY"))
        XCTAssertFalse(BurrowNotificationCategory.isReply("SUITE_OPEN_ACTION"))
        XCTAssertFalse(BurrowNotificationCategory.isReply("BURROW_OPEN_ACTION"))
        XCTAssertTrue(BurrowNotificationCategory.isRingWaiting("SUITE_RING_WAITING"))
        XCTAssertTrue(BurrowNotificationCategory.isRingWaiting("BURROW_RING_WAITING"))
        XCTAssertFalse(BurrowNotificationCategory.isRingWaiting("BURROW_MENTION"))
    }

    /// The capability the server keys BURROW_* on (task 01a14ba1): this build
    /// registers both sets, so it says so when it registers its device.
    func testRegistrationBodyDeclaresTheBurrowCategoryScheme() {
        let body = BurrowAPI.registrationBody(token: Data([0x00, 0xab]), appInstallID: "install-1", publicKey: "pk")
        XCTAssertEqual(body["push_category_scheme"] as? String, "burrow")
        XCTAssertEqual(body["token"] as? String, "00ab")
        XCTAssertEqual(body["app_install_id"] as? String, "install-1")
        XCTAssertEqual(body["push_public_key"] as? String, "pk")

        let noKey = BurrowAPI.registrationBody(token: Data([0x01]), appInstallID: "install-1", publicKey: nil)
        XCTAssertNil(noKey["push_public_key"])
        XCTAssertEqual(noKey["push_category_scheme"] as? String, "burrow", "the scheme does not depend on the key")
    }

    func testPayloadDestinationStaysOnItsInstall() {
        let relative = PushPayload(userInfo: ["install_host": "burrow.example.com", "url": "/chat/s1?message=m1"])
        XCTAssertEqual(relative.destination()?.absoluteString, "https://burrow.example.com/chat/s1?message=m1")

        let absolute = PushPayload(userInfo: ["install_host": "burrow.example.com", "url": "https://burrow.example.com/inbox"])
        XCTAssertEqual(absolute.destination()?.absoluteString, "https://burrow.example.com/inbox")

        let foreign = PushPayload(userInfo: ["install_host": "burrow.example.com", "url": "https://evil.example/x"])
        XCTAssertEqual(foreign.destination()?.absoluteString, "https://burrow.example.com/")

        XCTAssertNil(PushPayload(userInfo: ["url": "/chat"]).destination())
    }

    func testAuthorizationStateVocabulary() {
        XCTAssertEqual(BurrowNativePlugin.state(.authorized), "granted")
        XCTAssertEqual(BurrowNativePlugin.state(.denied), "denied")
        XCTAssertEqual(BurrowNativePlugin.state(.notDetermined), "prompt")
    }

    func testDeviceTokenHex() {
        XCTAssertEqual(PushRegistrar.hex(Data([0x00, 0xab, 0x10])), "00ab10")
    }
}

/// Capacitor's bridge replaces the notification delegate when it loads
/// unless told not to (`ios.handleApplicationNotifications: false`, plus
/// the re-assert in `capacitorDidLoad`). Without both, Reply, Open and a
/// tap go to CAPNotificationRouter and never reach the shell.
final class NotificationDelegateTests: XCTestCase {
    func testDelegateIsTheAppRouterAfterTheBridgeLoads() {
        let center = UNUserNotificationCenter.current()
        let savedHandler = NotificationRouter.shared.openHandler
        defer { NotificationRouter.shared.openHandler = savedHandler }

        let shell = BurrowBridgeViewController()
        shell.loadViewIfNeeded()

        XCTAssertNotNil(shell.bridge, "the bridge loaded")
        XCTAssertTrue(
            center.delegate === NotificationRouter.shared,
            "delegate is \(String(describing: center.delegate))")
    }
}

/// Task 01a1b700: "every iPhone notification reads Burrow". Fixtures for the
/// sender a chat push shows, driven through the Notification Service
/// Extension's own builders (`PushContentPreparer`,
/// `AvatarNotificationDelivery`, `CommunicationPayload`,
/// `CommunicationNotification.sendMessageIntent`).
///
/// The assertions are on the INTENT the extension builds and on the
/// delivered content's thread, title and body, never on the delivered
/// content BEING a communication notification: `content.updating(from:)`
/// needs the Communication Notifications capability in a signed build, and
/// this unsigned test host has none, so there it may throw and
/// `CommunicationNotification.build` falls back to the plain content.
/// Whether the signed build carries the capability is a device-side check.
final class SenderNotificationFixtureTests: XCTestCase {
    private let host = "nse-fixture.localhost"
    private let personID = "0f1b7000-0000-4000-8000-000000000001"
    private let agentID = "0f1b7000-0000-4000-8000-000000000002"
    private let spaceID = "0f1b7000-0000-4000-8000-0000000000a1"
    private let messageID = "0f1b7000-0000-4000-8000-0000000000b1"
    private let personName = "Person Placeholder"
    private let agentName = "Agent Placeholder"

    // MARK: Helpers

    private func png(_ color: UIColor, size: CGFloat = 64) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    /// A direct chat push as `Platform.Push.Notification.to_apns_payload/1`
    /// sends it: alert title/body, `thread-id` `<host>:<space>`, ids beside `aps`.
    private func directPush(
        authorType: String, authorID: String, name: String, tone: String?, avatar: String?, space: String = "launch"
    ) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(name) in \(space)"
        content.body = "Deck is updated."
        content.threadIdentifier = "\(host):\(spaceID)"
        var info: [AnyHashable: Any] = [
            "kind": "chat_message", "install_host": host, "space_id": spaceID, "message_id": messageID,
            "author_id": authorID, "author_type": authorType, "author_name": name, "space_name": space,
        ]
        if let tone { info["author_avatar_tone"] = tone }
        if let avatar { info["author_avatar_url"] = avatar }
        content.userInfo = info
        return content
    }

    private func preparer(key: Curve25519.KeyAgreement.PrivateKey?, installs: [Install] = []) throws -> PushContentPreparer {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "sender-fixture-\(UUID().uuidString)"))
        return PushContentPreparer(
            privateKey: { _ in key }, unread: InstallUnreadStore(defaults: defaults), installs: { installs }, isSignedIn: { _ in false })
    }

    /// Runs `prepared` through the extension's delivery with a stub fetch.
    /// Returns the delivered content and what the stub was asked for.
    private func deliver(_ prepared: UNNotificationContent, picture: Data?) async -> (UNNotificationContent, [(URL, String)]) {
        let lock = NSLock()
        var requests: [(URL, String)] = []
        var delivered: UNNotificationContent?
        let done = expectation(description: "delivered")
        let delivery = AvatarNotificationDelivery(
            fetch: { url, host in
                lock.lock()
                requests.append((url, host))
                lock.unlock()
                return picture
            },
            deliver: { content in
                delivered = content
                done.fulfill()
            })
        delivery.start(prepared)
        await fulfillment(of: [done], timeout: 5)
        lock.lock()
        defer { lock.unlock() }
        return (delivered!, requests)
    }

    /// The bytes an INImage was built from: INImage exposes no data getter,
    /// but its archive carries the image data verbatim.
    private func assertImage(_ image: INImage?, is expected: Data, _ message: String, line: UInt = #line) throws {
        let image = try XCTUnwrap(image, "sender image is nil: iOS would draw grey initials. \(message)", line: line)
        let archive = try NSKeyedArchiver.archivedData(withRootObject: image, requiringSecureCoding: false)
        XCTAssertNotNil(archive.range(of: expected), "sender image is not the expected rendering. \(message)", line: line)
    }

    private func sealFixture() throws -> (json: [String: Any], inner: [String: Any], host: String, key: Curve25519.KeyAgreement.PrivateKey) {
        let url =
            Bundle(for: Self.self).url(forResource: "push_seal_v1", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/push_seal_v1.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let inner = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(json["plaintext"] as? String).utf8)) as? [String: Any])
        let key = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: try XCTUnwrap(PushKeyStore.data(base64url: try XCTUnwrap(json["recipient_private_key"] as? String))))
        return (json, inner, try XCTUnwrap(json["install_host"] as? String), key)
    }

    /// Seals `inner` for the fixture's recipient key the way the server does.
    private func seal(_ inner: [String: Any], json: [String: Any], host: String) throws -> String {
        let publicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: try XCTUnwrap(PushKeyStore.data(base64url: try XCTUnwrap(json["recipient_public_key"] as? String))))
        var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: PushSeal.ciphersuite, info: PushSeal.info)
        let ciphertext = try sender.seal(try JSONSerialization.data(withJSONObject: inner), authenticating: Data(host.utf8))
        return PushKeyStore.base64url(sender.encapsulatedKey + ciphertext)
    }

    /// What the relay delivers: a constant alert and the sealed blob, nothing else.
    private func relayed(host: String, sealed: String?) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Burrow"
        content.body = "New notification"
        var info: [AnyHashable: Any] = ["install_host": host, "unread_count": 1, "unread_as_of": "2026-11-07T12:00:00Z"]
        if let sealed { info["sealed"] = sealed }
        content.userInfo = info
        return content
    }

    // MARK: (a) a person sender, direct

    func testAPersonSenderShowsTheirNameAndFetchedPicture() async throws {
        let avatar = "https://\(host)/api/app/users/\(personID)/avatar?v=1"
        let prepared = try preparer(key: nil).prepare(
            directPush(authorType: "user", authorID: personID, name: personName, tone: "3", avatar: avatar))
        let picture = png(.blue)

        let (delivered, requests) = await deliver(prepared, picture: picture)
        XCTAssertEqual(requests.count, 1, "one avatar fetch")
        XCTAssertEqual(requests.first?.0.absoluteString, avatar)
        XCTAssertEqual(requests.first?.1, host, "the bearer can only go to the payload's own host")
        XCTAssertEqual(delivered.threadIdentifier, "\(host):\(spaceID)")
        XCTAssertEqual(delivered.body, "Deck is updated.")

        let payload = try XCTUnwrap(CommunicationPayload(userInfo: prepared.userInfo))
        XCTAssertEqual(payload.effectiveTone, "3")
        let intent = CommunicationNotification.sendMessageIntent(payload, image: picture)
        XCTAssertEqual(intent.sender?.displayName, personName)
        XCTAssertEqual(intent.sender?.customIdentifier, "\(host)|\(personID)")
        XCTAssertEqual(intent.conversationIdentifier, "\(host)|\(spaceID)")
        try assertImage(
            intent.sender?.image, is: AvatarRenderer.senderImage(name: personName, tone: "3", picture: picture), "person, fetched picture")
    }

    func testAPersonSenderWithNoPictureShowsTheTone3LetterDisc() async throws {
        let prepared = try preparer(key: nil).prepare(
            directPush(authorType: "user", authorID: personID, name: personName, tone: "3", avatar: nil))

        let (delivered, requests) = await deliver(prepared, picture: png(.blue))
        XCTAssertTrue(requests.isEmpty, "no url, no fetch")
        XCTAssertEqual(delivered.threadIdentifier, "\(host):\(spaceID)")

        let intent = CommunicationNotification.sendMessageIntent(try XCTUnwrap(CommunicationPayload(userInfo: prepared.userInfo)))
        XCTAssertEqual(intent.sender?.displayName, personName)
        XCTAssertEqual(intent.sender?.customIdentifier, "\(host)|\(personID)")
        try assertImage(
            intent.sender?.image, is: AvatarRenderer.senderImage(name: personName, tone: "3", picture: nil), "person, tone-3 letter disc")
    }

    // MARK: (b) an agent sender, tone derived from author_type

    func testAnAgentSenderWithNoToneGetsTheAgentDiscAndDiffersFromAPerson() throws {
        let agentPush = try preparer(key: nil).prepare(
            directPush(authorType: "agent", authorID: agentID, name: agentName, tone: nil, avatar: nil))
        XCTAssertNil(agentPush.userInfo["author_avatar_tone"], "the fixture carries no tone")
        let payload = try XCTUnwrap(CommunicationPayload(userInfo: agentPush.userInfo))
        XCTAssertEqual(payload.effectiveTone, AvatarRenderer.agentTone, "derived from author_type")

        let agent = CommunicationNotification.sendMessageIntent(payload)
        XCTAssertEqual(agent.sender?.displayName, agentName)
        XCTAssertEqual(agent.sender?.customIdentifier, "\(host)|\(agentID)")
        let agentDisc = AvatarRenderer.senderImage(name: agentName, tone: AvatarRenderer.agentTone, picture: nil)
        try assertImage(agent.sender?.image, is: agentDisc, "agent disc from author_type")

        let person = CommunicationNotification.sendMessageIntent(
            try XCTUnwrap(CommunicationPayload(userInfo: directPush(authorType: "user", authorID: personID, name: personName, tone: "3", avatar: nil).userInfo))
        )
        let personDisc = AvatarRenderer.senderImage(name: personName, tone: "3", picture: nil)
        XCTAssertNotEqual(agentDisc, personDisc)
        XCTAssertNotEqual(agent.sender?.customIdentifier, person.sender?.customIdentifier)
        let personArchive = try NSKeyedArchiver.archivedData(withRootObject: try XCTUnwrap(person.sender?.image), requiringSecureCoding: false)
        XCTAssertNil(personArchive.range(of: agentDisc), "the person's image is not the agent disc")
    }

    func testAnAgentSenderWithAPortraitShowsThePortrait() async throws {
        let avatar = "https://\(host)/api/app/agents/\(agentID)/avatar?v=2"
        let prepared = try preparer(key: nil).prepare(
            directPush(authorType: "agent", authorID: agentID, name: agentName, tone: nil, avatar: avatar))
        let portrait = png(.green)

        let (delivered, requests) = await deliver(prepared, picture: portrait)
        XCTAssertEqual(requests.map { $0.0.absoluteString }, [avatar])
        XCTAssertEqual(delivered.threadIdentifier, "\(host):\(spaceID)")

        let intent = CommunicationNotification.sendMessageIntent(try XCTUnwrap(CommunicationPayload(userInfo: prepared.userInfo)), image: portrait)
        XCTAssertEqual(intent.sender?.displayName, agentName)
        let rendered = AvatarRenderer.senderImage(name: agentName, tone: AvatarRenderer.agentTone, picture: portrait)
        XCTAssertNotEqual(rendered, AvatarRenderer.senderImage(name: agentName, tone: AvatarRenderer.agentTone, picture: nil))
        try assertImage(intent.sender?.image, is: rendered, "agent portrait")
    }

    // MARK: (c) two spaces on one host, relayed

    func testTwoRelayedSpacesOnOneHostGetSeparateThreadsAndConversations() async throws {
        let f = try sealFixture()
        let spaceA = "0f1b7000-0000-4000-8000-0000000000c1"
        let spaceB = "0f1b7000-0000-4000-8000-0000000000c2"
        let prep = try preparer(key: f.key)

        var results: [(UNNotificationContent, INSendMessageIntent)] = []
        for space in [spaceA, spaceB] {
            var inner = f.inner
            inner["space_id"] = space
            inner["thread_id"] = space
            let push = relayed(host: f.host, sealed: try seal(inner, json: f.json, host: f.host))
            XCTAssertFalse("\(push.userInfo)".contains(space), "the space id is only inside the blob")
            let prepared = prep.prepare(push)
            let (delivered, _) = await deliver(prepared, picture: nil)
            let intent = CommunicationNotification.sendMessageIntent(try XCTUnwrap(CommunicationPayload(userInfo: prepared.userInfo)))
            results.append((delivered, intent))
        }

        XCTAssertEqual(results[0].0.threadIdentifier, "\(f.host):\(spaceA)")
        XCTAssertEqual(results[1].0.threadIdentifier, "\(f.host):\(spaceB)")
        XCTAssertNotEqual(results[0].0.threadIdentifier, results[1].0.threadIdentifier)
        XCTAssertEqual(results[0].1.conversationIdentifier, "\(f.host)|\(spaceA)")
        XCTAssertEqual(results[1].1.conversationIdentifier, "\(f.host)|\(spaceB)")
        XCTAssertNotEqual(results[0].1.conversationIdentifier, results[1].1.conversationIdentifier)
        XCTAssertEqual(results[0].0.title, f.inner["title"] as? String, "unsealed, the title is the sender's")
    }

    // MARK: (d) unseal failure

    /// PRIVACY (task 01a1b700): when the blob does not open, the outer title
    /// MUST stay the relay's generic "Burrow". The relay makes "no plaintext
    /// crosses the relay" structural (relay_server.ex: a strict allow-list of
    /// keys and a constant alert), so on an unseal failure the device has no
    /// other source for the sender, and naming one would be a guess. The
    /// body is the install fallback, never ciphertext, and no communication
    /// notification is built with a guessed sender. `Notification.redact/2`
    /// is the EXTERNAL-recipient preview, not this path; both stay untouched.
    func testAnUnsealFailureStaysGenericAndBuildsNoSender() async throws {
        let f = try sealFixture()
        let install = Install(host: f.host, name: "Fixture Install")
        let authorName = try XCTUnwrap(f.inner["author_name"] as? String)

        let wrongKey = (try preparer(key: Curve25519.KeyAgreement.PrivateKey(), installs: [install]), f.json["sealed"] as? String)
        let nullSealed = (try preparer(key: f.key, installs: [install]), String?.none)
        for (label, (prep, sealed)) in [("wrong key", wrongKey), ("null sealed", nullSealed)] {
            let prepared = prep.prepare(relayed(host: f.host, sealed: sealed))
            let (delivered, requests) = await deliver(prepared, picture: png(.red))
            for content in [prepared, delivered] {
                XCTAssertEqual(content.title, "Burrow", label)
                XCTAssertEqual(content.body, "New message in Fixture Install", label)
                XCTAssertFalse(content.title.contains(authorName) || content.body.contains(authorName), "no sender name: \(label)")
                if let sealed { XCTAssertFalse(content.body.contains(sealed.prefix(12)), "no ciphertext: \(label)") }
            }
            XCTAssertNil(CommunicationPayload(userInfo: prepared.userInfo), "no communication payload: \(label)")
            XCTAssertTrue(requests.isEmpty, "no avatar fetch: \(label)")
        }
    }
}
