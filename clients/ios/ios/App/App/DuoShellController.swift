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
        // Stage 1 draws no navigation bar; stage 4 shows it in the strip.
        navigation.setNavigationBarHidden(true, animated: false)
        navigations[key] = navigation
        return navigation
    }

    /// The keys of the tabs, in order.
    var keys: [String] { tabs.map(\.identifier) }

    /// The slot of `tab`.
    func slot(of tab: UITab?) -> TabSlotViewController? {
        tab.flatMap { navigations[$0.identifier]?.viewControllers.first as? TabSlotViewController }
    }

    /// The slot holding the content, nil before any tab exists.
    var selectedSlot: TabSlotViewController? { slot(of: selectedTab) }

    /// Puts the content in the selected tab's slot (a no-op when it is
    /// already there). Called after every selection or tab-list change.
    func placeContent() {
        guard let target = selectedSlot else { return }
        for tab in tabs where slot(of: tab) !== target { slot(of: tab)?.release(content) }
        target.host(content)
    }

    /// Web-load recovery on the Duo: a fresh bridge replaces ONLY the
    /// content. The window root, the tabs and the selection stay.
    func replaceContent(with replacement: UIViewController) {
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
