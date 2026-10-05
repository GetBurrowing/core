import SwiftUI
import UIKit

/// The named colour assets (Assets.xcassets). Every colour in the native
/// surfaces comes from one of these slots, each with an Any and a Dark
/// appearance; no colour literal appears in Swift. Slot -> web token table:
/// clients/ios/README.md.
enum SuiteColor: String, CaseIterable {
    case primary, onPrimary, accent, surface, surfaceMuted, onSurface, muted, border, destructive

    var color: Color { Color(rawValue) }
    var uiColor: UIColor { UIColor(named: rawValue) ?? .label }
}

/// Public Sans (bundled, OFL), scaled with Dynamic Type through `relativeTo`.
enum SuiteFont {
    static let family = "Public Sans"

    static func title() -> Font {
        .custom(family, size: 28, relativeTo: .title).weight(.heavy)
    }

    static func body(_ weight: Font.Weight = .regular) -> Font {
        .custom(family, size: 17, relativeTo: .body).weight(weight)
    }

    static func secondary(_ weight: Font.Weight = .regular) -> Font {
        .custom(family, size: 15, relativeTo: .subheadline).weight(weight)
    }

    static func caption(_ weight: Font.Weight = .regular) -> Font {
        .custom(family, size: 13, relativeTo: .footnote).weight(weight)
    }

    /// Inputs stay at 16pt minimum so iOS never zooms a focused field.
    static func input() -> Font {
        .custom(family, size: 17, relativeTo: .body)
    }
}

enum SuiteRadius {
    static let field: CGFloat = 10
    static let box: CGFloat = 14
}
