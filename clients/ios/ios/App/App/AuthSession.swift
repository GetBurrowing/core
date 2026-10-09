import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// RFC 7636 PKCE, S256 only (the server refuses anything else).
enum PKCE {
    /// 32 random bytes as base64url: a 43-character verifier.
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return base64URL(Data(bytes))
    }

    /// base64url(SHA-256(ASCII(verifier))) without padding.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Native sign-in for one install.
///
/// 1. ASWebAuthenticationSession opens `https://<host>/auth/login?app_challenge=<S256>`
///    in the system browser sheet, where passkeys work (see README, Login);
/// 2. the server's OIDC callback lands on `burrow://auth/callback?code=...`;
/// 3. `POST /api/app/session` swaps the code plus verifier for a bearer and a
///    `handoff_url`;
/// 4. the bearer goes to the Keychain (account = host) and the web view loads
///    `handoff_url` as returned, which signs the web view in.
///
/// Neither the code, the verifier nor the bearer is ever logged.
final class AuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let callbackScheme = "burrow"

    enum Failure: Error {
        case cancelled
        case noCode
        case exchangeFailed(Int)
        case badResponse
    }

    private let install: Install
    private let anchor: () -> ASPresentationAnchor
    private var session: ASWebAuthenticationSession?

    init(install: Install, anchor: @escaping () -> ASPresentationAnchor) {
        self.install = install
        self.anchor = anchor
    }

    static func loginURL(host: String, challenge: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/auth/login"
        components.queryItems = [URLQueryItem(name: "app_challenge", value: challenge)]
        return components.url!
    }

    /// Runs the whole flow and returns the handoff URL to load.
    func start(completion: @escaping (Result<URL, Error>) -> Void) {
        let verifier = PKCE.makeVerifier()
        let url = Self.loginURL(host: install.host, challenge: PKCE.challenge(for: verifier))
        let host = install.host

        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { [weak self] callback, error in
            self?.session = nil
            if let error {
                let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                DispatchQueue.main.async { completion(.failure(cancelled ? Failure.cancelled : error)) }
                return
            }
            guard let callback,
                  let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value else {
                DispatchQueue.main.async { completion(.failure(Failure.noCode)) }
                return
            }
            Self.exchange(host: host, code: code, verifier: verifier) { result in
                DispatchQueue.main.async { completion(result) }
            }
        }
        session.presentationContextProvider = self
        // Share the Safari cookie jar: a person already signed in to pocket-id
        // in Safari is not asked again.
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        session.start()
    }

    static func exchange(host: String, code: String, verifier: String, completion: @escaping (Result<URL, Error>) -> Void) {
        var request = URLRequest(url: URL(string: "https://\(host)/api/app/session")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: String] = [
            "code": code,
            "code_verifier": verifier,
            "app_install_id": InstallStore.shared.appInstallID,
            "device_name": UIDevice.current.name
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { return completion(.failure(error)) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return completion(.failure(Failure.exchangeFailed(status))) }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["token"] as? String,
                  let handoff = (json["handoff_url"] as? String).flatMap(URL.init(string:)) else {
                return completion(.failure(Failure.badResponse))
            }
            guard KeychainTokenStore.shared.store(token, for: host) else {
                return completion(.failure(Failure.badResponse))
            }
            WidgetCountsRefresher.refresh(host: host)
            IntentAppHooks.didSignIn(host: host)
            completion(.success(handoff))
        }.resume()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor()
    }
}
