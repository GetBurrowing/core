import Capacitor
import Foundation
import UIKit
import UserNotifications
import WebKit

// `SuiteNative` is the app's ONE Capacitor plugin: every native capability the
// web UI reaches goes through it. A later meetings plugin (v2) registers
// beside it in BurrowBridgeViewController.capacitorDidLoad rather than
// growing this one.

// MARK: - Notification categories

enum BurrowNotificationCategory {
    static let mention = "SUITE_MENTION"
    static let open = "SUITE_OPEN"
    static let replyAction = "SUITE_REPLY"
    static let openAction = "SUITE_OPEN_ACTION"
    /// `meeting_ring_waiting`: a ring that arrived during a call. Shown as
    /// the in-call invite banner, never as a system banner.
    static let ringWaiting = "SUITE_RING_WAITING"

    // The Burrow names for the same three categories and two actions (task
    // 01a14ba1). Registered BESIDE the SUITE_* ids, never instead of them:
    // a device that has not reported `push_category_scheme` keeps getting
    // SUITE_* from the server, and an already-delivered notification answers
    // with the action id it was shown with.
    static let burrowMention = "BURROW_MENTION"
    static let burrowOpen = "BURROW_OPEN"
    static let burrowRingWaiting = "BURROW_RING_WAITING"
    static let burrowReplyAction = "BURROW_REPLY"
    static let burrowOpenAction = "BURROW_OPEN_ACTION"

    /// The scheme this build reports in `POST /api/app/devices` as
    /// `push_category_scheme`: it registers the BURROW_* categories too.
    static let scheme = "burrow"

    /// Categories the server's APNs payload names in `aps.category`
    /// (Platform.Push.Notification: chat_mention -> SUITE_MENTION or
    /// BURROW_MENTION, approvals -> SUITE_OPEN or BURROW_OPEN,
    /// meeting_ring_waiting -> SUITE_RING_WAITING or BURROW_RING_WAITING).
    /// Both sets are registered.
    static func all() -> Set<UNNotificationCategory> {
        categories(
            mention: mention, open: Self.open, ringWaiting: ringWaiting,
            replyAction: replyAction, openAction: openAction
        )
        .union(
            categories(
                mention: burrowMention, open: burrowOpen, ringWaiting: burrowRingWaiting,
                replyAction: burrowReplyAction, openAction: burrowOpenAction))
    }

