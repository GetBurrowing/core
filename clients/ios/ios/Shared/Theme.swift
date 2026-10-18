import SwiftUI
import UIKit

/// The named colour assets (Assets.xcassets). Every colour in the native
/// surfaces comes from one of these slots, each with an Any and a Dark
/// appearance; no colour literal appears in Swift. Slot -> web token table:
/// clients/ios/README.md.
enum BurrowColor: String, CaseIterable {
    /// `primary` (orange) marks primary actions only. `info` (teal-cyan) is
    /// reserved for live state: the live widget count, and on the in-call
    /// screen (App/Meetings/InCallView.swift) the speaking ring and the one
    /// recovery action of the moment (Resume, Try again), which the design
    /// canvas draws in its cyan. Outside the call no button is ever cyan.
    case primary, onPrimary, accent, info, onInfo, surface, surfaceMuted, onSurface, muted, border, destructive

    var color: Color { Color(rawValue) }
    var uiColor: UIColor { UIColor(named: rawValue) ?? .label }
}

/// Public Sans (bundled, OFL), scaled with Dynamic Type through `relativeTo`.
enum BurrowFont {
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

    /// The unread pill on a picker row (task 01a1261e): 12pt, semibold.
    static func pill() -> Font {
        .custom(family, size: 12, relativeTo: .caption).weight(.semibold)
    }

    /// Inputs stay at 16pt minimum so iOS never zooms a focused field.
    static func input() -> Font {
        .custom(family, size: 17, relativeTo: .body)
    }

    /// Utility type: a host to read character by character (the add-install
    /// confirmation card, task 01a12787).
    static func mono() -> Font {
        .system(.subheadline, design: .monospaced)
    }
}

enum BurrowRadius {
    static let field: CGFloat = 10
    static let box: CGFloat = 14
}

/// Regular width (iPad full screen and wide Split View): native surfaces sit
/// in a centred column no wider than a form sheet. Compact width (iPhone,
/// Slide Over, narrow Split View) keeps the iPhone layout. Layout follows
/// the size class, never the device idiom.
enum BurrowLayout {
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
    func burrowFormSheet(regular: Bool) -> some View {
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
                        width: BurrowLayout.columnWidth(available: geometry.size.width),
                        height: max(0, min(BurrowLayout.sheetMaxHeight, geometry.size.height - 2 * BurrowLayout.gutter))
                    )
                    .background(BurrowColor.surface.color)
                    .clipShape(RoundedRectangle(cornerRadius: BurrowRadius.box, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: BurrowRadius.box, style: .continuous)
                            .stroke(BurrowColor.border.color, lineWidth: 1)
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .background(BurrowColor.surfaceMuted.color.ignoresSafeArea())
        } else {
            content
        }
    }
}
