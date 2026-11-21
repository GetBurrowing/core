import UIKit
import XCTest

@testable import App

/// The iPhone Duo host (task 01a1fa7c stage 1): a UITabBarController shell
/// whose tabs the system puts in the closed Duo's side strip, one shared web
/// content re-parented into the selected tab's slot, and the same
/// `tabBarState` / `burrowNativeTab` contract as the standalone bar.
@available(iOS 18, *)
@MainActor
final class DuoShellTests: XCTestCase {
    private let four = ["chat", "calendar", "inbox", "more"]

    private func state(_ payload: [String: Any], from start: NativeTabBarState = NativeTabBarState()) -> NativeTabBarState {
        start.applying(payload, log: { _ in })
    }

    private func rgba(_ colour: UIColor?) -> [Int] {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        _ = colour?.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { Int(($0 * 255).rounded()) }
    }

    /// A shell around a plain content controller, with its host installed.
    /// Work the host scheduled (a tap's timeout), run by `runScheduled()`.
    private var scheduled: [@MainActor () -> Void] = []

    private func runScheduled() {
        let work = scheduled
        scheduled = []
        for item in work { item() }
    }

    private func makeShell() -> (DuoShellController, ControllerTabBarHost, UIViewController) {
        let content = UIViewController()
        let shell = DuoShellController(content: content)
        shell.loadViewIfNeeded()
        let host = ControllerTabBarHost(shell: shell, reduceMotion: { true }, schedule: { [weak self] _, work in self?.scheduled.append(work) })
        host.install(in: content)
        return (shell, host, content)
    }

    // MARK: The Duo predicate

    func testThePredicateReadsTheSimulatorModelIdentifierElseTheHardware() {
        XCTAssertEqual(DuoDevice.modelIdentifier(environment: ["SIMULATOR_MODEL_IDENTIFIER": "iPhone19,4"]), "iPhone19,4")
        let hardware = DuoDevice.modelIdentifier(environment: [:])
        XCTAssertFalse(hardware.isEmpty, "uname's machine")
        XCTAssertEqual(DuoDevice.modelIdentifier(environment: ["SIMULATOR_MODEL_IDENTIFIER": ""]), hardware, "empty counts as unset")
    }

    func testOnlyTheDuoModelIsADuo() {
        XCTAssertEqual(DuoDevice.modelIdentifiers, ["iPhone19,4"])
        XCTAssertTrue(DuoDevice.isDuo(model: "iPhone19,4"), "the iOS 27.2 test runtime has the vertical bar")
        for other in ["iPhone18,1", "iPhone18,3", "iPad17,4", "iPhone19,3", ""] {
            XCTAssertFalse(DuoDevice.isDuo(model: other), other)
        }
    }

    // MARK: Factory

    func testTheFactoryPicksTheStandaloneBarWhenThePredicateIsFalse() {
        let content = UIViewController()
        let shell = DuoShellController(content: content)
        // As at launch: the content's view loads (its viewDidLoad makes the
        // host) while the shell lays out, before the tabs' navigation
        // controllers are the shell's children.
        shell.loadViewIfNeeded()
        XCTAssertNotNil(content.parent)
        XCTAssertTrue(NativeTabBarFactory.make(for: content, isDuo: false) is StandaloneTabBarHost)
        XCTAssertEqual(NativeTabBarFactory.make(for: content, isDuo: false).hosting, "standalone")
        let duo = NativeTabBarFactory.make(for: content, isDuo: true)
        XCTAssertTrue(duo is ControllerTabBarHost)
        XCTAssertEqual(duo.hosting, "controller")
        XCTAssertTrue(NativeTabBarFactory.make(for: UIViewController(), isDuo: true) is StandaloneTabBarHost, "a Duo bridge with no shell")
        XCTAssertTrue(NativeTabBarFactory.make() is StandaloneTabBarHost, "no parent")
    }

    func testTheWindowRootIsTheShellOnlyOnTheDuo() {
        let content = UIViewController()
        XCTAssertTrue(DuoShellController.root(for: content, isDuo: false) === content)
        let root = DuoShellController.root(for: content, isDuo: true)
        XCTAssertTrue(root is DuoShellController)
        XCTAssertTrue(ShellRoot.content(of: root) === content)
        XCTAssertTrue(ShellRoot.content(of: content) === content)
        XCTAssertNil(ShellRoot.content(of: nil))
        XCTAssertNil(BurrowBridgeViewController.find(in: root), "not a bridge")
    }

    // MARK: Render