    private static func categories(
        mention: String, open openID: String, ringWaiting: String,
        replyAction: String, openAction: String
    ) -> Set<UNNotificationCategory> {
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
            UNNotificationCategory(
                identifier: openID, actions: [open], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: nil,
                categorySummaryFormat: "%u approvals", options: []),
            UNNotificationCategory(identifier: ringWaiting, actions: [], intentIdentifiers: [], options: []),
        ]
    }

    /// A busy callee's ring, under either name.
    static func isRingWaiting(_ category: String) -> Bool {
        category == ringWaiting || category == burrowRingWaiting
    }

    /// The Reply action, under either name.
    static func isReply(_ action: String) -> Bool {
        action == replyAction || action == burrowReplyAction
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
    let authorID: String?
    let authorType: String?

    init(userInfo: [AnyHashable: Any]) {
        installHost = userInfo["install_host"] as? String
        url = userInfo["url"] as? String
        spaceID = userInfo["space_id"] as? String
        messageID = userInfo["message_id"] as? String
        authorID = userInfo["author_id"] as? String
        authorType = userInfo["author_type"] as? String
    }

    /// A reply from the notification: the space, and the author it answers
    /// as the recipient. Ids only; the reply text is never part of it.
    func replyDonation() -> DonationEvent? {
        guard let host = installHost, let spaceID, UUID(uuidString: spaceID) != nil else { return nil }
        var recipients: [DonationRecipient] = []
        if let authorID, UUID(uuidString: authorID) != nil, let type = authorType, type == "user" || type == "agent" {
            recipients = [DonationRecipient(type: type, id: authorID.lowercased())]
        }
        return .messageSent(host: host, spaceID: spaceID.lowercased(), recipients: recipients)
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
        for waiter in pending { waiter(result) }
    }

    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - App API client

/// Calls to the install's `/api/app/*` routes with that install's bearer.
enum BurrowAPI {
    static var pushEnvironment: String {
        (Bundle.main.object(forInfoDictionaryKey: "BurrowPushEnvironment") as? String) ?? "production"
    }

    /// Through the shared client: the bearer for `host`, from the shared
    /// Keychain, attached in one place.
    static func post(host: String, path: String, json: [String: Any], completion: @escaping (Result<Data, Error>) -> Void) {
        BurrowAPIClient.shared.postJSON(host: host, path: path, json: json, completion: completion)
    }

    static func registerDevice(host: String, token: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        let body = registrationBody(
            token: token, appInstallID: InstallStore.shared.appInstallID,
            publicKey: PushKeyStore.shared.publicKey(for: host))
        post(host: host, path: "/api/app/devices", json: body) { result in
            completion(result.map { _ in () })
        }
    }

    /// The `POST /api/app/devices` body.
    static func registrationBody(token: Data, appInstallID: String, publicKey: String?) -> [String: Any] {
        var body: [String: Any] = [
            "token": PushRegistrar.hex(token),
            "environment": pushEnvironment,
            "bundle_id": Bundle.main.bundleIdentifier ?? "com.kobo-ai.burrow",
            "app_install_id": appInstallID,
            // Task 01a14ba1: this build registers the BURROW_* categories, so
            // the server may send them. A build that sends no scheme keeps
            // getting SUITE_*.
            "push_category_scheme": BurrowNotificationCategory.scheme,
        ]
        // Task 01a1261e: this install's sealed-preview public key. No key
        // (Keychain refused) registers exactly as before: no preview.
        if let publicKey { body["push_public_key"] = publicKey }
        return body
    }

    static func reply(host: String, spaceID: String, replyTo messageID: String?, text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var body: [String: Any] = ["text": text]
        if let messageID { body["reply_to"] = messageID }
        let path = BurrowAPIClient.messagesPath(spaceID)
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

    /// Set by BurrowBridgeViewController; until the shell is up, an Open is
    /// parked here and replayed.
    var openHandler: ((Install, URL) -> Void)?
    private(set) var pendingOpen: (Install, URL)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        completionHandler(Self.presentation(forCategory: content.categoryIdentifier))
        // The NSE already wrote this push's unread count: refresh the dot.
        NotificationCenter.default.post(name: .burrowInstallBadgesChanged, object: nil)
        if BurrowNotificationCategory.isRingWaiting(content.categoryIdentifier) {
            showRingWaiting(content.userInfo)
        }
    }

    /// Foreground presentation by category. A busy callee's ring
    /// (`SUITE_RING_WAITING` or `BURROW_RING_WAITING`) gets NO system banner and no sound:
    /// it becomes the in-call invite banner and the call is never interrupted.
    static func presentation(forCategory category: String) -> UNNotificationPresentationOptions {
        BurrowNotificationCategory.isRingWaiting(category) ? [] : [.banner, .list, .sound]
    }

    /// Hands a ring-waiting payload to the in-call banner.
    func showRingWaiting(_ userInfo: [AnyHashable: Any]) {
        guard let invite = RingInvite(userInfo: userInfo) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { RingWaiting.shared.show(invite) }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let payload = PushPayload(userInfo: response.notification.request.content.userInfo)

        switch response.actionIdentifier {
        case let id where BurrowNotificationCategory.isReply(id):
            guard
                let text = (response as? UNTextInputNotificationResponse)?.userText
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                let host = payload.installHost, let spaceID = payload.spaceID
            else {
                return completionHandler()
            }
            let task = UIApplication.shared.beginBackgroundTask(withName: "burrow.reply")
            BurrowAPI.reply(host: host, spaceID: spaceID, replyTo: payload.messageID, text: text) { result in
                if case .success = result, let event = payload.replyDonation() { Donations.shared.donate(event) }
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
            if BurrowNotificationCategory.isRingWaiting(response.notification.request.content.categoryIdentifier) {
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

@objc(BurrowNativePlugin)
public class BurrowNativePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "BurrowNativePlugin"
    // The JS-facing wire name stays `SuiteNative`: core JS older than task
    // 01a14ba9 looks up only that name (docs/runbooks/burrow-rename-deferred.md).
    public let jsName = "SuiteNative"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "pushState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "enablePush", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "switchInstall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "donate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "installBadges", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "tabBarState", returnType: CAPPluginReturnPromise),
    ]

    /// The shell's navigation policy, consulted for every web view
    /// navigation before Capacitor's own rule. Owned by the bridge view
    /// controller; nil while no install is loaded.
    weak var shell: BurrowBridgeViewController?

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
            BurrowNotificationCategory.register(center: center)
            PushRegistrar.shared.requestToken { tokenResult in
                switch tokenResult {
                case .failure:
                    call.reject("APNs registration failed", "apns_failed")
                case .success(let token):
                    BurrowAPI.registerDevice(host: host, token: token) { result in
                        switch result {
                        case .success:
                            call.resolve(["registered": true, "state": "granted"])
                        case .failure(BurrowAPIClient.Failure.notSignedIn):
                            call.reject("Not signed in to this install", "not_signed_in")
                        case .failure(BurrowAPIClient.Failure.status(let status)):
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

    /// A `PlatformWeb.NativeDonation` payload from the web view (ids only):
    /// donated as a recipients-only value for the install the web view is
    /// showing. Unknown kinds and malformed ids are ignored.
    @objc func donate(_ call: CAPPluginCall) {
        let payload = Dictionary(uniqueKeysWithValues: call.options.compactMap { key, value in (key as? String).map { ($0, value) } })
        guard let host = InstallStore.shared.selectedHost, let event = DonationEvent.fromBridge(payload, host: host) else {
            return call.resolve(["donated": false])
        }
        Donations.shared.donate(event)
        call.resolve(["donated": true])
    }

    /// `{others_unread: Bool}`: whether any signed-in install OTHER than the
    /// one showing has unread (task 01a1261e; the web shell's switcher dot,
    /// contract owned by stage 3). Re-asked on `burrowInstallBadges`.
    @objc func installBadges(_ call: CAPPluginCall) {
        call.resolve(["others_unread": Self.othersUnread()])
    }

    /// `{items, selected, inbox_dot, visible}` for the native tab bar (task
    /// 01a1557b). Missing or malformed fields leave the bar's state unchanged;
    /// see `NativeTabBarState.applying`.
    @objc func tabBarState(_ call: CAPPluginCall) {
        let payload = Dictionary(uniqueKeysWithValues: call.options.compactMap { key, value in (key as? String).map { ($0, value) } })
        DispatchQueue.main.async {
            self.shell?.applyTabBarState(payload)
            call.resolve()
        }
    }

    static func othersUnread(store: InstallUnreadStore = .shared, selectedHost: String? = InstallStore.shared.selectedHost) -> Bool {
        store.othersUnread(selectedHost: selectedHost)
    }

    static func state(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral: return "granted"
        case .denied: return "denied"
        default: return "prompt"
        }
    }
}
