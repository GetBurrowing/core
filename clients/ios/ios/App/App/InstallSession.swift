import Foundation

/// What the shell does next to put a signed-in install in the web view.
enum LaunchStep: Equatable {
    /// Load this URL (a one-time handoff URL, or the page itself).
    case load(URL)
    /// No usable bearer: run the native ASWebAuthenticationSession sign-in.
    case signIn
}

/// Opens an install on its stored bearer instead of a new sign-in.
///
/// WKWebView keeps the install's session cookie only for the life of the
/// app process, so on a cold launch or an install switch the web view is
/// signed out even though the Keychain still holds a bearer. With a bearer,
/// `POST /api/app/handoff` returns a one-time URL that signs the web view
/// back in and lands on the page asked for. A 401 means the bearer was
/// revoked: it is removed and the native sign-in runs. Any other failure
/// (offline, a 5xx) loads the page itself; the web view may still hold a
/// cookie, and if not its `/auth/login` comes back to the native flow.
struct InstallLauncher {
    let client: SuiteAPIClient
    let tokens: MutableTokenStore

    init(client: SuiteAPIClient = .shared, tokens: MutableTokenStore = KeychainTokenStore.shared) {
        self.client = client
        self.tokens = tokens
    }

    func start(install: Install, destination: URL?, completion: @escaping (LaunchStep) -> Void) {
        guard client.isSignedIn(host: install.host) else { return completion(.signIn) }
        client.handoff(host: install.host, path: Self.localPath(of: destination, on: install.host)) { result in
            switch result {
            case .success(let url):
                completion(.load(url))
            case .failure(SuiteAPIClient.Failure.status(401)):
                tokens.remove(for: install.host)
                completion(.signIn)
            case .failure:
                completion(.load(destination ?? install.baseURL))
            }
        }
    }

    /// The path (and query) of `url` when it is on `host`; nil for the root
    /// or anything else, so the handoff lands on `/`.
    static func localPath(of url: URL?, on host: String) -> String? {
        guard let url, url.host?.lowercased() == host.lowercased(),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let local = components.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
        return local == "/" ? nil : local
    }
}

/// Native sign-out for one install, run when the web UI navigates to
/// `/auth/logout`:
///
/// 1. `DELETE /api/app/devices/:app_install_id`, so pushes stop;
/// 2. `DELETE /api/app/session`, so the bearer is revoked server-side;
/// 3. the bearer leaves the Keychain.
///
/// The Keychain entry is removed whatever the server answered: a person who
/// signed out offline is signed out on this phone. The shell then lets the
/// web `/auth/logout` run in the web view.
struct NativeSignOut {
    let client: SuiteAPIClient
    let tokens: MutableTokenStore
    let appInstallID: String
    /// Deletes the install's sealed-preview key with its bearer (task 01a1261e).
    let forgetPushKey: (String) -> Void

    init(
        client: SuiteAPIClient = .shared,
        tokens: MutableTokenStore = KeychainTokenStore.shared,
        appInstallID: String = InstallStore.shared.appInstallID,
        forgetPushKey: @escaping (String) -> Void = { PushKeyStore.shared.remove(for: $0) }
    ) {
        self.client = client
        self.tokens = tokens
        self.appInstallID = appInstallID
        self.forgetPushKey = forgetPushKey
    }

    func run(host: String, completion: @escaping () -> Void) {
        client.delete(host: host, path: SuiteAPIClient.devicePath(appInstallID)) { _ in
            client.delete(host: host, path: "/api/app/session") { _ in
                tokens.remove(for: host)
                forgetPushKey(host)
                completion()
            }
        }
    }
}
