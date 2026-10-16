import Capacitor
import UIKit
import UserNotifications

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Set before launch finishes so a notification that launched the app
        // is delivered to the router.
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationRouter.shared
        SuiteNotificationCategory.register(center: center)
        IntentAppHooks.install()
        IntentTrace.append("launch sha=\(IntentTrace.buildSHA) state=\(application.applicationState.rawValue)")
        // Rings (stage 5): the CallKit provider exists, then PushKit starts,
        // both before launch returns, so a VoIP push that launched the app
        // is reported to CallKit.
        _ = CallController.shared
        VoIPRegistrar.shared.start()
        #if DEBUG
            EvidenceHooks.apply()
        #endif
        // Large share-sheet uploads (task 01a120be): for a chunked upload
        // whose share extension is gone, rebuild which chunks still have
        // live tasks, HEAD for the server's contiguous offset and queue
        // only the missing chunks. Every chunk was queued up front, so this
        // creates no task unless one was lost.
        BackgroundUploader.shared.resumePending()
        return true
    }

    /// The system relaunches the app for a background upload session the
    /// share extension started; the uploader recreates the session by its
    /// identifier and handles the chunk results: an acknowledged slice is
    /// deleted, a failed chunk alone is re-sent, a 404/410 posts the
    /// "upload expired" notification, the finishing 200 posts "Sent to".
    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundUploader.shared.reconnect(sessionID: identifier, completionHandler: completionHandler)
    }

    // The APNs device token is handed to the registrar and never logged.
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistrar.shared.didRegister(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushRegistrar.shared.didFail(error)
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

#if DEBUG
    /// DEBUG-only launch arguments the screenshot UI test (EvidenceUITests)
    /// uses to put the app in a state. Compiled out of Release.
    enum EvidenceHooks {
        static func apply() {
            let args = UserDefaults.standard
            if args.bool(forKey: "SuiteEvidenceReset") {
                UserDefaults(suiteName: InstallStore.appGroup)?.removePersistentDomain(forName: InstallStore.appGroup)
            }
            if let host = args.string(forKey: "SuiteExtraInstall") {
                let store = InstallStore.shared
                let selected = store.selectedHost
                store.add(host: host)
                if let selected { store.select(selected) }
            }
            // Ring review (stage 5): an install "signed in" with a
            // placeholder bearer, so an injected ring for that host keeps
            // ringing. Use an unresolvable host (`*.invalid`) so the
            // placeholder never reaches a server.
            if let host = args.string(forKey: "SuiteEvidenceSignInHost"), host.hasSuffix(".invalid") {
                let store = InstallStore.shared
                store.add(host: host)
                _ = KeychainTokenStore.shared.store("evidence-placeholder", for: host)
            }
            // Siri review (01a111bb stage 7, round 3): one person in the
            // people cache, `<host>|<uuid>|<name>|<kind>` on a signed-in
            // `*.invalid` host, so a system test can hand the system an
            // entity ID and watch it resolve through MessagePersonEntityQuery.
            if #available(iOS 27, *), let spec = args.string(forKey: "SuiteEvidencePerson") {
                let parts = spec.split(separator: "|").map(String.init)
                if parts.count == 4, parts[0].hasSuffix(".invalid") {
                    InstallStore.shared.add(host: parts[0])
                    _ = KeychainTokenStore.shared.store("evidence-placeholder", for: parts[0])
                    PeopleCache.shared.remember([MessagePersonEntity(id: "\(parts[0])|\(parts[1])", name: parts[2], kind: parts[3], subtitle: "Person")])
                }
            }
            // Task 01a120be stage 4 evidence: the large-upload completion
            // notification, posted by the uploader's own code path once
            // notifications are allowed (EvidenceUITests presses Home first).
            if let space = args.string(forKey: "SuiteEvidenceSentNotification") {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    // A time trigger, so the system delivers it while the
                    // app is suspended in the background.
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 8, repeats: false)
                    UNUserNotificationCenter.current().add(BackgroundUploader.sentNotificationRequest(space, trigger: trigger))
                }
            }
            if args.bool(forKey: "SuiteRequestPush") {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
        }
    }
#endif