    func testTheShellStartsHiddenAsATabBarNeverASidebar() {
        let (shell, _, content) = makeShell()
        XCTAssertEqual(shell.mode, .tabBar)
        XCTAssertTrue(shell.isTabBarHidden, "hidden until the web's first state")
        XCTAssertEqual(shell.keys, four)
        XCTAssertTrue(content.parent === shell.selectedSlot, "the content is in the selected slot from the start")
        for tab in shell.tabs {
            let navigation = tab.viewController as? UINavigationController
            XCTAssertNotNil(navigation, tab.identifier)
            XCTAssertTrue(navigation?.isNavigationBarHidden ?? false, "stage 1 draws no navigation bar")
            XCTAssertEqual((navigation?.viewControllers.first as? TabSlotViewController)?.key, tab.identifier)
        }
    }

    func testTheHostRendersItemsOrderBadgesInkAndVisibility() {
        let (shell, host, _) = makeShell()
        let order = ["inbox", "chat", "more", "calendar"]
        let next = state([
            "items": order, "selected": "chat", "inbox_badge": "3", "visible": true,
            "ink": ["selected": "#8b3b04ff", "unselected": "#0000008c"], "scheme": "light",
        ])
        host.render(next)
        XCTAssertEqual(shell.keys, order, "the web's order")
        XCTAssertEqual(host.renderedKeys, order)
        XCTAssertEqual(shell.tabs.map(\.title), ["Inbox", "Chat", "More", "Calendar"])
        for tab in shell.tabs {
            XCTAssertNotNil(tab.image, "\(tab.identifier): the catalog glyph")
            XCTAssertEqual(tab.badgeValue, tab.identifier == "inbox" ? "3" : nil, tab.identifier)
        }
        XCTAssertEqual(shell.selectedTab?.identifier, "chat")
        XCTAssertFalse(shell.isTabBarHidden)
        XCTAssertEqual(rgba(shell.tabBar.tintColor), [0x8b, 0x3b, 0x04, 0xff], "the web's selected ink")
        XCTAssertEqual(rgba(shell.tabBar.unselectedItemTintColor), [0, 0, 0, 0x8c])
        XCTAssertEqual(shell.tabBar.overrideUserInterfaceStyle, .light)

        let cleared = state(["inbox_badge": NSNull(), "inbox_dot": false, "visible": false], from: next)
        host.render(cleared)
        XCTAssertNil(shell.tabs.first { $0.identifier == "inbox" }?.badgeValue, "a count of 0 shows nothing")
        XCTAssertFalse(shell.isTabBarHidden, "the web hiding its own bar does not hide the strip (stage 5)")
        host.render(state(["visible": true], from: cleared))
        XCTAssertFalse(shell.isTabBarHidden)
    }

    // MARK: Stage 5 round 2: the strip's selected tint is the web's ink

    /// The closed Duo's strip draws its selected tab in the tint of the
    /// shell's view, not the UITabBar's `tintColor`; unset, that is the
    /// app's global accent (the asset primary, #ad4b07 in light). The light
    /// probe ink #8b3b04 must reach the strip as it reaches the iPhone bar,
    /// and a later ink (a theme change) must follow.
    func testTheStripTakesTheWebsSelectedInkNotTheAssetPrimary() {
        let (shell, host, _) = makeShell()
        let light = state([
            "items": four, "selected": "chat", "visible": true,
            "ink": ["selected": "#8b3b04ff", "unselected": "#000000ff"], "scheme": "light",
        ])
        host.render(light)
        XCTAssertEqual(rgba(shell.view.tintColor), [0x8b, 0x3b, 0x04, 0xff], "the strip's tint is the probe ink")
        XCTAssertNotEqual(rgba(shell.view.tintColor), rgba(BurrowColor.primary.uiColor), "not the asset primary")
        XCTAssertEqual(rgba(shell.tabBar.tintColor), rgba(shell.view.tintColor), "the strip and the bar agree")
        host.render(state(["ink": ["selected": "#f47721ff"], "scheme": "dark"], from: light))
        XCTAssertEqual(rgba(shell.view.tintColor), [0xf4, 0x77, 0x21, 0xff], "a new ink follows")
    }

    // MARK: Stage 5 round 2: a move never carries a live text input session

    /// A text field that records the moment it resigns.
    private final class ResignSpyField: UITextField {
        var onResign: (() -> Void)?
        override func resignFirstResponder() -> Bool {
            onResign?()
            return super.resignFirstResponder()
        }
    }

