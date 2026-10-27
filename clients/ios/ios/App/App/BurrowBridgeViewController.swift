import AuthenticationServices
import Capacitor
import Combine
import SwiftUI
import UIKit
import UserNotifications
import WebKit

/// The shell: Capacitor's bridge around the selected install's web UI.
///
/// - edge to edge (`contentInsetAdjustmentBehavior = .never`); the web UI
///   pads itself with `env(safe-area-inset-*)` (`viewport-fit=cover` in
///   root.html.heex);
/// - the status bar follows the web UI's theme, read from `data-theme`;
/// - the install host stays in the view, every other host opens in Safari
///   (NavigationPolicy, applied through `SuiteNative.shouldOverrideLoad`);
/// - pull-to-refresh is a UIRefreshControl in the base-content colour, off
///   on `/chat` paths.
final class BurrowBridgeViewController: CAPBridgeViewController {
    private let store = InstallStore.shared
    private let plugin = BurrowNativePlugin()
    private let meetingsPlugin = BurrowMeetingsPlugin()
    private var callScreen: UIViewController?
    private var callObservation: AnyCancellable?
    private var activeObservation: NSObjectProtocol?
    private var incomingObservation: AnyCancellable?
    private var incomingPrompt: UIViewController?
    private(set) var currentInstall: Install?
    private var policy: NavigationPolicy?
    private var auth: AuthSession?
    private let refresh = UIRefreshControl()
    private var urlObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private var webStatusBarStyle: UIStatusBarStyle?
    private var didStart = false
    private var pickerHost: UIViewController?
    private let launcher = InstallLauncher()
    private let switchBanner = SwitchBannerPresenter()
    private var badgesObservation: NSObjectProtocol?
    /// Hides the web view while it is between installs, so one install's
    /// page never shows under another's sign-in sheet.
    private let cover = UIView()
    /// When the shell last asked for a handoff; a web `/auth/login` right
    /// after one means the handoff did not take, so sign in natively.
    private var lastHandoffAt: Date?
    /// The install a native sign-out is running for, until it finishes.
    private var signingOutHost: String?
    /// Set by SceneDelegate when the app was cold-launched from the
    /// Switch install quick action.
    var startOnPicker = false
    /// Set by SceneDelegate when a widget's deep link cold-launched the app.
    var pendingDeepLink: DeepLink?

    /// The native tab bar (task 01a1557b), hidden until the web's first
    /// `tabBarState`.
    private var tabBarHost: NativeTabBarHosting?
    private(set) var tabBarState = NativeTabBarState()
    /// Bumped by the document-start script for every new main-frame
    /// document; a document that sends no state by didFinish (plus a grace)
    /// hides the bar.
    private var documentGeneration = 0
    private var documentSentState = false
    /// Hosts that already have the document-start script.
    private var tabBarScriptHosts = Set<String>()
    private var pushedTabBarHeight: CGFloat?
    private var backdropObservation: NSKeyValueObservation?
    private var backdropSampling = false

    /// DEBUG only: `-BurrowLoginProbe <host>` loads that host's `/auth/login`
    /// with no navigation policy at all, to measure a plain in-WKWebView
    /// pocket-id login (README, Login).
    private var loginProbeHost: String? {
        #if DEBUG
            return UserDefaults.standard.string(forKey: "BurrowLoginProbe")
        #else
            return nil
        #endif
    }

    // MARK: Capacitor hooks

