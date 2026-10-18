import SwiftUI
import UIKit

/// "Switched to <install>" (task 01a1261e stage 4): a 2-second top banner
/// after a notification tap or Open moved the app to ANOTHER install, so the
/// person knows which sign-in they are now looking at. No banner when the
/// tap is for the install already showing.
enum SwitchBanner {
    static let duration: TimeInterval = 2

    static func message(_ installName: String) -> String { "Switched to \(installName)" }

    static func shouldShow(currentHost: String?, targetHost: String) -> Bool {
        guard let currentHost else { return false }
        return currentHost.lowercased() != targetHost.lowercased()
    }
}

struct SwitchBannerView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(BurrowFont.secondary(.semibold))
            .foregroundColor(BurrowColor.onSurface.color)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous).fill(BurrowColor.surface.color)
            )
            .overlay(Capsule(style: .continuous).stroke(BurrowColor.border.color, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("switch-banner")
    }
}

/// Presents `SwitchBannerView` over a view controller's top safe area and
/// removes it after `SwitchBanner.duration`. A newer banner replaces one
/// still showing.
@MainActor
final class SwitchBannerPresenter {
    private weak var current: UIView?

    func show(_ text: String, in host: UIViewController) {
        current?.removeFromSuperview()
        let hosting = UIHostingController(rootView: SwitchBannerView(text: text))
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.isUserInteractionEnabled = false
        host.view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            hosting.view.centerXAnchor.constraint(equalTo: host.view.centerXAnchor),
            hosting.view.leadingAnchor.constraint(greaterThanOrEqualTo: host.view.leadingAnchor, constant: 16),
        ])
        UIAccessibility.post(notification: .announcement, argument: text)
        let view: UIView = hosting.view
        current = view
        view.alpha = 0
        UIView.animate(withDuration: 0.2) { view.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + SwitchBanner.duration) {
            UIView.animate(withDuration: 0.2, animations: { view.alpha = 0 }, completion: { _ in view.removeFromSuperview() })
        }
    }
}