    /// A shell on screen with the content editing in the Chat slot.
    private func makeEditingShell() throws -> (DuoShellController, ControllerTabBarHost, UIViewController, ResignSpyField, UIWindow, NativeTabBarState) {
        let (shell, host, content) = makeShell()
        let first = state(["items": four, "selected": "chat", "visible": true])
        host.render(first)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
        window.rootViewController = shell
        window.makeKeyAndVisible()
        let field = ResignSpyField(frame: CGRect(x: 10, y: 100, width: 200, height: 40))
        content.view.addSubview(field)
        window.layoutIfNeeded()
        XCTAssertTrue(field.becomeFirstResponder())
        try XCTSkipUnless(field.isFirstResponder, "the field could not take focus in this host")
        return (shell, host, content, field, window, first)
    }

    func testAWebDrivenMoveEndsEditingBeforeTheContentLeavesItsSlot() throws {
        let (shell, host, content, field, window, first) = try makeEditingShell()
        let chatSlot = try XCTUnwrap(shell.selectedSlot)
        var atResign: [String] = []
        field.onResign = {
            let parent = content.parent === chatSlot ? "chat" : "other"
            atResign.append("\(shell.selectedTab?.identifier ?? "none") parent=\(parent) window=\(content.view.window != nil)")
        }
        host.render(state(["selected": "inbox"], from: first))
        XCTAssertEqual(atResign.first, "chat parent=chat window=true", "editing ends while the old slot still holds the content, on screen")
        XCTAssertFalse(field.isFirstResponder)
        XCTAssertEqual(shell.editingEndedForMove, 1)
        XCTAssertTrue(content.parent === shell.selectedSlot, "and then the content moves")
        window.isHidden = true
    }

    func testATapOnAnotherTabEndsEditingBeforeTheSystemSelects() throws {
        let (shell, host, content, field, window, _) = try makeEditingShell()
        let chatSlot = try XCTUnwrap(shell.selectedSlot)
        var atResign: [String] = []
        field.onResign = { atResign.append("\(shell.selectedTab?.identifier ?? "none") parent=\(content.parent === chatSlot ? "chat" : "other")") }
        let calendar = try XCTUnwrap(shell.tabs.first { $0.identifier == "calendar" })
        XCTAssertTrue(host.tabBarController(shell, shouldSelectTab: calendar))
        XCTAssertEqual(atResign.first, "chat parent=chat", "resigned before the system's selection")
        XCTAssertFalse(field.isFirstResponder)
        XCTAssertEqual(shell.editingEndedForMove, 1)
        window.isHidden = true
    }

    func testNoMoveLeavesEditingAlone() throws {
        let (shell, host, _, field, window, first) = try makeEditingShell()
        // The same tab again, a badge, a web hide: no move, the keyboard stays.
        host.render(state(["selected": "chat", "inbox_badge": "2", "visible": false], from: first))
        XCTAssertTrue(field.isFirstResponder, "no move, no resign")
        XCTAssertEqual(shell.editingEndedForMove, 0)
        let chat = try XCTUnwrap(shell.selectedTab)
        XCTAssertFalse(host.tabBarController(shell, shouldSelectTab: chat), "a reselect")
        XCTAssertTrue(field.isFirstResponder)
        window.isHidden = true
    }

    // MARK: Stage 5: the strip never hides with the web's floating bar

    /// A conversation with its composer focused, a full-screen viewer, a
    /// covering sheet, a tab change's grace hide and a call (`data-in-call`,
    /// #243) all send `visible: false`. The strip is a system region that
    /// covers none of them and is the closed Duo's only navigation, so it
    /// stays, and so does the Back.
    func testAWebHideKeepsTheStripVisible() {
        let (shell, host, _) = makeShell()
        let shown = state(["items": four, "selected": "chat", "visible": true])
        host.render(shown)
        XCTAssertFalse(shell.isTabBarHidden)
        let hidden = state(["visible": false], from: shown)
        XCTAssertFalse(hidden.shown, "the standalone bar still hides")
        XCTAssertTrue(hidden.stripShown)
        host.render(hidden)
        XCTAssertFalse(shell.isTabBarHidden, "the web hid its bar; the strip stays")
        shell.renderNavBack(NativeNavBack(kind: .back, label: "Back"), verticalBar: true, tabsShown: hidden.stripShown)
        XCTAssertTrue(shell.navBarShown, "and the Back with it")
    }

