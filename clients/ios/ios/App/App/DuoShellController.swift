import UIKit

// iPhone Duo (task 01a1fa7c stage 1). On the Duo the system places a
// UITabBarController's tabs in the closed phone's vertical side strip, and it
// ignores a bare UITabBar ("won't be considered", Tech Talk 111462). So on
// the Duo ONLY the window root is this controller: one tab per web key, each
// a UINavigationController whose root is a thin slot, and the ONE live
// BurrowBridgeViewController moves into whichever slot is selected. Every
// other iPhone and iPad keeps the bridge as the window root with the
// standalone bar (NativeTabBar.swift).

/// Whether this device is an iPhone Duo. Decided once per launch from the
/// model identifier: `verticalBarEdge` cannot decide it, because it is
/// unspecified on the open inner display in portrait, and `UIHingeInteraction`
/// reports the hinge only asynchronously, after a view is on screen, which is
/// too late to choose the window root (clients/ios/README.md, "Hosting").
enum DuoDevice {
    /// The Duo's model identifiers (the iOS 27.2 simulator profile's
    /// `representedModelIdentifiers`).
    static let modelIdentifiers: Set<String> = ["iPhone19,4"]

    /// The hardware model: `SIMULATOR_MODEL_IDENTIFIER` on the simulator
    /// (where `hw.machine` is the Mac's), else `uname`'s machine.
    static func modelIdentifier(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let simulated = environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// True on a Duo running iOS 27.1 or later (the first release with the
    /// vertical bar).
    static func isDuo(model: String) -> Bool {
        guard #available(iOS 27.1, *) else { return false }
        return modelIdentifiers.contains(model)
    }

    /// This launch's answer.
    static let current = isDuo(model: modelIdentifier())
}

/// Where the system draws bars right now. `verticalBarEdge` is set while the
/// vertical side strip is in use (the closed Duo), and unspecified on every
/// other device and posture.
enum DuoLayout {
    static func verticalBarActive(_ traits: UITraitCollection) -> Bool {
        guard #available(iOS 27.1, *) else { return false }
        return traits.verticalBarEdge != .unspecified
    }

    /// Whether the side strip is in use for `controller`. Read from the shell
    /// (and the window), not the content: measured on the iOS 27.2 Duo
    /// simulator, the bridge inside a tab's navigation controller reports
    /// `unspecified` while the shell, window and scene report `trailing`.
    static func verticalBarActive(for controller: UIViewController) -> Bool {
        let candidates = [controller.duoShell?.traitCollection, controller.view.window?.traitCollection, controller.traitCollection]
        return candidates.contains { $0.map(verticalBarActive) ?? false }
    }

    /// Whether the bar sits along the bottom. Open at regular width the
    /// system puts a tab bar controller's tabs at the top, iPad-style (canvas
    /// layout B'), and the web then reserves nothing at the bottom. Decided
    /// from where the bar is, not from a size class: a bar slid off the
    /// bottom by `setTabBarHidden` still counts as bottom.
    static func barAtBottom(barFrameInWindow frame: CGRect, windowHeight: CGFloat?) -> Bool {
        guard let windowHeight, windowHeight > 0 else { return true }
        return frame.midY >= windowHeight / 2
    }
}

/// The app's orientations (task 01a1fa7c stage 2). Every iPhone is
/// portrait-only, as before, except the Duo while it is open: on the inner
/// display Apple's own apps rotate, so the Duo adds landscape there. The
/// plist's iPhone list carries landscape only so this mask can grant it; the
/// app delegate returns this mask for every window, which also caps any
/// controller presented full screen. iPad keeps all four (`~ipad` key).
enum OrientationPolicy {
    /// Open or closed, from the window's shorter side. The iOS 27.2 Duo
    /// profile (both displays @3x): the outer display is 1398 px = 466 pt
    /// wide, the inner one 2007x2853 px = 669x951 pt.
    static let innerDisplayShortSide: CGFloat = 600

    static func isOpen(windowSize: CGSize) -> Bool {
        min(windowSize.width, windowSize.height) >= innerDisplayShortSide
    }

    static func mask(idiom: UIUserInterfaceIdiom, isDuo: Bool, windowSize: CGSize) -> UIInterfaceOrientationMask {
        if idiom == .pad { return .all }
        if isDuo, isOpen(windowSize: windowSize) { return [.portrait, .landscapeLeft, .landscapeRight] }
        return .portrait
    }

