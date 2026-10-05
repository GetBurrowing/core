import Capacitor
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

        // Cold launch from a widget: park the link for when the shell starts.
        if let link = connectionOptions.urlContexts.lazy.compactMap({ DeepLink(url: $0.url) }).first {
            shell.pendingDeepLink = link
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        WidgetCountsRefresher.refresh()
    }

    // Long-press Home Screen quick action "Switch install" (canvas Q7).
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        guard shortcutItem.type == Self.switchInstallShortcut else { return completionHandler(false) }
        bridge?.presentPicker()
        completionHandler(true)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        // `burrow://open?...` is a widget deep link (SuiteBridgeViewController
        // opens it); anything else is Capacitor's.
        if let link = URLContexts.lazy.compactMap({ DeepLink(url: $0.url) }).first {
            bridge?.open(link)
            return
        }
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}