    override func capacitorDidLoad() {
        plugin.shell = self
        bridge?.registerPluginInstance(plugin)
        // Native meetings (task 01a10db7 stage 3), beside `SuiteNative`.
        meetingsPlugin.shell = self
        bridge?.registerPluginInstance(meetingsPlugin)
        // CapacitorBridge.init makes its own CAPNotificationRouter the
        // notification delegate unless `ios.handleApplicationNotifications`
        // is false. That config line is the first guard; this is the second,
        // so Reply, Open and a tap always reach NotificationRouter.shared.
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BurrowColor.surface.uiColor
        guard let webView else { return }
        webView.isOpaque = false
        webView.backgroundColor = BurrowColor.surface.uiColor
        webView.scrollView.backgroundColor = BurrowColor.surface.uiColor
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = true

        cover.backgroundColor = BurrowColor.surface.uiColor
        cover.frame = webView.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.isHidden = true
        webView.addSubview(cover)
        installTabBar()
        webView.configuration.userContentController.add(
            WeakScriptMessageHandler(self), name: NativeTabBarDocument.messageName)

        refresh.tintColor = BurrowColor.onSurface.uiColor
        refresh.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)

        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async { self?.webViewURLChanged(webView.url) }
        }
        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
            guard !webView.isLoading else { return }
            DispatchQueue.main.async {
                self?.refresh.endRefreshing()
                self?.syncStatusBarWithWebTheme()
                self?.uncoverIfOnCurrentInstall(webView.url)
                self?.hideTabBarUnlessDocumentSendsState()
            }
        }

        // The in-call screen (stage 4): full screen while the call wants it
        // presented, through the ended screen until Done.
        callObservation = CallController.shared.$presented
            .receive(on: DispatchQueue.main)
            .sink { [weak self] presented in self?.syncCallScreen(presented) }
        // The simulator's in-app incoming ring (RingCenter.systemEndsIncomingCalls).
        incomingObservation = RingWaiting.shared.$incoming
            .map { $0?.invite }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] invite in self?.syncIncomingPrompt(invite) }
        CallController.shared.openWeb = { [weak self] host, path in
            self?.openCallPage(host: host, path: path)
        }
        // Back in the app (the Lock Screen Burrow button, Recents) with a
        // call up: show the call again.
        activeObservation = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in CallController.shared.reopen() }
        }

        NotificationRouter.shared.openHandler = { [weak self] install, url in
            guard let self else { return }
            // Task 01a1261e: a tap that moves the app to ANOTHER install says so.
            let switching = SwitchBanner.shouldShow(currentHost: self.currentInstall?.host, targetHost: install.host)
            self.open(install, at: url)
            if switching { self.switchBanner.show(SwitchBanner.message(install.displayName), in: self) }
        }

        // Per-install unread changed: the web shell re-asks
        // `SuiteNative.installBadges()` (task 01a1261e; contract from stage 3).
        badgesObservation = NotificationCenter.default.addObserver(
            forName: .burrowInstallBadgesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.bridge?.triggerWindowJSEvent(eventName: "burrowInstallBadges")
        }

        // An App Intent opening a space, task or meeting. Before the shell
        // has started, the link waits for viewDidAppear.
        IntentNavigator.handler = { [weak self] link in
            guard let self else { return }
            if self.didStart {
                self.open(link)
            } else {
                self.pendingDeepLink = link
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        #if DEBUG
            DebugVoIPSeam.applyLaunchArgument()
            if startMeetingProbe() { return }
            if startTabBarFixture() { return }
        #endif

        if let host = loginProbeHost {
            webView?.load(URLRequest(url: URL(string: "https://\(host)/auth/login")!))
            return
        }
        if let link = pendingDeepLink ?? IntentNavigator.takePending() {
            pendingDeepLink = nil
            open(link)
        } else if let (install, url) = NotificationRouter.shared.takePendingOpen() {
            open(install, at: url)
        } else if !startOnPicker, store.hasConfirmedSelection, let install = store.selectedInstall {
            open(install, at: nil)
        } else {
            presentPicker()
        }
    }

    // MARK: Native in-call screen (stage 4)

    private func syncCallScreen(_ presented: Bool) {
        if presented, callScreen == nil {
            let host = InCallHostingController(rootView: InCallScreen(controller: CallController.shared))
            host.modalPresentationStyle = .fullScreen
            callScreen = host
            // Not on a sheet that is on its way out (the in-app ring prompt
            // dismissing as its Answer joins).
            let presenter = presentedViewController.flatMap { $0.isBeingDismissed ? nil : $0 } ?? self
            presenter.present(host, animated: true)
        } else if !presented, let screen = callScreen {
            callScreen = nil
            screen.dismiss(animated: true)
        }
    }

    private func syncIncomingPrompt(_ invite: RingInvite?) {
        if let invite, incomingPrompt == nil {
            let waiting = RingWaiting.shared
            let host = InCallHostingController(
                rootView: IncomingRingPrompt(
                    invite: invite, decline: { waiting.declineIncoming() }, answer: { waiting.answerIncoming() }))
            host.modalPresentationStyle = .overFullScreen
            incomingPrompt = host
            var top: UIViewController = self
            while let next = top.presentedViewController { top = next }
            top.present(host, animated: true)
        } else if invite == nil, let prompt = incomingPrompt {
            incomingPrompt = nil
            prompt.dismiss(animated: true)
        }
    }

    /// "Open full meeting" and "Open the space": the page on the call's
    /// install, switching installs only when the call's is not loaded.
    private func openCallPage(host: String, path: String) {
        guard let url = URL(string: "https://\(host)\(path)") else { return }
        if currentInstall?.host.lowercased() == host.lowercased() {
            webView?.load(URLRequest(url: url))
        } else if let install = store.add(host: host) {
            open(install, at: url)
        }
    }

    #if DEBUG
        /// DEBUG measurement (stage 3): `BURROW_MEETING_PROBE_URL` /
        /// `_TOKEN` / `_ROOM` in the launch environment connect a native call
        /// straight to a LiveKit server, skipping sign-in. Values are never
        /// logged. The legacy SUITE_ spellings of these names still work.
        private func startMeetingProbe() -> Bool {
            guard let url = env("BURROW_MEETING_PROBE_URL", "SUITE_MEETING_PROBE_URL"),
                let credential = env("BURROW_MEETING_PROBE_TOKEN", "SUITE_MEETING_PROBE_TOKEN")
            else {
                return false
            }
            CallController.shared.startProbe(
                url: url, token: credential,
                roomName: env("BURROW_MEETING_PROBE_ROOM", "SUITE_MEETING_PROBE_ROOM") ?? "probe",
                meetingName: env("BURROW_MEETING_PROBE_NAME", "SUITE_MEETING_PROBE_NAME") ?? "Design review",
                useCallKit: env("BURROW_MEETING_PROBE_CALLKIT", "SUITE_MEETING_PROBE_CALLKIT") != "0")
            return true
        }

        /// Legacy names already reported, so each warns once per process.
        private static var warnedLegacyEnv = Set<String>()

        /// The launch-environment value of `burrow`, else of the legacy
        /// `suite` name with one deprecation line. Empty counts as unset.
        /// Logs the names only, never the value.
        private func env(_ burrow: String, _ suite: String) -> String? {
            let environment = ProcessInfo.processInfo.environment
            if let value = environment[burrow], !value.isEmpty { return value }
            guard let value = environment[suite], !value.isEmpty else { return nil }
            if Self.warnedLegacyEnv.insert(suite).inserted {
                NSLog("deprecated: %@ is set; rename it to %@", suite, burrow)
            }
            return value
        }
    #endif

    // MARK: Native tab bar (task 01a1557b)

    private func installTabBar() {
        guard tabBarHost == nil else { return }
        let host = NativeTabBarFactory.make()
        host.install(in: self)
        host.onTap = { [weak self] key in self?.tabTapped(key) }
        host.render(tabBarState)
        tabBarHost = host
    }

    /// `SuiteNative.tabBarState` from the web.
    func applyTabBarState(_ payload: [String: Any]) {
        documentSentState = true
        tabBarState = tabBarState.applying(payload)
        tabBarHost?.render(tabBarState)
        observeBackdrop()
        for delay in [0.15, 0.7, 1.6] { scheduleBackdropSample(after: delay) }
        #if DEBUG
            reportTabBarFixture()
        #endif
    }

    // MARK: Backdrop (task 01a174e8 stage 3, option 1)

    /// Re-samples the content under the bar while the page scrolls.
    private func observeBackdrop() {
        guard backdropObservation == nil, let scrollView = webView?.scrollView else { return }
        backdropObservation = scrollView.observe(\.contentOffset, options: []) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleBackdropSample(after: 0.2) }
        }
    }

    private func scheduleBackdropSample(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.sampleBackdrop() }
    }

    /// Snapshots the web content behind the bar and gives the bar the style
    /// that matches it.
    private func sampleBackdrop() {
        guard let webView, let host = tabBarHost, !host.bar.isHidden else { return }
        // Reduce Transparency draws the bar as a solid system fill: nothing
        // behind it shows through, so the web's own scheme and inks stand.
        if UIAccessibility.isReduceTransparencyEnabled {
            host.applyBackdrop(nil)
            return
        }
        guard !backdropSampling else { return }
        let area = webView.convert(host.bar.bounds, from: host.bar).intersection(webView.bounds)
        guard !area.isNull, area.width > 1, area.height > 1 else { return }
        backdropSampling = true
        // A snapshot that never calls back must not stop later samples.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.backdropSampling = false }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = area
        configuration.snapshotWidth = 64
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.backdropSampling = false
                guard let cgImage = image?.cgImage, let luminance = NativeTabBarBackdrop.luminance(of: cgImage) else {
                    #if DEBUG
                        NativeTabBarProbe.lastBackdrop = "snapshot-failed"
                    #endif
                    return
                }
                #if DEBUG
                    NativeTabBarProbe.lastBackdrop = String(format: "%.3f", luminance)
                #endif
                #if DEBUG
                    let before = self.tabBarHost?.bar.overrideUserInterfaceStyle
                #endif
                let current = (self.tabBarHost as? StandaloneTabBarHost)?.backdropStyle
                self.tabBarHost?.applyBackdrop(NativeTabBarBackdrop.style(forLuminance: luminance, current: current))
                #if DEBUG
                    // Only the flat backdrop pages wait on the style; a report at
                    // a random moment could catch a tap mid-flight on the others.
                    let onBackdropPage = self.webView?.url?.query?.contains("backdrop=") == true
                    if onBackdropPage, before != self.tabBarHost?.bar.overrideUserInterfaceStyle { self.reportTabBarFixture() }
                #endif
            }
        }
    }

    /// A tap: `burrowNativeTab` with `{key, reselect}`. Tapping the selected
    /// tab is a reselect; the web decides what that does.
    private func tabTapped(_ key: String) {
        let detail: [String: Any] = ["key": key, "reselect": tabBarState.isReselect(key)]
        guard let data = try? JSONSerialization.data(withJSONObject: ["detail": detail]), let json = String(data: data, encoding: .utf8) else { return }
        bridge?.triggerWindowJSEvent(eventName: NativeTabBarDocument.tapEvent, data: json)
    }

    /// The document-start script for `host`: marks `<html data-native-tab-bar>`
    /// and sets `--native-tab-bar-height` on that host's pages only. Added
    /// once per host; each copy checks its own host.
    private func addTabBarScript(host: String) {
        let key = host.lowercased()
        guard let webView, tabBarScriptHosts.insert(key).inserted else { return }
        let script = WKUserScript(
            source: NativeTabBarDocument.script(host: key, height: currentTabBarHeight()),
            injectionTime: .atDocumentStart, forMainFrameOnly: true)
        webView.configuration.userContentController.addUserScript(script)
    }

    /// A new main-frame document started (any host).
    fileprivate func tabBarDocumentStarted() {
        documentGeneration += 1
        documentSentState = false
        pushedTabBarHeight = nil
        pushTabBarHeight()
    }

    /// didFinish: a document that has sent no state after the LiveView
    /// connect grace (sign-in, guest pages, pages with no rail) hides the bar.
    /// A document that does send one keeps it, with no hide/show blink.
    private func hideTabBarUnlessDocumentSendsState() {
        let generation = documentGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + NativeTabBarDocument.stateGrace) { [weak self] in
            guard let self, self.documentGeneration == generation, !self.documentSentState, self.tabBarState.visible else { return }
            self.tabBarState.visible = false
            self.tabBarHost?.render(self.tabBarState)
            #if DEBUG
                self.reportTabBarFixture()
            #endif
        }
    }

    private func currentTabBarHeight() -> CGFloat {
        guard let bar = tabBarHost?.bar else { return 0 }
        return NativeTabBarFactory.heightAboveSafeArea(barHeight: bar.frame.height, safeAreaBottom: view.safeAreaInsets.bottom)
    }

    /// Keeps `--native-tab-bar-height` current on layout and rotation.
    private func pushTabBarHeight() {
        let height = currentTabBarHeight()
        guard height > 0, height != pushedTabBarHeight else { return }
        pushedTabBarHeight = height
        webView?.evaluateJavaScript(NativeTabBarDocument.heightUpdate(height))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        pushTabBarHeight()
    }

    #if DEBUG
        /// DEBUG only: `-BurrowTabBarFixture YES` loads the bundled
        /// `tabbar-fixture.html` (a fake web side) in place of an install,
        /// under the native tab bar. `-BurrowTabBarFixtureAppearance
        /// light|dark` pins the appearance for screenshots.
        private func startTabBarFixture() -> Bool {
            let defaults = UserDefaults.standard
            guard defaults.string(forKey: "BurrowTabBarFixture") != nil else { return false }
            switch defaults.string(forKey: "BurrowTabBarFixtureAppearance") {
            case "dark": view.window?.overrideUserInterfaceStyle = .dark
            case "light": view.window?.overrideUserInterfaceStyle = .light
            default: break
            }
            guard let base = bridge?.config.serverURL else { return true }
            view.layoutIfNeeded()
            addTabBarScript(host: base.host ?? "localhost")
            webView?.load(URLRequest(url: base.appendingPathComponent("tabbar-fixture.html")))
            return true
        }

        /// Hands the fixture page the probe of what the system drew.
        private func reportTabBarFixture() {
            guard UserDefaults.standard.string(forKey: "BurrowTabBarFixture") != nil, let host = tabBarHost, let root = webView else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                var report = NativeTabBarProbe.report(bar: host.bar, root: root)
                report["hosting"] = "standalone"
                report["rendered"] = NativeTabBarProbe.rendered(bar: host.bar, keys: host.renderedKeys)
                guard let data = try? JSONSerialization.data(withJSONObject: report), let json = String(data: data, encoding: .utf8) else { return }
                self?.webView?.evaluateJavaScript("window.burrowFixtureNative && window.burrowFixtureNative(\(json))")
            }
        }
    #endif

    // MARK: Install lifecycle

    /// Loads an install. With a bearer in the Keychain the web view is
    /// signed in through `POST /api/app/handoff` (InstallLauncher); without
    /// one, or on a 401, sign in natively.
    func open(_ install: Install, at url: URL?) {
        dismissPicker()
        if currentInstall?.host != install.host {
            // Between installs: hide the old page until the new one loads.
            cover.isHidden = false
            webView?.stopLoading()
        }
        currentInstall = install
        signingOutHost = nil
        policy = NavigationPolicy(installHost: install.host)
        addTabBarScript(host: install.host)
        let switched = store.selectedHost != install.host
        store.select(install.host)
        store.confirmSelection()
        if switched { WidgetCountsRefresher.refresh(host: install.host) }
        launch(install, at: url)
    }

    private func launch(_ install: Install, at url: URL?) {
        lastHandoffAt = Date()
        launcher.start(install: install, destination: url) { [weak self] step in
            DispatchQueue.main.async {
                guard let self, self.currentInstall?.host == install.host else { return }
                switch step {
                case .load(let target): self.webView?.load(URLRequest(url: target))
                case .signIn: self.signIn(to: install, then: url)
                }
            }
        }
    }

    private func uncoverIfOnCurrentInstall(_ url: URL?) {
        guard let host = url?.host?.lowercased(), host == currentInstall?.host.lowercased() else { return }
        cover.isHidden = true
    }

    /// The web "Log out": revoke the device and the session, forget the
    /// bearer, then run the web `/auth/logout` in the view. Its redirect to
    /// the identity provider's end-session page is not opened in Safari;
    /// the sign-out ends on the install picker.
    func signOut(of install: Install) {
        signingOutHost = install.host
        cover.isHidden = false
        IntentAppHooks.forget(host: install.host)
        NativeSignOut().run(host: install.host) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.signingOutHost == install.host else { return }
                WidgetCountsRefresher.refresh(host: install.host)
                self.webView?.load(URLRequest(url: install.baseURL.appendingPathComponent("auth/logout")))
            }
        }
    }

    private func finishSignOut() {
        signingOutHost = nil
        currentInstall = nil
        policy = nil
        presentPicker()
    }

    /// A widget's `burrow://open?host=…&path=…`: switch to that install
    /// (adding it if it was removed) and open the page.
    func open(_ link: DeepLink) {
        guard let install = store.add(host: link.host) else { return }
        open(install, at: link.destination)
    }

    func signIn(to install: Install, then url: URL?) {
        let session = AuthSession(install: install) { [weak self] in
            self?.view.window ?? ASPresentationAnchor()
        }
        auth = session
        session.start { [weak self] result in
            guard let self else { return }
            self.auth = nil
            switch result {
            case .success(let handoff):
                self.webView?.load(URLRequest(url: handoff))
                // A fresh bearer: tell this install where to ring.
                VoIPRegistrar.shared.registerWithSignedInInstalls()
            case .failure:
                self.presentPicker()
            }
        }
    }

    func presentPicker() {
        guard pickerHost == nil else { return }
        let model = InstallPickerModel(store: store, refreshUnread: { UnreadReconciler.refreshAll() })
        let picker = InstallPickerView(model: model) { [weak self] install in
            self?.open(install, at: nil)
        }
        let host = UIHostingController(rootView: picker)
        host.modalPresentationStyle = .fullScreen
        host.view.backgroundColor = BurrowColor.surface.uiColor
        pickerHost = host
        (presentedViewController ?? self).present(host, animated: currentInstall != nil)
    }

    private func dismissPicker() {
        guard let host = pickerHost else { return }
        pickerHost = nil
        host.dismiss(animated: true)
    }

    // MARK: Navigation policy

    /// Returns true when the navigation was taken over (cancelled).
    func handle(_ action: WKNavigationAction) -> Bool {
        if loginProbeHost != nil { return false }
        guard let policy, let install = currentInstall else { return false }
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        let decision = policy.decide(url: action.request.url, isMainFrame: isMainFrame)
        if signingOutHost == install.host {
            switch decision {
            case .signOut:
                // The shell's own load of /auth/logout, after NativeSignOut.
                return false
            case .openExternally, .startNativeLogin:
                // The end-session redirect, or the signed-out install asking
                // for a login: the sign-out is done.
                DispatchQueue.main.async { self.finishSignOut() }
                return true
            case .allow:
                return false
            }
        }
        switch decision {
        case .allow:
            return false
        case .openExternally:
            if let url = action.request.url {
                UIApplication.shared.open(url)
            }
            return true
        case .startNativeLogin:
            DispatchQueue.main.async {
                // A handoff that did not take lands here; do not loop on it.
                if let last = self.lastHandoffAt, Date().timeIntervalSince(last) < 15 {
                    self.signIn(to: install, then: nil)
                } else {
                    self.launch(install, at: nil)
                }
            }
            return true
        case .signOut:
            DispatchQueue.main.async { self.signOut(of: install) }
            return true
        }
    }

    // MARK: Pull to refresh, status bar

    private func webViewURLChanged(_ url: URL?) {
        annotateEntity(url)
        guard let scrollView = webView?.scrollView else { return }
        let allowed = url.map { NavigationPolicy.allowsPullToRefresh(path: $0.path) } ?? false
        if allowed, scrollView.refreshControl == nil {
            scrollView.refreshControl = refresh
        } else if !allowed, scrollView.refreshControl != nil {
            refresh.endRefreshing()
            scrollView.refreshControl = nil
        }
    }

    /// On `/chat/<segment>` or `/tasks/<id>`, the current activity names
    /// that entity (iOS 18.2+), for Apple Intelligence's onscreen
    /// understanding. Anywhere else the activity is cleared.
    private func annotateEntity(_ url: URL?) {
        guard let host = currentInstall?.host, let activity = EntityActivity.activity(for: url, host: host) else {
            userActivity?.resignCurrent()
            userActivity = nil
            return
        }
        userActivity = activity
        activity.becomeCurrent()
        // A space or task the person opened is donated (ids and its name).
        if let event = EntityActivity.donationEvent(for: url, host: host) { Donations.shared.donate(event) }
    }

    @objc private func pullToRefresh() {
        webView?.reload()
    }

    /// The status bar sits over the web UI's top bar, so its style follows
    /// the web theme (the person can pick a theme in Burrow that differs from
    /// iOS). Without a readable theme it follows the system appearance.
    private func syncStatusBarWithWebTheme() {
        webView?.evaluateJavaScript("document.documentElement.getAttribute('data-theme')") { [weak self] value, _ in
            guard let self else { return }
            let theme = value as? String
            let dark: Bool
            switch theme {
            case "dark": dark = true
            case "light": dark = false
            default: dark = self.traitCollection.userInterfaceStyle == .dark
            }
            let style: UIStatusBarStyle = dark ? .lightContent : .darkContent
            guard style != self.webStatusBarStyle else { return }
            self.webStatusBarStyle = style
            // Capacitor owns preferredStatusBarStyle; this is its setter.
            self.setStatusBarStyle(style)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        syncStatusBarWithWebTheme()
    }
}

