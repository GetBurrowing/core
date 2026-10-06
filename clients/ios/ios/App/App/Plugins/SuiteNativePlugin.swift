import Capacitor
import Foundation
import UIKit
import UserNotifications
import WebKit

// SuiteNative is the app's ONE Capacitor plugin: every native capability the
// web UI reaches goes through it. A later meetings plugin (v2) registers
// beside it in SuiteBridgeViewController.capacitorDidLoad rather than
// growing this one.

// MARK: - Notification categories

enum SuiteNotificationCategory {
    static let mention = "SUITE_MENTION"
    static let open = "SUITE_OPEN"
    static let replyAction = "SUITE_REPLY"
    static let openAction = "SUITE_OPEN_ACTION"
    /// `meeting_ring_waiting`: a ring that arrived during a call. Shown as
    /// the in-call invite banner, never as a system banner.
    static let ringWaiting = "SUITE_RING_WAITING"

    /// Categories the server's APNs payload names in `aps.category`
    /// (Platform.Push.Notification: chat_mention -> SUITE_MENTION,
    /// approvals -> SUITE_OPEN).
    static func all() -> Set<UNNotificationCategory> {
        // Reply runs in the background: no `.foreground`, so answering from
        // the lock screen does not open the app. It does need the device
        // unlocked, because it posts as the signed-in person.
        let reply = UNTextInputNotificationAction(
            identifier: replyAction,
            title: "Reply",
            options: [.authenticationRequired],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Reply"
        )
        let open = UNNotificationAction(identifier: openAction, title: "Open", options: [.foreground])
        return [
            UNNotificationCategory(identifier: mention, actions: [reply, open], intentIdentifiers: [], options: []),
            // A stack of approvals reads "3 approvals", not "3 more notifications".
            UNNotificationCategory(identifier: Self.open, actions: [open], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: nil,
                                   categorySummaryFormat: "%u approvals", options: []),
            UNNotificationCategory(identifier: ringWaiting, actions: [], intentIdentifiers: [], options: [])
        ]
    }

    static func register(center: UNUserNotificationCenter = .current()) {
        center.setNotificationCategories(all())
    }
}

// MARK: - Push payload

/// The routing keys `Platform.Push.Notification.to_apns_payload/1` puts beside `aps`.
struct PushPayload {
    let installHost: String?
    let url: String?
    let spaceID: String?
    let messageID: String?

    init(userInfo: [AnyHashable: Any]) {
        installHost = userInfo["install_host"] as? String
        url = userInfo["url"] as? String
        spaceID = userInfo["space_id"] as? String
        messageID = userInfo["message_id"] as? String
    }

    /// The page to open: an absolute URL on the install host, or a path
    /// resolved against it. A URL on any OTHER host is ignored and the
    /// install root opens instead, so a payload cannot steer the shell off
    /// its install.
    func destination() -> URL? {
        guard let host = installHost else { return nil }
        let base = URL(string: "https://\(host)/")!
        guard let raw = url, let resolved = URL(string: raw, relativeTo: base)?.absoluteURL else { return base }
        return resolved.host?.lowercased() == host.lowercased() ? resolved : base
    }
}

// MARK: - APNs token

/// Bridges UIApplication's token callbacks (AppDelegate) to whoever asked.
final class PushRegistrar {
    static let shared = PushRegistrar()

    private var waiters: [(Result<Data, Error>) -> Void] = []
    private let lock = NSLock()

    struct Timeout: Error {}

    func requestToken(timeout: TimeInterval = 20, completion: @escaping (Result<Data, Error>) -> Void) {
        lock.lock()
        waiters.append(completion)
        lock.unlock()
        DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(Timeout()))
        }
    }

    func didRegister(_ token: Data) { finish(.success(token)) }
    func didFail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0(result) }
    }

    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - App API client

/// Calls to the install's `/api/app/*` routes with that install's bearer.
enum SuiteAPI {
    static var pushEnvironment: String {
        (Bundle.main.object(forInfoDictionaryKey: "SuitePushEnvironment") as? String) ?? "production"
    }

    /// Through the shared client: the bearer for `host`, from the shared
    /// Keychain, attached in one place.
    static func post(host: String, path: String, json: [String: Any], completion: @escaping (Result<Data, Error>) -> Void) {
        SuiteAPIClient.shared.postJSON(host: host, path: path, json: json, completion: completion)
    }

    static func registerDevice(host: String, token: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        let body: [String: Any] = [
            "token": PushRegistrar.hex(token),
            "environment": pushEnvironment,
            "bundle_id": Bundle.main.bundleIdentifier ?? "com.kobo-ai.burrow",
            "app_install_id": InstallStore.shared.appInstallID
        ]
        post(host: host, path: "/api/app/devices", json: body) { result in
            completion(result.map { _ in () })
        }
    }

    static func reply(host: String, spaceID: String, replyTo messageID: String?, text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var body: [String: Any] = ["text": text]
        if let messageID { body["reply_to"] = messageID }
        let path = SuiteAPIClient.messagesPath(spaceID)
        post(host: host, path: path, json: body) { result in
            completion(result.map { _ in () })
        }
    }
}

// MARK: - Notification responses