    /// The mask for `window` (closed, so portrait, before there is one).
    @MainActor
    static func mask(for window: UIWindow?, isDuo: Bool = DuoDevice.current) -> UIInterfaceOrientationMask {
        mask(idiom: UIDevice.current.userInterfaceIdiom, isDuo: isDuo, windowSize: window?.bounds.size ?? .zero)
    }
}

/// The web's back target (task 01a1fa7c stage 4), from
/// `navBarState({back: {kind: "back" | "close", label} | null})`, the
/// contract of apps/platform/assets/js/hooks/native_back.js.
struct NativeNavBack: Equatable {
    enum Kind: String { case back, close }
    let kind: Kind
    /// The web control's aria-label, else "Back" / "Close". Back shows it as
    /// its title; both read it to VoiceOver.
    let label: String

    /// The target in a `navBarState` payload. `back: null`, a missing key,
    /// an unknown kind or a malformed value all mean no target (a tab root),
    /// so a bad payload clears the item rather than leaving a stale one.
    static func parse(_ payload: [String: Any]) -> NativeNavBack? {
        guard let back = payload["back"] as? [String: Any], let raw = back["kind"] as? String, let kind = Kind(rawValue: raw) else {
            return nil
        }
        let label = (back["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return NativeNavBack(kind: kind, label: label.isEmpty ? defaultLabel(kind) : label)
    }

    static func defaultLabel(_ kind: Kind) -> String { kind == .back ? "Back" : "Close" }
}

/// The strings native shares with native_back.js (pinned both ways by
/// NativeTabBarContractTests and native_back_contract.test.js).
enum NativeNavBarDocument {
    static let method = "navBarState"
    static let tapEvent = "burrowNativeBack"
    /// Set on `<html>` while native draws the Back in the side strip;
    /// app.css then hides every `[data-native-back]` control.
    static let attribute = "data-native-vertical-bar"

    /// The script that sets or clears the attribute, nil off the Duo (the
    /// attribute is never touched there). It is SET only on a Duo whose side
    /// strip is in use; the open Duo clears it, so the web's own control
    /// comes back.
    static func attributeScript(isDuo: Bool, verticalBar: Bool) -> String? {
        guard isDuo else { return nil }
        let call = verticalBar ? "setAttribute(\"\(attribute)\", \"\")" : "removeAttribute(\"\(attribute)\")"
        return "(function (root) { if (root) root.\(call); })(document.documentElement);"
    }

    /// Set on `<html>` on the Duo only. `navBarState` is registered on every
    /// iPhone, so the web needs this to know the bridge can draw anything;
    /// without it native_back.js installs no observer and makes no call.
    static let duoAttribute = "data-native-duo"
    /// Dispatched on `window` right after `duoAttribute` is set, for a hook
    /// that installed before the attribute arrived.
    static let duoEvent = "burrowNativeDuo"

    /// The script that marks a new document as the Duo's, nil on every other
    /// device (the attribute is never set there).
    static func duoScript(isDuo: Bool) -> String? {
        guard isDuo else { return nil }
        return """
            (function (root) {
              if (!root) return;
              root.setAttribute("\(duoAttribute)", "");
              window.dispatchEvent(new Event("\(duoEvent)"));
            })(document.documentElement);
            """
    }

    /// Set on `<html>` while the Duo is open (the inner display), cleared
    /// while it is closed, by `OrientationPolicy.isOpen`, the one definition
    /// of open. It flips live on fold and unfold. Never touched off the Duo.
    static let duoOpenAttribute = "data-native-duo-open"
    /// Dispatched on `window` after every change of `duoOpenAttribute`.
    static let duoPostureEvent = "burrowNativeDuoPosture"

    /// The script that sets (open) or clears (closed) the posture attribute
    /// and announces it, nil off the Duo.
    static func postureScript(isDuo: Bool, open: Bool) -> String? {
        guard isDuo else { return nil }
        let call = open ? "setAttribute(\"\(duoOpenAttribute)\", \"\")" : "removeAttribute(\"\(duoOpenAttribute)\")"
        return """
            (function (root) {
              if (!root) return;
              root.\(call);
              window.dispatchEvent(new Event("\(duoPostureEvent)"));
            })(document.documentElement);
            """
    }
}

/// One tab's page: the root of that tab's UINavigationController (stage 4
/// puts the native Back in its navigation item). It holds the shared web
/// content only while its tab is selected.
@available(iOS 18, *)
final class TabSlotViewController: UIViewController {
    let key: String
    /// The shell this slot belongs to. Held here because a tab's navigation
    /// controller becomes the shell's child only once the shell lays out, and
    /// the content looks its shell up as soon as its view loads.
    weak var shell: DuoShellController?

    init(key: String) {
        self.key = key
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BurrowColor.surface.uiColor
    }

    private(set) var content: UIViewController?

    /// Moves `child` into this slot. Top and bottom run to the slot's edges
    /// (the web pads itself with `env(safe-area-inset-*)`); the sides stop at
    /// the safe area, so the side strip's reserved region is never drawn under
    /// by the composer, a web sheet or a toast.
    func host(_ child: UIViewController) {
        guard content !== child else { return }
        if child.parent != nil {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
        child.didMove(toParent: self)
        content = child
        setNeedsStatusBarAppearanceUpdate()
    }

    /// The native Back or Close at the top of the strip (stage 4): one
    /// leading item, which UIKit draws in place of a system back button
    /// (`leftItemsSupplementBackButton` stays false, Tech Talk 111462). A
    /// leading item, not a pushed placeholder controller, so nothing has to
    /// track the web's history. nil clears it.
    func showNavBack(_ back: NativeNavBack?, action: @escaping () -> Void) {
        guard let back else {
            navigationItem.leadingItemGroups = []
            return
        }
        let handler = UIAction { _ in action() }
        let item: UIBarButtonItem
        switch back.kind {
        case .back:
            // The HIG asks for a title and the symbol together.
            item = UIBarButtonItem(title: back.label, image: UIImage(systemName: "chevron.backward"), primaryAction: handler)
            item.accessibilityIdentifier = "native-nav-back"
        case .close:
            item = UIBarButtonItem(systemItem: .close, primaryAction: handler)
            item.accessibilityIdentifier = "native-nav-close"
        }
        item.accessibilityLabel = back.label
        navigationItem.leftItemsSupplementBackButton = false
        navigationItem.leadingItemGroups = [UIBarButtonItemGroup(barButtonItems: [item], representativeItem: nil)]
    }

    /// Forgets the content once another slot has taken it.
    func release(_ child: UIViewController) {
        if content === child { content = nil }
    }

    // The web content owns the status bar and the home indicator.
    override var childForStatusBarStyle: UIViewController? { content }
    override var childForStatusBarHidden: UIViewController? { content }
    override var childForHomeIndicatorAutoHidden: UIViewController? { content }
}

/// The Duo's window root. It owns the content (the bridge) and which slot
/// holds it; `ControllerTabBarHost` drives its tabs from the web's state.
@available(iOS 18, *)
final class DuoShellController: UITabBarController {
    /// The live web content, re-parented into the selected tab's slot.
    private(set) var content: UIViewController

    /// Each key's tab and navigation controller, kept across tab-list
    /// changes so a key that stays keeps its page (UIKit refuses one view
    /// controller in two tabs).
    private var navigations: [String: UINavigationController] = [:]
    private var tabsByKey: [String: UITab] = [:]

    init(content: UIViewController, keys: [String] = NativeTab.catalog.map(\.key)) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
        // Never the iPad-style sidebar (the README spike saw one at regular
        // width); the system still places the bar in the side strip.
        mode = .tabBar
        // Hidden until the web's first `tabBarState` (as the standalone bar).
        isTabBarHidden = true
        setTabs(makeTabs(for: keys), animated: false)
        selectedTab = tabs.first
        // UIKit may already have loaded this controller's view above, so the
        // content is placed here rather than in viewDidLoad.
        placeContent()
        // Folding or unfolding changes the window's size (and with it the
        // orientation mask): ask the system to re-read the mask.
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) {
            (shell: DuoShellController, _: UITraitCollection) in
            shell.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    /// A tab per known key: the glyph and title of `NativeTabBarFactory.item`,
    /// and a navigation controller whose root is that key's slot.
    func makeTabs(for keys: [String]) -> [UITab] {
        keys.compactMap { NativeTab.named($0) }.enumerated().map { index, tab in
            if let existing = tabsByKey[tab.key] { return existing }
            let item = NativeTabBarFactory.item(tab, index: index)
            let navigation = navigation(for: tab.key)
            let made = UITab(title: item.title ?? tab.title, image: item.image, identifier: tab.key) { _ in navigation }
            tabsByKey[tab.key] = made
            return made
        }
    }

    private func navigation(for key: String) -> UINavigationController {
        if let existing = navigations[key] { return existing }
        let slot = TabSlotViewController(key: key)
        slot.shell = self
        let navigation = UINavigationController(rootViewController: slot)
        // Hidden until the side strip is in use (`renderNavBack`).
        navigation.setNavigationBarHidden(!navBarShown, animated: false)
        navigations[key] = navigation
        return navigation
    }

    // MARK: Native Back (stage 4)

    /// The web's back target, drawn in the selected slot only.
    private(set) var navBack: NativeNavBack?
    /// Whether the side strip is in use: the navigation bars show only then.
    /// Everywhere else (the open Duo, inner portrait included) they stay
    /// hidden and the web header keeps its own control.
    private(set) var navBarShown = false
    /// The item's tap: the bridge fires `burrowNativeBack`.
    var onNavBack: (() -> Void)?

    /// Draws `back` (nil: none) in the selected slot, clears every other
    /// slot, and shows the navigation bars only while `verticalBar` and
    /// while the strip shows (`tabsShown`, the bridge's
    /// `NativeTabBarState.stripShown`). Since stage 5 the web hiding its
    /// floating bar (a call, a full-screen viewer, the composer focused)
    /// does NOT hide the strip; only a page that sends no state does, and
    /// then the Back hides with the tabs and the web shows its own.
    func renderNavBack(_ back: NativeNavBack?, verticalBar: Bool, tabsShown: Bool = true) {
        navBack = back
        navBarShown = verticalBar && tabsShown
        applyNavBack()
    }

    private func applyNavBack() {
        let selected = selectedSlot
        for (_, navigation) in navigations {
            guard let slot = navigation.viewControllers.first as? TabSlotViewController else { continue }
            slot.showNavBack(slot === selected ? navBack : nil) { [weak self] in self?.onNavBack?() }
            if navigation.isNavigationBarHidden == navBarShown {
                navigation.setNavigationBarHidden(!navBarShown, animated: false)
            }
        }
    }

    /// The keys of the tabs, in order.
    var keys: [String] { tabs.map(\.identifier) }

    /// Any change of selection moves the content, so editing ends while the
    /// content is still in the old, on-screen slot (see `placeContent`):
    /// UIKit takes the old tab's page off screen inside this setter.
    override var selectedTab: UITab? {
        willSet {
            if newValue !== selectedTab { endEditingBeforeMove() }
        }
    }

    /// The slot of `tab`.
    func slot(of tab: UITab?) -> TabSlotViewController? {
        tab.flatMap { navigations[$0.identifier]?.viewControllers.first as? TabSlotViewController }
    }

    /// The slot holding the content, nil before any tab exists.
    var selectedSlot: TabSlotViewController? { slot(of: selectedTab) }

    /// Puts the content in the selected tab's slot (a no-op when it is
    /// already there). Called after every selection or tab-list change.
    ///
    /// A move ends editing first (task 01a1fa7c stage 5). Re-parenting the
    /// web view while it is first responder, its text input session live,
    /// can leave the keyboard host attached to the old slot: the next focus
    /// shows the accessory bar with no keys until a relaunch. So when the
    /// content is about to change slot and anything in it is first
    /// responder, it resigns (WebKit blurs the focused field) before the
    /// view leaves its superview, and the next tap starts a fresh session in
    /// the new slot.
    func placeContent() {
        guard let target = selectedSlot else { return }
        if target.content !== content { endEditingBeforeMove() }
        for tab in tabs where slot(of: tab) !== target { slot(of: tab)?.release(content) }
        target.host(content)
        // The Back follows the content into the newly selected slot.
        applyNavBack()
    }

    /// How many moves found the content editing and ended it first (the
    /// DEBUG fixture and the tests read it).
    private(set) var editingEndedForMove = 0

    /// Resigns whatever in the content is first responder, while the content
    /// is still in its old slot. A no-op when nothing is editing. The
    /// controller host also calls it for a tap, before the system selects.
    func endEditingBeforeMove() {
        guard content.isViewLoaded, content.view.window != nil, Self.firstResponder(in: content.view) != nil else { return }
        content.view.endEditing(true)
        editingEndedForMove += 1
    }

    /// The first responder in `view`'s subtree, nil when there is none.
    static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let found = firstResponder(in: subview) { return found }
        }
        return nil
    }

    /// Web-load recovery on the Duo: a fresh bridge replaces ONLY the
    /// content. The window root, the tabs and the selection stay.
    func replaceContent(with replacement: UIViewController) {
        endEditingBeforeMove()
        let old = content
        for tab in tabs { slot(of: tab)?.release(old) }
        old.willMove(toParent: nil)
        old.view.removeFromSuperview()
        old.removeFromParent()
        content = replacement
        placeContent()
    }

    /// The window root for `content`: this shell on the Duo, the content
    /// itself everywhere else.
    static func root(for content: UIViewController, isDuo: Bool) -> UIViewController {
        isDuo ? DuoShellController(content: content) : content
    }
}

extension UIViewController {
    /// The Duo shell this controller sits in, nil off the Duo.
    var duoShell: UIViewController? {
        guard #available(iOS 18, *) else { return nil }
        var current = parent
        while let node = current {
            if node is DuoShellController { return node }
            if let slot = node as? TabSlotViewController, let shell = slot.shell { return shell }
            current = node.parent
        }
        return nil
    }
}

/// The content under a window root: the shell's content on the Duo, the root
/// itself everywhere else.
enum ShellRoot {
    static func content(of root: UIViewController?) -> UIViewController? {
        if #available(iOS 18, *), let shell = root as? DuoShellController { return shell.content }
        return root
    }
}
