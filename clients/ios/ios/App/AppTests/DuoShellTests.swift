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
    private func makeShell() -> (DuoShellController, ControllerTabBarHost, UIViewController) {
        let content = UIViewController()
        let shell = DuoShellController(content: content)
        shell.loadViewIfNeeded()
        let host = ControllerTabBarHost(shell: shell, reduceMotion: { true })
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
            "ink": ["selected": "#ad4b07ff", "unselected": "#0000008c"], "scheme": "light",
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
        XCTAssertEqual(rgba(shell.tabBar.tintColor), [0xad, 0x4b, 0x07, 0xff], "today's selected ink")
        XCTAssertEqual(rgba(shell.tabBar.unselectedItemTintColor), [0, 0, 0, 0x8c])
        XCTAssertEqual(shell.tabBar.overrideUserInterfaceStyle, .light)

        let cleared = state(["inbox_badge": NSNull(), "inbox_dot": false, "visible": false], from: next)
        host.render(cleared)
        XCTAssertNil(shell.tabs.first { $0.identifier == "inbox" }?.badgeValue, "a count of 0 shows nothing")
        XCTAssertTrue(shell.isTabBarHidden, "visible:false hides the strip (calls, covering sheets)")
        host.render(state(["visible": true], from: cleared))
        XCTAssertFalse(shell.isTabBarHidden)
    }

    func testATapForwardsTheKeyAndLeavesTheSelectionToTheWeb() throws {
        let (shell, host, _) = makeShell()
        var taps: [String] = []
        host.onTap = { taps.append($0) }
        host.render(state(["items": four, "selected": "chat", "visible": true]))
        let inbox = try XCTUnwrap(shell.tabs.first { $0.identifier == "inbox" })
        XCTAssertFalse(host.tabBarController(shell, shouldSelectTab: inbox), "the controller never selects on a tap")
        XCTAssertEqual(taps, ["inbox"])
        XCTAssertEqual(shell.selectedTab?.identifier, "chat")
        let chat = try XCTUnwrap(shell.tabs.first { $0.identifier == "chat" })
        XCTAssertFalse(host.tabBarController(shell, shouldSelectTab: chat))
        XCTAssertEqual(taps, ["inbox", "chat"], "a tap on the selected tab still goes to the web (reselect)")
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
}