/// UNUserNotificationCenter delegate: banners in the foreground, Reply in
/// the background, Open and tap switch to the payload's install.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// Set by SuiteBridgeViewController; until the shell is up, an Open is
    /// parked here and replayed.
    var openHandler: ((Install, URL) -> Void)?
    private(set) var pendingOpen: (Install, URL)?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let content = notification.request.content
        completionHandler(Self.presentation(forCategory: content.categoryIdentifier))
        if content.categoryIdentifier == SuiteNotificationCategory.ringWaiting {
            showRingWaiting(content.userInfo)
        }
    }

    /// Foreground presentation by category. A busy callee's ring
    /// (`SUITE_RING_WAITING`, stage 5) gets NO system banner and no sound:
    /// it becomes the in-call invite banner and the call is never interrupted.
    static func presentation(forCategory category: String) -> UNNotificationPresentationOptions {
        category == SuiteNotificationCategory.ringWaiting ? [] : [.banner, .list, .sound]
    }

    /// Hands a `SUITE_RING_WAITING` payload to the in-call banner.
    func showRingWaiting(_ userInfo: [AnyHashable: Any]) {
        guard let invite = RingInvite(userInfo: userInfo) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { RingWaiting.shared.show(invite) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let payload = PushPayload(userInfo: response.notification.request.content.userInfo)

        switch response.actionIdentifier {
        case SuiteNotificationCategory.replyAction:
            guard let text = (response as? UNTextInputNotificationResponse)?.userText
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let host = payload.installHost, let spaceID = payload.spaceID else {
                return completionHandler()
            }
            let task = UIApplication.shared.beginBackgroundTask(withName: "suite.reply")
            SuiteAPI.reply(host: host, spaceID: spaceID, replyTo: payload.messageID, text: text) { _ in
                DispatchQueue.main.async {
                    completionHandler()
                    UIApplication.shared.endBackgroundTask(task)
                }
            }

        case UNNotificationDismissActionIdentifier:
            completionHandler()

        default:
            // A tap on a ring-waiting notification shown while the app was
            // in the background: the banner, not a page.
            if response.notification.request.content.categoryIdentifier == SuiteNotificationCategory.ringWaiting {
                showRingWaiting(response.notification.request.content.userInfo)
                return completionHandler()
            }
            // Open, or a tap on the notification itself.
            DispatchQueue.main.async {
                self.open(payload)
                completionHandler()
            }
        }
    }

    func open(_ payload: PushPayload) {
        guard let host = payload.installHost, let url = payload.destination() else { return }
        let store = InstallStore.shared
        guard let install = store.add(host: host) else { return }
        store.confirmSelection()
        if let openHandler {
            openHandler(install, url)
        } else {
            pendingOpen = (install, url)
        }
    }

    func takePendingOpen() -> (Install, URL)? {
        defer { pendingOpen = nil }
        return pendingOpen
    }
}

// MARK: - The plugin

@objc(SuiteNativePlugin)
public class SuiteNativePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "SuiteNativePlugin"
    public let jsName = "SuiteNative"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "pushState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "enablePush", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "switchInstall", returnType: CAPPluginReturnPromise)
    ]

    /// The shell's navigation policy, consulted for every web view
    /// navigation before Capacitor's own rule. Owned by the bridge view
    /// controller; nil while no install is loaded.
    weak var shell: SuiteBridgeViewController?

    override public func shouldOverrideLoad(_ navigationAction: WKNavigationAction) -> NSNumber? {
        guard let shell else { return nil }
        return shell.handle(navigationAction) ? true : false
    }

    /// `{state: "granted" | "denied" | "prompt"}` from iOS notification settings.
    @objc func pushState(_ call: CAPPluginCall) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            call.resolve(["state": Self.state(settings.authorizationStatus)])
        }
    }

    /// Asks for permission if needed, registers with APNs and POSTs the token
    /// to `/api/app/devices` for the current install. Resolves
    /// `{registered: true}` ONLY when that POST succeeded; a denial resolves
    /// `{registered: false, state: "denied"}`; any failure after a grant
    /// rejects, so the web never reports a registration that was not stored.
    @objc func enablePush(_ call: CAPPluginCall) {
        guard let host = InstallStore.shared.selectedHost else {
            return call.reject("No install selected", "no_install")
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else {
                return call.resolve(["registered": false, "state": "denied"])
            }
            SuiteNotificationCategory.register(center: center)
            PushRegistrar.shared.requestToken { tokenResult in
                switch tokenResult {
                case .failure:
                    call.reject("APNs registration failed", "apns_failed")
                case .success(let token):
                    SuiteAPI.registerDevice(host: host, token: token) { result in
                        switch result {
                        case .success:
                            call.resolve(["registered": true, "state": "granted"])
                        case .failure(SuiteAPIClient.Failure.notSignedIn):
                            call.reject("Not signed in to this install", "not_signed_in")
                        case .failure(SuiteAPIClient.Failure.status(let status)):
                            call.reject("Device registration returned \(status)", "registration_failed")
                        case .failure:
                            call.reject("Device registration failed", "registration_failed")
                        }
                    }
                }
            }
        }
    }

    /// Opens the install picker (the web UI does not need to; the Home
    /// Screen quick action does the same).
    @objc func switchInstall(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.shell?.presentPicker()
            call.resolve()
        }
    }

    static func state(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral: return "granted"
        case .denied: return "denied"
        default: return "prompt"
        }
    }
}