    /// A page that sends no state (sign-in, guest pages): the bridge clears
    /// `webSentState` and the strip hides, as the bar did before.
    func testAPageThatSendsNoStateHidesTheStrip() {
        let (shell, host, _) = makeShell()
        var current = state(["items": four, "selected": "chat", "visible": true])
        host.render(current)
        current.visible = false
        current.webSentState = false
        host.render(current)
        XCTAssertTrue(shell.isTabBarHidden)
        host.render(state(["visible": true], from: current))
        XCTAssertFalse(shell.isTabBarHidden, "the next page's state shows it again")
    }

    // MARK: Stage 5: a tap animates the selection exactly once

    /// The web's sequence on a tab change whose new view mounts late: the
    /// old view's grace hide still names the OLD tab, then the new view
    /// names the new one. The system selected the tab on the tap (one
    /// animation); neither state moves the selection in code.
    func testATapSelectsOnceAndTheWebsEchoIsANoOp() throws {
        let (shell, host, content) = makeShell()
        var taps: [String] = []
        host.onTap = { taps.append($0) }
        let start = state(["items": four, "selected": "calendar", "visible": true])
        host.render(start)
        let chat = try XCTUnwrap(shell.tabs.first { $0.identifier == "chat" })
        let moves = host.programmaticSelections
        XCTAssertTrue(host.tabBarController(shell, shouldSelectTab: chat), "the system selects, and animates, once")
        XCTAssertEqual(taps, ["chat"])
        shell.selectedTab = chat
        host.tabBarController(shell, didSelectTab: chat, previousTab: nil)
        XCTAssertTrue(content.parent === shell.slot(of: chat), "the content follows the tap")
        let grace = state(["selected": "calendar", "visible": false], from: start)
        host.render(grace)
        XCTAssertEqual(shell.selectedTab?.identifier, "chat", "the old view's grace hide does not snap it back")
        XCTAssertFalse(shell.isTabBarHidden)
        host.render(state(["selected": "chat", "visible": false], from: grace))
        XCTAssertEqual(shell.selectedTab?.identifier, "chat")
        XCTAssertNil(host.pendingKey, "the web confirmed the tap")
        XCTAssertEqual(host.programmaticSelections, moves, "no selection was set in code")
        XCTAssertFalse(shell.isTabBarHidden, "Chat in a conversation keeps the strip")
    }

    /// The web declined the move (it never names the tapped tab): after the
    /// timeout its own selection is restored.
    func testAnUnconfirmedTapFallsBackToTheWebsSelection() throws {
        let (shell, host, _) = makeShell()
        host.render(state(["items": four, "selected": "calendar", "visible": true]))
        let inbox = try XCTUnwrap(shell.tabs.first { $0.identifier == "inbox" })
        XCTAssertTrue(host.tabBarController(shell, shouldSelectTab: inbox))
        shell.selectedTab = inbox
        XCTAssertEqual(scheduled.count, 1)
        runScheduled()
        XCTAssertNil(host.pendingKey)
        XCTAssertEqual(shell.selectedTab?.identifier, "calendar")
    }

    /// A second tap supersedes the first one's timeout.
    func testAStaleTimeoutDoesNotUndoANewerTap() throws {
        let (shell, host, _) = makeShell()
        let start = state(["items": four, "selected": "calendar", "visible": true])
        host.render(start)
        let inbox = try XCTUnwrap(shell.tabs.first { $0.identifier == "inbox" })
        let more = try XCTUnwrap(shell.tabs.first { $0.identifier == "more" })
        XCTAssertTrue(host.tabBarController(shell, shouldSelectTab: inbox))
        shell.selectedTab = inbox
        XCTAssertTrue(host.tabBarController(shell, shouldSelectTab: more))
        shell.selectedTab = more
        let first = scheduled.removeFirst()
        first()
        XCTAssertEqual(host.pendingKey, "more")
        XCTAssertEqual(shell.selectedTab?.identifier, "more")
    }

    func testATapForwardsTheKeyAndAReselectChangesNothing() throws {
        let (shell, host, _) = makeShell()
        var taps: [String] = []
        host.onTap = { taps.append($0) }
        host.render(state(["items": four, "selected": "chat", "visible": true]))
        let chat = try XCTUnwrap(shell.tabs.first { $0.identifier == "chat" })
        XCTAssertFalse(host.tabBarController(shell, shouldSelectTab: chat), "a reselect changes nothing natively")
        XCTAssertEqual(taps, ["chat"], "a tap on the selected tab still goes to the web (reselect)")
        XCTAssertNil(host.pendingKey)
        let inbox = try XCTUnwrap(shell.tabs.first { $0.identifier == "inbox" })
        XCTAssertTrue(host.tabBarController(shell, shouldSelectTab: inbox), "another tab: the system selects it")
        XCTAssertEqual(taps, ["chat", "inbox"])
        XCTAssertEqual(host.pendingKey, "inbox")
    }

