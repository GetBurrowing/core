import UserNotifications
import XCTest

@testable import App

final class NotificationTests: XCTestCase {
    func testCategoryIdentifiersMatchTheServerPayload() {
        let categories = Dictionary(uniqueKeysWithValues: SuiteNotificationCategory.all().map { ($0.identifier, $0) })
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
        XCTAssertTrue(SuiteNotificationCategory.isReply("SUITE_REPLY"))
        XCTAssertTrue(SuiteNotificationCategory.isReply("BURROW_REPLY"))
        XCTAssertFalse(SuiteNotificationCategory.isReply("SUITE_OPEN_ACTION"))
        XCTAssertFalse(SuiteNotificationCategory.isReply("BURROW_OPEN_ACTION"))
        XCTAssertTrue(SuiteNotificationCategory.isRingWaiting("SUITE_RING_WAITING"))
        XCTAssertTrue(SuiteNotificationCategory.isRingWaiting("BURROW_RING_WAITING"))
        XCTAssertFalse(SuiteNotificationCategory.isRingWaiting("BURROW_MENTION"))
    }

    /// The capability the server keys BURROW_* on (task 01a14ba1): this build
    /// registers both sets, so it says so when it registers its device.
    func testRegistrationBodyDeclaresTheBurrowCategoryScheme() {
        let body = SuiteAPI.registrationBody(token: Data([0x00, 0xab]), appInstallID: "install-1", publicKey: "pk")
        XCTAssertEqual(body["push_category_scheme"] as? String, "burrow")
        XCTAssertEqual(body["token"] as? String, "00ab")
        XCTAssertEqual(body["app_install_id"] as? String, "install-1")
        XCTAssertEqual(body["push_public_key"] as? String, "pk")

        let noKey = SuiteAPI.registrationBody(token: Data([0x01]), appInstallID: "install-1", publicKey: nil)
        XCTAssertNil(noKey["push_public_key"])
        XCTAssertEqual(noKey["push_category_scheme"] as? String, "burrow", "the scheme does not depend on the key")
    }

    func testPayloadDestinationStaysOnItsInstall() {
        let relative = PushPayload(userInfo: ["install_host": "suite.example.com", "url": "/chat/s1?message=m1"])
        XCTAssertEqual(relative.destination()?.absoluteString, "https://suite.example.com/chat/s1?message=m1")

        let absolute = PushPayload(userInfo: ["install_host": "suite.example.com", "url": "https://suite.example.com/inbox"])
        XCTAssertEqual(absolute.destination()?.absoluteString, "https://suite.example.com/inbox")

        let foreign = PushPayload(userInfo: ["install_host": "suite.example.com", "url": "https://evil.example/x"])
        XCTAssertEqual(foreign.destination()?.absoluteString, "https://suite.example.com/")

        XCTAssertNil(PushPayload(userInfo: ["url": "/chat"]).destination())
    }

    func testAuthorizationStateVocabulary() {
        XCTAssertEqual(SuiteNativePlugin.state(.authorized), "granted")
        XCTAssertEqual(SuiteNativePlugin.state(.denied), "denied")
        XCTAssertEqual(SuiteNativePlugin.state(.notDetermined), "prompt")
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

        let shell = SuiteBridgeViewController()
        shell.loadViewIfNeeded()

        XCTAssertNotNil(shell.bridge, "the bridge loaded")
        XCTAssertTrue(
            center.delegate === NotificationRouter.shared,
            "delegate is \(String(describing: center.delegate))")
    }
}
