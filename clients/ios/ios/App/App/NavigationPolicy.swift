import Foundation

/// What the shell does with one web view navigation.
enum NavigationDecision: Equatable {
    /// Stay in the web view.
    case allow
    /// Cancel the new window and load its request in the existing web view.
    case loadInMainView
    /// Cancel and hand the URL to iOS (Safari, Mail, Phone...).
    case openExternally
    /// Cancel and sign in natively with ASWebAuthenticationSession.
    case startNativeLogin
    /// Cancel, sign out natively (device, session, Keychain), then let the
    /// web logout run in the view (NativeSignOut).
    case signOut
}

/// The shell's navigation rule: the selected install's host stays in the
/// view; every other host opens in Safari. Pure so it can be unit tested.
///
/// - Sub-frame loads are allowed whatever their host: an embed (a video, a
///   canvas iframe) is part of the install's page, not a navigation away.
/// - The install's own `/auth/login` in the main frame is the web app asking
///   for a sign-in. pocket-id's passkey ceremony does not complete inside a
///   third-party WKWebView (README, Login), so the shell runs the native
///   flow instead. A URL already carrying `app_challenge` is that native
///   flow's own URL and is left alone.
/// - The install's own `/auth/logout` in the main frame is the web "Log
///   out" link. The app's bearer and APNs device outlive the web cookie, so
///   the shell signs out natively first.
struct NavigationPolicy {
    let installHost: String

    static let inViewSchemes: Set<String> = ["about", "data", "blob", "capacitor"]

    func decide(url: URL?, isMainFrame: Bool, isNewWindow: Bool = false) -> NavigationDecision {
        let isMainFrame = isMainFrame || isNewWindow
        guard let url, let scheme = url.scheme?.lowercased() else { return .allow }
        if Self.inViewSchemes.contains(scheme) { return .allow }
        guard scheme == "https" || scheme == "http" else { return .openExternally }

        let host = url.host?.lowercased() ?? ""
        guard host == installHost.lowercased() else {
            return isMainFrame ? .openExternally : .allow
        }

        if isMainFrame, url.path == "/auth/logout" {
            return .signOut
        }
        if isMainFrame, url.path == "/auth/login",
           !(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).contains(where: { $0.name == "app_challenge" }) {
            return .startNativeLogin
        }
        return isNewWindow ? .loadInMainView : .allow
    }

    /// Pull-to-refresh is off in chat views, where pulling down already
    /// means loading older messages (canvas Layout intent).
    static func allowsPullToRefresh(path: String) -> Bool {
        !(path == "/chat" || path.hasPrefix("/chat/"))
    }
}