// MARK: Native tab bar document contract (task 01a1557b)

/// The strings the web side matches (clients/ios/README.md, "Native tab bar").
enum NativeTabBarDocument {
    static let attribute = "data-native-tab-bar"
    static let heightVariable = "--native-tab-bar-height"
    static let tapEvent = "burrowNativeTab"
    static let messageName = "burrowNativeDocument"
    /// After didFinish, how long a new document has to send its first
    /// `tabBarState` (the LiveView connect) before the bar hides.
    static let stateGrace: TimeInterval = 2.5

    /// Runs at document start in every main frame: pings native that a new
    /// document began, then marks the page only when it is on `host`.
    static func script(host: String, height: CGFloat) -> String {
        let literal = (try? JSONSerialization.data(withJSONObject: [host])).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
            (function () {
              try { window.webkit.messageHandlers.\(messageName).postMessage(1); } catch (e) {}
              if (location.host.toLowerCase() !== \(literal)[0]) return;
              var root = document.documentElement;
              root.setAttribute("\(attribute)", "");
              root.style.setProperty("\(heightVariable)", "\(Int(height))px");
            })();
            """
    }

    /// Updates the variable on a page that carries the attribute.
    static func heightUpdate(_ height: CGFloat) -> String {
        """
        (function (root) {
          if (root && root.hasAttribute("\(attribute)")) root.style.setProperty("\(heightVariable)", "\(Int(height))px");
        })(document.documentElement);
        """
    }
}

/// Holds the shell weakly, so the user content controller does not retain it.
@MainActor
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var shell: BurrowBridgeViewController?

    init(_ shell: BurrowBridgeViewController) { self.shell = shell }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        shell?.tabBarDocumentStarted()
    }
}