    func testAWebDrivenSwitchMovesTheSelectionAndTheOneContent() throws {
        let (shell, host, content) = makeShell()
        let first = state(["items": four, "selected": "chat", "visible": true])
        host.render(first)
        let chatSlot = try XCTUnwrap(shell.slot(of: shell.tabs.first { $0.identifier == "chat" }))
        XCTAssertTrue(content.parent === chatSlot)
        // A deep link or an in-app link to Inbox: the web's next state.
        host.render(state(["selected": "inbox"], from: first))
        XCTAssertEqual(shell.selectedTab?.identifier, "inbox")
        let inboxSlot = try XCTUnwrap(shell.slot(of: shell.tabs.first { $0.identifier == "inbox" }))
        XCTAssertTrue(content.parent === inboxSlot, "the same content, re-parented")
        XCTAssertTrue(content.view.superview === inboxSlot.view)
        XCTAssertTrue(chatSlot.children.isEmpty)
        XCTAssertNil(chatSlot.content)
        XCTAssertEqual(shell.tabs.compactMap { shell.slot(of: $0)?.children.count }.reduce(0, +), 1, "exactly one slot holds it")
    }

    /// Duo-only difference: a UITabBarController always has a selected tab,
    /// so `selected: null` keeps the previous one (the standalone bar shows
    /// none).
    func testSelectedNullKeepsThePreviousSelection() {
        let (shell, host, content) = makeShell()
        let calendar = state(["items": four, "selected": "calendar", "visible": true])
        host.render(calendar)
        host.render(state(["selected": NSNull()], from: calendar))
        XCTAssertEqual(shell.selectedTab?.identifier, "calendar")
        XCTAssertTrue(content.parent === shell.selectedSlot)
        host.render(state(["selected": "nope"], from: calendar))
        XCTAssertEqual(shell.selectedTab?.identifier, "calendar", "an unknown key changes nothing")
    }

    func testANewItemListKeepsTheSelectedKeyAndTheContent() {
        let (shell, host, content) = makeShell()
        let first = state(["items": four, "selected": "inbox", "visible": true])
        host.render(first)
        host.render(state(["items": ["chat", "inbox", "more"]], from: first))
        XCTAssertEqual(shell.keys, ["chat", "inbox", "more"])
        XCTAssertEqual(shell.selectedTab?.identifier, "inbox")
        XCTAssertTrue(content.parent === shell.selectedSlot)
    }

    // MARK: Layout

