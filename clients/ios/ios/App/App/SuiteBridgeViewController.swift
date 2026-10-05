import AuthenticationServices
import Capacitor
import SwiftUI
import UserNotifications
import UIKit
import WebKit

/// The shell: Capacitor's bridge around the selected install's web UI.
///
/// - edge to edge (`contentInsetAdjustmentBehavior = .never`); the web UI
///   pads itself with `env(safe-area-inset-*)` (`viewport-fit=cover` in
///   root.html.heex);
/// - the status bar follows the web UI's theme, read from `data-theme`;
/// - the install host stays in the view, every other host opens in Safari
///   (NavigationPolicy, applied through SuiteNative.shouldOverrideLoad);
/// - pull-to-refresh is a UIRefreshControl in the base-content colour, off
///   on `/chat` paths.
final class SuiteBridgeViewController: CAPBridgeViewController {
    private let store = InstallStore.shared
    private let plugin = SuiteNativePlugin()
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

    /// DEBUG only: `-SuiteLoginProbe <host>` loads that host's `/auth/login`
    /// with no navigation policy at all, to measure a plain in-WKWebView
    /// pocket-id login (README, Login).
    private var loginProbeHost: String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "SuiteLoginProbe")
        #else
        return nil
        #endif
    }

    // MARK: Capacitor hooks

    override func capacitorDidLoad() {
        plugin.shell = self
        bridge?.registerPluginInstance(plugin)
        // CapacitorBridge.init makes its own CAPNotificationRouter the
        // notification delegate unless `ios.handleApplicationNotifications`
        // is false. That config line is the first guard; this is the second,
        // so Reply, Open and a tap always reach NotificationRouter.shared.
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = SuiteColor.surface.uiColor
        guard let webView else { return }
        webView.isOpaque = false
        webView.backgroundColor = SuiteColor.surface.uiColor
        webView.scrollView.backgroundColor = SuiteColor.surface.uiColor
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = true

        cover.backgroundColor = SuiteColor.surface.uiColor
        cover.frame = webView.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.isHidden = true
        webView.addSubview(cover)

        refresh.tintColor = SuiteColor.onSurface.uiColor
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
            }
        }

        NotificationRouter.shared.openHandler = { [weak self] install, url in
            self?.open(install, at: url)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true

        if let host = loginProbeHost {
            webView?.load(URLRequest(url: URL(string: "https://\(host)/auth/login")!))
            return
        }
        if let link = pendingDeepLink {
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
            case .failure:
                self.presentPicker()
            }
        }
    }

    func presentPicker() {
        guard pickerHost == nil else { return }
        let model = InstallPickerModel(store: store)
        let picker = InstallPickerView(model: model) { [weak self] install in
            self?.open(install, at: nil)
        }
        let host = UIHostingController(rootView: picker)
        host.modalPresentationStyle = .fullScreen
        host.view.backgroundColor = SuiteColor.surface.uiColor
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
        guard let scrollView = webView?.scrollView else { return }
        let allowed = url.map { NavigationPolicy.allowsPullToRefresh(path: $0.path) } ?? false
        if allowed, scrollView.refreshControl == nil {
            scrollView.refreshControl = refresh
        } else if !allowed, scrollView.refreshControl != nil {
            refresh.endRefreshing()
            scrollView.refreshControl = nil
        }
    }

    @objc private func pullToRefresh() {
        webView?.reload()
    }

    /// The status bar sits over the web UI's top bar, so its style follows
    /// the web theme (the person can pick a theme in Suite that differs from
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
