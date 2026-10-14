import Foundation
import UserNotifications

#if DEBUG
    /// DEBUG ONLY (task 01a1261e stage 4 evidence): `burrow://debug/push-key?host=<host>&name=<name>`
    /// saves the install (keeping the current selection), creates its
    /// sealed-preview keypair if missing, and writes the PUBLIC key to
    /// `debug-push-key-<host>.txt` in the App Group container. A sealed test
    /// push can then be built off-device and delivered with `simctl push`,
    /// exercising the real Notification Service Extension. The private key
    /// never leaves the Keychain; nothing is logged. Not compiled in Release.
    enum DebugPushKeySeam {
        /// `simctl launch ... -SuiteDebugPushKeyHost <host> -SuiteDebugPushKeyName <name>`:
        /// the same as the link, without the system's "Open in Burrow?" prompt.
        static func applyLaunchArgument(defaults: UserDefaults = .standard) {
            // `-SuiteDebugPushKeyRemove <host>`: undo, on a shared simulator.
            if let host = defaults.string(forKey: "SuiteDebugPushKeyRemove") {
                InstallStore.shared.remove(host: host)
                PushKeyStore.shared.remove(for: host)
                if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: InstallStore.appGroup) {
                    try? FileManager.default.removeItem(at: container.appendingPathComponent("debug-push-key-\(host).txt"))
                }
            }
            guard let host = defaults.string(forKey: "SuiteDebugPushKeyHost") else { return }
            var components = URLComponents()
            components.scheme = DeepLink.scheme
            components.host = "debug"
            components.path = "/push-key"
            components.queryItems = [
                URLQueryItem(name: "host", value: host),
                URLQueryItem(name: "name", value: defaults.string(forKey: "SuiteDebugPushKeyName")),
            ]
            if let url = components.url { handle(url: url) }
        }

        /// `-SuiteDebugLocalPush <file>`: read an APNs payload from `<file>` in
        /// the App Group container, run it through the Notification Service
        /// Extension's own pipeline (`PushContentPreparer`, then
        /// `AvatarNotificationDelivery` with the live `AvatarFetcher`, task
        /// 01a12773) and schedule the result as a local notification 3 s out.
        /// For evidence frames on a simulator whose `simctl push` does not
        /// launch the extension.
        static func applyLocalPushArgument(defaults: UserDefaults = .standard) {
            guard let name = defaults.string(forKey: "SuiteDebugLocalPush"),
                let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: InstallStore.appGroup),
                let data = try? Data(contentsOf: container.appendingPathComponent(name)),
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let aps = payload["aps"] as? [String: Any]
            else { return }
            let content = UNMutableNotificationContent()
            let alert = aps["alert"] as? [String: Any]
            content.title = alert?["title"] as? String ?? ""
            content.body = alert?["body"] as? String ?? ""
            content.sound = .default
            content.userInfo = payload.filter { $0.key != "aps" }
            let avatars = AvatarFetcher.live()
            let delivery = AvatarNotificationDelivery(
                fetch: { url, host in await avatars.fetch(url, installHost: host) },
                deliver: { delivered in
                    let request = UNNotificationRequest(
                        identifier: "debug-\(name)", content: delivered,
                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false))
                    UNUserNotificationCenter.current().add(request)
                })
            delivery.start(PushContentPreparer.live().prepare(content))
        }

        @discardableResult
        static func handle(url: URL) -> Bool {
            guard url.scheme?.lowercased() == DeepLink.scheme, url.host?.lowercased() == "debug", url.path == "/push-key",
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                let host = items.first(where: { $0.name == "host" })?.value.flatMap(InstallStore.normalizeHost)
            else { return false }
            let store = InstallStore.shared
            let previous = store.selectedHost
            store.add(host: host, name: items.first(where: { $0.name == "name" })?.value)
            if let previous { store.select(previous) }
            guard let key = PushKeyStore.shared.publicKey(for: host),
                let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: InstallStore.appGroup)
            else { return true }
            try? Data(key.utf8).write(to: container.appendingPathComponent("debug-push-key-\(host).txt"))
            return true
        }
    }
#endif