    /// The content's sides stop at the slot's safe area (the side strip's
    /// reserved region); its top and bottom run to the edges.
    func testTheContentStopsAtTheStripsSafeArea() throws {
        let (shell, _, content) = makeShell()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
        window.rootViewController = shell
        window.makeKeyAndVisible()
        let slot = try XCTUnwrap(shell.selectedSlot)
        slot.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 70)
        window.layoutIfNeeded()
        let frame = content.view.convert(content.view.bounds, to: slot.view)
        XCTAssertGreaterThanOrEqual(slot.view.safeAreaInsets.right, 70)
        XCTAssertEqual(frame.minX, slot.view.safeAreaInsets.left, accuracy: 0.5)
        XCTAssertEqual(frame.maxX, slot.view.bounds.width - slot.view.safeAreaInsets.right, accuracy: 0.5)
        XCTAssertEqual(frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, slot.view.bounds.height, accuracy: 0.5)
        window.isHidden = true
    }

    func testTheBottomReservationIsZeroInTheVerticalStrip() {
        XCTAssertEqual(NativeTabBarFactory.bottomReservation(barHeight: 96, safeAreaBottom: 34, verticalBar: true), 0)
        XCTAssertEqual(NativeTabBarFactory.bottomReservation(barHeight: 96, safeAreaBottom: 34, verticalBar: false), 62)
        XCTAssertFalse(DuoLayout.verticalBarActive(UITraitCollection()), "unspecified edge: no vertical bar")
    }

    func testTheBottomReservationIsZeroWhenTheBarIsAtTheTop() {
        XCTAssertEqual(NativeTabBarFactory.bottomReservation(barHeight: 96, safeAreaBottom: 34, verticalBar: false, barAtBottom: false), 0)
        XCTAssertEqual(NativeTabBarFactory.bottomReservation(barHeight: 96, safeAreaBottom: 34, verticalBar: false, barAtBottom: true), 62)
        // Open at regular width the system draws the tabs at the top (B').
        XCTAssertFalse(DuoLayout.barAtBottom(barFrameInWindow: CGRect(x: 0, y: 24, width: 669, height: 50), windowHeight: 951))
        XCTAssertTrue(DuoLayout.barAtBottom(barFrameInWindow: CGRect(x: 0, y: 855, width: 669, height: 96), windowHeight: 951))
        // Slid off the bottom by setTabBarHidden: still the bottom bar.
        XCTAssertTrue(DuoLayout.barAtBottom(barFrameInWindow: CGRect(x: 0, y: 960, width: 669, height: 96), windowHeight: 951))
        XCTAssertTrue(DuoLayout.barAtBottom(barFrameInWindow: .zero, windowHeight: nil), "no window yet: as today")
    }

    // MARK: Orientation (task 01a1fa7c stage 2)

    private let outerPortrait = CGSize(width: 466, height: 678)
    private let innerPortrait = CGSize(width: 669, height: 951)
    private let innerLandscape = CGSize(width: 951, height: 669)
    private let iPhone18Pro = CGSize(width: 402, height: 874)

    func testTheOpenDuoRotatesAndTheClosedDuoStaysPortrait() {
        let both: UIInterfaceOrientationMask = [.portrait, .landscapeLeft, .landscapeRight]
        XCTAssertEqual(OrientationPolicy.mask(idiom: .phone, isDuo: true, windowSize: innerPortrait), both)
        XCTAssertEqual(OrientationPolicy.mask(idiom: .phone, isDuo: true, windowSize: innerLandscape), both, "landscape stays allowed once there")
        XCTAssertEqual(OrientationPolicy.mask(idiom: .phone, isDuo: true, windowSize: outerPortrait), .portrait)
        XCTAssertEqual(OrientationPolicy.mask(idiom: .phone, isDuo: true, windowSize: .zero), .portrait, "no window yet")
        XCTAssertFalse(OrientationPolicy.mask(idiom: .phone, isDuo: true, windowSize: innerPortrait).contains(.portraitUpsideDown))
    }

    func testEveryOtherIPhoneIsPortraitOnlyAtAnySize() {
        for size in [iPhone18Pro, outerPortrait, innerPortrait, innerLandscape, CGSize(width: 440, height: 956)] {
            XCTAssertEqual(OrientationPolicy.mask(idiom: .phone, isDuo: false, windowSize: size), .portrait, "\(size)")
        }
    }

    func testIPadKeepsAllFourOrientations() {
        for isDuo in [true, false] {
            XCTAssertEqual(OrientationPolicy.mask(idiom: .pad, isDuo: isDuo, windowSize: CGSize(width: 1032, height: 1376)), .all)
        }
    }

    func testTheOpenTestIsTheWindowsShorterSide() {
        XCTAssertFalse(OrientationPolicy.isOpen(windowSize: outerPortrait))
        XCTAssertFalse(OrientationPolicy.isOpen(windowSize: CGSize(width: 678, height: 466)), "closed, turned")
        XCTAssertTrue(OrientationPolicy.isOpen(windowSize: innerPortrait))
        XCTAssertTrue(OrientationPolicy.isOpen(windowSize: innerLandscape))
    }

    func testTheWindowMaskFollowsTheInjectedPredicate() {
        let window = UIWindow(frame: CGRect(origin: .zero, size: innerPortrait))
        XCTAssertEqual(OrientationPolicy.mask(for: window, isDuo: false), .portrait)
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertEqual(OrientationPolicy.mask(for: window, isDuo: true), [.portrait, .landscapeLeft, .landscapeRight])
            XCTAssertEqual(OrientationPolicy.mask(for: UIWindow(frame: CGRect(origin: .zero, size: outerPortrait)), isDuo: true), .portrait)
        }
        XCTAssertEqual(OrientationPolicy.mask(for: nil, isDuo: true), UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait)
    }

    func testThePlistGrantsLandscapeOnlyForTheMaskToNarrow() throws {
        // The raw file: the bundle's lookup folds the `~ipad` key in on iPad.
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Info", withExtension: "plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let iphone = try XCTUnwrap(plist["UISupportedInterfaceOrientations"] as? [String])
        XCTAssertEqual(
            Set(iphone), ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"])
        let ipad = try XCTUnwrap(plist["UISupportedInterfaceOrientations~ipad"] as? [String])
        XCTAssertEqual(ipad.count, 4, "the ~ipad key is untouched")
        // The app delegate narrows a closed-size window back to portrait.
        let closed = UIWindow(frame: CGRect(origin: .zero, size: iPhone18Pro))
        let expected: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
        XCTAssertEqual(AppDelegate().application(UIApplication.shared, supportedInterfaceOrientationsFor: closed), expected)
    }

    // MARK: Web-load recovery

    func testDuoRecoverySwapsOnlyTheContent() throws {
        let (shell, host, old) = makeShell()
        host.render(state(["items": four, "selected": "calendar", "visible": true]))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
        window.rootViewController = shell
        window.makeKeyAndVisible()
        let tabs = shell.tabs
        let replacement = UIViewController()
        shell.replaceContent(with: replacement)
        XCTAssertTrue(window.rootViewController === shell, "the window root stays")
        XCTAssertTrue(shell.content === replacement)
        XCTAssertTrue(replacement.parent === shell.selectedSlot)
        XCTAssertNil(old.parent)
        XCTAssertNil(old.view.superview)
        XCTAssertEqual(shell.tabs.map(\.identifier), tabs.map(\.identifier), "the tabs stay")
        XCTAssertEqual(shell.selectedTab?.identifier, "calendar", "the selection stays")
        XCTAssertTrue(ShellRoot.content(of: window.rootViewController) === replacement)
        window.isHidden = true
    }

    // MARK: Native Back in the strip (stage 4)

    private func leadingItems(_ slot: TabSlotViewController?) -> [UIBarButtonItem] {
        (slot?.navigationItem.leadingItemGroups ?? []).flatMap(\.barButtonItems)
    }

    func testThePayloadParsesBackCloseAndEverythingElseAsNone() {
        XCTAssertEqual(NativeNavBack.parse(["back": ["kind": "back", "label": "Back to channels"]]), NativeNavBack(kind: .back, label: "Back to channels"))
        XCTAssertEqual(NativeNavBack.parse(["back": ["kind": "close", "label": "Close"]]), NativeNavBack(kind: .close, label: "Close"))
        XCTAssertEqual(NativeNavBack.parse(["back": ["kind": "back", "label": "  "]])?.label, "Back", "a blank label falls back")
        for payload: [String: Any] in [["back": NSNull()], [:], ["back": ["kind": "home"]], ["back": "back"], ["back": ["label": "Back"]]] {
            XCTAssertNil(NativeNavBack.parse(payload), "\(payload)")
        }
    }

    func testBackGivesOneLeadingGroupWithTheLabelAndTheChevron() throws {
        let slot = TabSlotViewController(key: "chat")
        slot.showNavBack(NativeNavBack(kind: .back, label: "General"), action: {})
        XCTAssertEqual(slot.navigationItem.leadingItemGroups.count, 1)
        let item = try XCTUnwrap(leadingItems(slot).first)
        XCTAssertEqual(leadingItems(slot).count, 1)
        XCTAssertEqual(item.title, "General")
        XCTAssertEqual(item.image, UIImage(systemName: "chevron.backward"))
        XCTAssertEqual(item.accessibilityLabel, "General")
        XCTAssertFalse(slot.navigationItem.leftItemsSupplementBackButton)
        XCTAssertNil(slot.navigationItem.title, "the strip never carries a title")
    }

    func testCloseGivesTheSystemCloseItem() throws {
        let slot = TabSlotViewController(key: "chat")
        slot.showNavBack(NativeNavBack(kind: .close, label: "Close"), action: {})
        XCTAssertEqual(leadingItems(slot).count, 1)
        let item = try XCTUnwrap(leadingItems(slot).first)
        XCTAssertEqual(item.accessibilityIdentifier, "native-nav-close")
        XCTAssertEqual(item.accessibilityLabel, "Close")
        XCTAssertNil(item.title)
    }

    func testNoneClearsTheItem() {
        let slot = TabSlotViewController(key: "chat")
        slot.showNavBack(NativeNavBack(kind: .back, label: "Back"), action: {})
        slot.showNavBack(nil, action: {})
        XCTAssertTrue(slot.navigationItem.leadingItemGroups.isEmpty)
    }

    func testTheItemsActionFiresTheBackEvent() throws {
        let (shell, _, _) = makeShell()
        var fired = 0
        shell.onNavBack = { fired += 1 }
        shell.renderNavBack(NativeNavBack(kind: .back, label: "Back"), verticalBar: true)
        let item = try XCTUnwrap(leadingItems(shell.selectedSlot).first)
        let action = try XCTUnwrap(item.primaryAction)
        action.performWithSender(nil, target: nil)
        XCTAssertEqual(fired, 1)
    }

    func testOnlyTheSelectedSlotCarriesTheBackAndItFollowsTheContent() {
        let (shell, host, _) = makeShell()
        host.render(state(["items": four, "selected": "chat", "visible": true]))
        shell.renderNavBack(NativeNavBack(kind: .back, label: "Back"), verticalBar: true)
        XCTAssertEqual(leadingItems(shell.selectedSlot).count, 1)
        let chat = shell.selectedSlot
        host.render(state(["selected": "inbox"]))
        XCTAssertEqual(shell.selectedTab?.identifier, "inbox")
        XCTAssertTrue(leadingItems(chat).isEmpty, "exactly one Back")
        XCTAssertEqual(leadingItems(shell.selectedSlot).count, 1)
        let total = shell.tabs.map { leadingItems(shell.slot(of: $0)).count }.reduce(0, +)
        XCTAssertEqual(total, 1)
    }

    func testTheNavigationBarShowsOnlyWhileTheStripIsInUse() {
        let (shell, host, _) = makeShell()
        host.render(state(["items": four, "selected": "chat", "visible": true]))
        func hidden() -> [Bool] { shell.tabs.compactMap { shell.slot(of: $0)?.navigationController?.isNavigationBarHidden } }
        XCTAssertEqual(hidden(), [true, true, true, true], "hidden before any state")
        shell.renderNavBack(NativeNavBack(kind: .back, label: "Back"), verticalBar: true)
        XCTAssertEqual(hidden(), [false, false, false, false], "closed: the strip")
        // Open (inner display, portrait or landscape): no edge, no bar, and
        // the web header keeps its own control.
        shell.renderNavBack(NativeNavBack(kind: .back, label: "Back"), verticalBar: false)
        XCTAssertEqual(hidden(), [true, true, true, true])
        XCTAssertFalse(shell.navBarShown)
    }

    /// When the strip hides (a page with no state), the Back hides with it.
    func testTheBackHidesWithTheStrip() {
        let (shell, host, _) = makeShell()
        host.render(state(["items": four, "selected": "chat", "visible": true]))
        shell.renderNavBack(NativeNavBack(kind: .back, label: "Back"), verticalBar: true, tabsShown: false)
        XCTAssertFalse(shell.navBarShown, "the whole strip hides, Back included")
        XCTAssertEqual(shell.selectedSlot?.navigationController?.isNavigationBarHidden, true)
        shell.renderNavBack(NativeNavBack(kind: .back, label: "Back"), verticalBar: true, tabsShown: true)
        XCTAssertEqual(shell.selectedSlot?.navigationController?.isNavigationBarHidden, false)
    }

    func testTheAttributeIsSetOnlyOnTheDuoWithAnEdge() throws {
        XCTAssertNil(NativeNavBarDocument.attributeScript(isDuo: false, verticalBar: true), "never on another iPhone")
        XCTAssertNil(NativeNavBarDocument.attributeScript(isDuo: false, verticalBar: false))
        let set = try XCTUnwrap(NativeNavBarDocument.attributeScript(isDuo: true, verticalBar: true))
        XCTAssertTrue(set.contains("setAttribute(\"data-native-vertical-bar\""))
        XCTAssertFalse(set.contains("removeAttribute"))
        let cleared = try XCTUnwrap(NativeNavBarDocument.attributeScript(isDuo: true, verticalBar: false))
        XCTAssertTrue(cleared.contains("removeAttribute(\"data-native-vertical-bar\")"))
        XCTAssertFalse(cleared.contains("setAttribute"))
    }

    /// `data-native-duo` gates native_back.js: produced only when the Duo
    /// predicate is true, so a regular iPhone never runs the web observer.
    func testTheDuoMarkerScriptIsProducedOnlyOnTheDuo() throws {
        XCTAssertNil(NativeNavBarDocument.duoScript(isDuo: false), "never on another iPhone")
        let script = try XCTUnwrap(NativeNavBarDocument.duoScript(isDuo: true))
        XCTAssertTrue(script.contains("setAttribute(\"data-native-duo\", \"\")"))
        XCTAssertTrue(script.contains("new Event(\"burrowNativeDuo\")"))
        XCTAssertFalse(script.contains("removeAttribute"))
    }

    /// The predicate the bridge passes is the launch's own Duo answer.
    func testTheDuoMarkerFollowsTheLaunchPredicate() {
        XCTAssertEqual(NativeNavBarDocument.duoScript(isDuo: DuoDevice.current) != nil, DuoDevice.current)
    }
}
