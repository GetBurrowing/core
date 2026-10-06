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
        XCTAssertEqual(Set(categories.keys), ["SUITE_MENTION", "SUITE_OPEN", "SUITE_RING_WAITING"])
        XCTAssertEqual(categories["SUITE_RING_WAITING"]!.actions, [])

        let mention = categories["SUITE_MENTION"]!
        XCTAssertEqual(mention.actions.map(\.identifier), ["SUITE_REPLY", "SUITE_OPEN_ACTION"])
        XCTAssertEqual(mention.actions.map(\.title), ["Reply", "Open"])
        let reply = mention.actions[0]
        XCTAssertTrue(reply is UNTextInputNotificationAction)
        XCTAssertFalse(reply.options.contains(.foreground), "Reply must not open the app")
        XCTAssertTrue(mention.actions[1].options.contains(.foreground))

        XCTAssertEqual(categories["SUITE_OPEN"]!.actions.map(\.title), ["Open"])
        XCTAssertEqual(categories["SUITE_OPEN"]!.categorySummaryFormat, "%u approvals")
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
        XCTAssertTrue(center.delegate === NotificationRouter.shared,
                      "delegate is \(String(describing: center.delegate))")
    }
}
