import UserNotifications
import XCTest

@testable import App

/// The in-call invite banner for a busy callee (task 01a10db7 stage 5).
@MainActor
final class RingBannerTests: XCTestCase {
    private var waiting: RingWaiting!
    private var haptics = 0
    private var reveals = 0
    private var scheduled: [(TimeInterval, () -> Void)] = []
    private var notNow: [RingInvite] = []
    private var switched: [RingInvite] = []
    private var missed: [RingInvite] = []

    private let sam = RingInvite(
        ringID: "01a111f0-0000-7000-8000-000000000002", meetingID: "m2", installHost: "burrow.example.com",
        title: "Sam in Design review")

    override func setUp() async throws {
        waiting = RingWaiting()
        waiting.haptic = { [unowned self] in self.haptics += 1 }
        waiting.reveal = { [unowned self] in self.reveals += 1 }
        waiting.schedule = { [unowned self] after, work in
            self.scheduled.append((after, work))
            return {}
        }
        waiting.onNotNow = { [unowned self] in self.notNow.append($0) }
        waiting.onSwitch = { [unowned self] in self.switched.append($0) }
        waiting.onMissed = { [unowned self] in self.missed.append($0) }
    }

    func testShowingTheBannerIsOneSoftHapticAndRevealsTheCall() {
        waiting.show(sam)
        XCTAssertEqual(waiting.current, sam)
        XCTAssertEqual(haptics, 1)
        XCTAssertEqual(reveals, 1)
        XCTAssertEqual(scheduled.map(\.0), [30])
        waiting.show(sam)
        XCTAssertEqual(haptics, 1, "the same ring twice is one banner, one haptic")
    }

    func testNotNowDeclines() {
        waiting.show(sam)
        waiting.notNow()
        XCTAssertNil(waiting.current)
        XCTAssertEqual(notNow, [sam])
        XCTAssertTrue(switched.isEmpty && missed.isEmpty)
    }

    func testSwitchAnswersTheInvite() {
        waiting.show(sam)
        waiting.switchToInvite()
        XCTAssertNil(waiting.current)
        XCTAssertEqual(switched, [sam])
    }

    func testThirtySecondsWithoutAChoiceIsAMissedInvite() {
        waiting.show(sam)
        scheduled[0].1()
        XCTAssertNil(waiting.current)
        XCTAssertEqual(missed, [sam])
        // A choice after the timeout does nothing.
        waiting.notNow()
        XCTAssertTrue(notNow.isEmpty)
    }

    func testTheInviteDecodesFromTheRingWaitingAlert() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Sam in Design review", "body": "Invites you to join"], "category": "SUITE_RING_WAITING"],
            "ring_id": sam.ringID, "meeting_id": "m2", "space_id": "s2", "install_host": "burrow.example.com",
        ]
        XCTAssertEqual(RingInvite(userInfo: userInfo), sam)
        XCTAssertEqual(sam.initial, "S")
        XCTAssertNil(RingInvite(userInfo: ["meeting_id": "m2"]))
    }

    func testARingWaitingPushHasNoSystemPresentation() {
        XCTAssertEqual(NotificationRouter.presentation(forCategory: "SUITE_RING_WAITING"), [])
        XCTAssertEqual(NotificationRouter.presentation(forCategory: BurrowNotificationCategory.mention), [.banner, .list, .sound])
        XCTAssertTrue(BurrowNotificationCategory.all().contains { $0.identifier == "SUITE_RING_WAITING" })
    }

    /// Task 01a14ba1: the Burrow name for the same ring is presented the same
    /// way, and a Burrow mention still draws a system banner (the control).
    func testABurrowRingWaitingPushHasNoSystemPresentation() {
        XCTAssertEqual(NotificationRouter.presentation(forCategory: "BURROW_RING_WAITING"), [])
        XCTAssertEqual(NotificationRouter.presentation(forCategory: "BURROW_MENTION"), [.banner, .list, .sound])
        XCTAssertEqual(NotificationRouter.presentation(forCategory: "SUITE_MENTION"), [.banner, .list, .sound])
        XCTAssertTrue(BurrowNotificationCategory.all().contains { $0.identifier == "BURROW_RING_WAITING" })
    }

    func testTheInviteDecodesFromABurrowRingWaitingAlert() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Sam in Design review", "body": "Invites you to join"], "category": "BURROW_RING_WAITING"],
            "ring_id": sam.ringID, "meeting_id": "m2", "space_id": "s2", "install_host": "burrow.example.com",
        ]
        XCTAssertEqual(RingInvite(userInfo: userInfo), sam)
    }

    func testBannerColoursAndCopy() {
        XCTAssertEqual(RingBannerStyle.switchFill, .info)
        XCTAssertEqual(RingBannerStyle.switchLabel, .onInfo)
        XCTAssertEqual(RingBannerStyle.notNowOutline, .border)
        XCTAssertEqual(RingBannerStyle.fill, .surfaceMuted)
        XCTAssertEqual(RingBannerCopy.subtitle, "Invites you to join")
        XCTAssertEqual(RingBannerCopy.notNow, "Not now")
        XCTAssertEqual(RingBannerCopy.switchCall, "Switch")
    }
}
