import Capacitor
import Intents
import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    static let switchInstallShortcut = "com.kobo-ai.burrow.switch-install"

    var window: UIWindow?
    private var bridge: SuiteBridgeViewController? { window?.rootViewController as? SuiteBridgeViewController }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        let shell = SuiteBridgeViewController()
        // Cold launch from the quick action: open on the picker.
        shell.startOnPicker = connectionOptions.shortcutItem?.type == Self.switchInstallShortcut
        window.rootViewController = shell
        window.makeKeyAndVisible()
        self.window = window

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)
        #if DEBUG
            DebugPushKeySeam.applyLaunchArgument()
            DebugPushKeySeam.applyLocalPushArgument()
        #endif

        // Cold launch from a widget: park the link for when the shell starts.
        if let link = connectionOptions.urlContexts.lazy.compactMap({ DeepLink(url: $0.url) }).first {
            shell.pendingDeepLink = link
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // ONE counts request per signed-in install: every install's unread
        // count, the summed icon badge, the web switcher dot and the widgets'
        // counts for the selected install (task 01a1261e).
        OpenRefresh.run()
        VoIPRegistrar.shared.registerWithSignedInInstalls()
        IntentAppHooks.didBecomeActive()
    }

    /// The only place App Shortcut phrases are refreshed: as the person
    /// leaves the app, never from an intent or an entity query, and never
    /// while they are using it (the refresh queries every install).
    func sceneDidEnterBackground(_ scene: UIScene) {
        ShortcutParameterRefresh.shared.refreshIfNeeded()
    }

    // Long-press Home Screen quick action "Switch install" (canvas Q7).
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard shortcutItem.type == Self.switchInstallShortcut else { return completionHandler(false) }
        bridge?.presentPicker()
        completionHandler(true)
    }

    func scene(_ scene: UIScene, openURLContexts urlContexts: Set<UIOpenURLContext>) {
        #if DEBUG
            // `burrow://debug/voip?payload=`: the ring injection seam.
            if urlContexts.contains(where: { DebugVoIPSeam.handle(url: $0.url) }) { return }
            // `burrow://debug/personal-context?host=`: donation and index counts.
            if urlContexts.contains(where: { DebugPersonalContext.handle(url: $0.url) }) { return }
            // `burrow://debug/push-key?host=`: a sealed-preview key for a test push.
            if urlContexts.contains(where: { DebugPushKeySeam.handle(url: $0.url) }) { return }
        #endif
        // `burrow://open?...` is a widget deep link (SuiteBridgeViewController
        // opens it); anything else is Capacitor's.
        if let link = urlContexts.lazy.compactMap({ DeepLink(url: $0.url) }).first {
            bridge?.open(link)
            return
        }
        SceneDelegateProxy.shared.scene(scene, openURLContexts: urlContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        // A tap on a Burrow call in the phone app's Recents.
        if let intent = userActivity.interaction?.intent as? INStartCallIntent,
            let handle = intent.contacts?.first?.personHandle?.value
        {
            CallController.shared.rejoinFromRecents(handle: handle)
            return
        }
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}
