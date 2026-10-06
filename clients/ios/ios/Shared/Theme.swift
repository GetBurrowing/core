import SwiftUI
import UIKit

/// The named colour assets (Assets.xcassets). Every colour in the native
/// surfaces comes from one of these slots, each with an Any and a Dark
/// appearance; no colour literal appears in Swift. Slot -> web token table:
/// clients/ios/README.md.
enum SuiteColor: String, CaseIterable {
    /// `primary` (orange) marks primary actions only. `info` (teal-cyan) is
    /// reserved for the live widget count: cyan means live, and no button
    /// is ever cyan.
    case primary, onPrimary, accent, info, onInfo, surface, surfaceMuted, onSurface, muted, border, destructive

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

/// Regular width (iPad full screen and wide Split View): native surfaces sit
/// in a centred column no wider than a form sheet. Compact width (iPhone,
/// Slide Over, narrow Split View) keeps the iPhone layout. Layout follows
/// the size class, never the device idiom.
enum SuiteLayout {
    /// UIKit's form-sheet width.
    static let sheetWidth: CGFloat = 540
    /// Side gutters once the space is narrower than a sheet plus gutters.
    static let gutter: CGFloat = 24
    /// The tallest a centred sheet gets; shorter windows get gutters.
    static let sheetMaxHeight: CGFloat = 720

    /// The column width for an available width: the sheet width, less
    /// gutters when there is not room for both.
    static func columnWidth(available: CGFloat) -> CGFloat {
        max(0, min(sheetWidth, available - 2 * gutter))
    }
}

extension View {
    /// Regular width: the view becomes a centred card (surface fill, box
    /// radius, border) on the muted surface. Compact: unchanged.
    func suiteFormSheet(regular: Bool) -> some View {
        modifier(FormSheetLayout(regular: regular))
    }
}

struct FormSheetLayout: ViewModifier {
    let regular: Bool

    func body(content: Content) -> some View {
        if regular {
            GeometryReader { geometry in
                content
                    .frame(
                        width: SuiteLayout.columnWidth(available: geometry.size.width),
                        height: max(0, min(SuiteLayout.sheetMaxHeight, geometry.size.height - 2 * SuiteLayout.gutter))
                    )
                    .background(SuiteColor.surface.color)
                    .clipShape(RoundedRectangle(cornerRadius: SuiteRadius.box, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: SuiteRadius.box, style: .continuous)
                            .stroke(SuiteColor.border.color, lineWidth: 1)
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .background(SuiteColor.surfaceMuted.color.ignoresSafeArea())
        } else {
            content
        }
    }
}
