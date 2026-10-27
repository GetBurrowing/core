import CoreText
import UIKit

// The native tab bar (task 01a1557b): the system's own UITabBar over the web
// view, so iOS 26+ draws real Liquid Glass. The web names the tabs and their
// order (`items` in `SuiteNative.tabBarState`); native only knows how to draw
// each key. Labels always shown. Stock material: no backgroundColor and no
// custom appearance on iOS 26+ (design direction canvas 01a1724a, rule zero).

/// How one tab key is drawn: its label and the masters' own glyph
/// (task 01a174e8 stage 2), the same image selected and unselected.
struct NativeTab: Equatable {
    let key: String
    let title: String
    /// An imageset in App/Assets.xcassets: one template SVG, the masters'
    /// glyph verbatim (master-mobile.html), single scale at the 25pt
    /// tab-icon box, vector preserved.
    let image: String

    /// Every key native can draw. A key the web sends that is not here is
    /// dropped; native never invents a tab.
    static let catalog: [NativeTab] = [
        NativeTab(key: "chat", title: "Chat", image: "tab-chat"),
        NativeTab(key: "voice", title: "Voice", image: "tab-voice"),
        NativeTab(key: "tasks", title: "Tasks", image: "tab-tasks"),
        NativeTab(key: "meetings", title: "Meetings", image: "tab-meetings"),
        NativeTab(key: "more", title: "More", image: "tab-more"),
    ]

    /// At most five, so iOS never adds its own "More" overflow item.
    static let maxItems = 5

    static func named(_ key: String, in catalog: [NativeTab] = catalog) -> NativeTab? {
        catalog.first { $0.key == key }
    }

    /// The glyph as a template image, so the bar's selected and unselected
    /// inks paint it. Nil only if the asset is missing from the bundle.
    var glyph: UIImage? { Self.glyph(named: image) }

    /// `traits` picks the display scale the vector is rasterised at; nil
    /// takes the current traits, which is what the bar uses.
    static func glyph(named name: String, traits: UITraitCollection? = nil) -> UIImage? {
        UIImage(named: name, in: Bundle(for: StandaloneTabBarHost.self), compatibleWith: traits)?.withRenderingMode(.alwaysTemplate)
    }
}

/// The tab labels: Public Sans 11pt at weight 550 (the variable font's
/// 'wght' axis), the same selected and unselected, scaled with Dynamic Type
/// as caption2 up to `maximumPointSize`.
enum NativeTabLabel {
    static let size: CGFloat = 11
    static let weight: Double = 550
    static let textStyle = UIFont.TextStyle.caption2
    /// 13pt. The narrowest bar is 375pt; its floating glass platter is inset
    /// 21pt a side (README, "Hosting"), so each of five tabs gets 333 / 5 =
    /// 66.6pt, about 62pt once the platter's own inner padding is taken off.
    /// "Meetings" at wght 550 is 4.4185em wide (measured from
    /// PublicSans-Variable.ttf's advances), so 13pt is 57.4pt (fits with
    /// about 2pt a side) and 14pt is 61.9pt (touches the edges). Past the
    /// cap the Large Content Viewer shows the label.
    static let maximumPointSize: CGFloat = 13
    /// The OpenType 'wght' axis tag.
    static let weightAxis = 0x7767_6874

    static func font(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        let variation = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        let descriptor = UIFontDescriptor(fontAttributes: [.family: BurrowFont.family, variation: [weightAxis: weight]])
        let base = UIFont(descriptor: descriptor, size: size)
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: base, maximumPointSize: maximumPointSize, compatibleWith: traits)
    }

    /// Per item, for `.normal` and `.selected`. Not through
    /// UITabBarAppearance: on iOS 26+ the bar carries no appearance at all
    /// (`NativeTabBarMaterial`). No colour here; the bar's inks paint it.
    static func apply(to item: UITabBarItem, compatibleWith traits: UITraitCollection? = nil) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font(compatibleWith: traits)]
        item.setTitleTextAttributes(attributes, for: .normal)
        item.setTitleTextAttributes(attributes, for: .selected)
    }

    /// The 'wght' value a font draws at, nil if it carries no variation.
    static func variationWeight(of font: UIFont) -> Double? {
        guard let variation = CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber] else { return nil }
        return variation[NSNumber(value: weightAxis)]?.doubleValue
    }
}

/// The tab inks the web resolved from its theme (`ink` in
/// `SuiteNative.tabBarState`, task 01a174e8): each a '#rrggbbaa' string,
/// stored as sent; nil until the web sends one. `NativeTabInkColors` turns
/// them into the bar's tints.
struct NativeTabInk: Equatable {
    var selected: String?
    var unselected: String?

    /// '#rrggbbaa' as a colour; nil for anything else (a missing value, a
    /// short or long string, a non-hex digit, a CSS name).
    static func colour(_ value: String?) -> UIColor? {
        guard let value, value.utf8.count == 9, value.hasPrefix("#") else { return nil }
        let digits = value.dropFirst()
        guard digits.allSatisfy({ $0.isASCII && $0.isHexDigit }), let rgba = UInt32(digits, radix: 16) else { return nil }
        return webInk(rgba: rgba)
    }

    /// The one place this file builds a colour from components: a value the
    /// WEB resolved from its theme tokens, never a literal. ThemeTests
    /// allowlists exactly this line.
    private static func webInk(rgba: UInt32) -> UIColor {
        let channel = { (shift: UInt32) in CGFloat(rgba >> shift & 0xff) / 255 }
        return UIColor(red: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
    }
}

/// The bar's two tints. A web ink that does not parse keeps the previous
/// colour; before any ink parses, the Burrow slots (primary selected, muted
/// unselected).
struct NativeTabInkColors: Equatable {
    var selected: UIColor
    var unselected: UIColor

    static var fallback: NativeTabInkColors {
        NativeTabInkColors(selected: BurrowColor.primary.uiColor, unselected: BurrowColor.muted.uiColor)
    }

    func applying(_ ink: NativeTabInk) -> NativeTabInkColors {
        var next = self
        if let selected = NativeTabInk.colour(ink.selected) { next.selected = selected }
        if let unselected = NativeTabInk.colour(ink.unselected) { next.unselected = unselected }
        return next
    }
}

/// What the web last said through `SuiteNative.tabBarState`
/// (`{items, selected, more_dot, visible, ink, scheme}`). The bar is hidden,
/// has no items and carries no badge until the first state arrives.
struct NativeTabBarState: Equatable {
    /// The keys to draw, in the web's order: known keys only, no repeats, at
    /// most `NativeTab.maxItems`.
    var items: [String] = []
    var selected: String?
    var moreDot = false
    var visible = false
    /// The web theme's tab inks. A key the web left out (it could not
    /// resolve that colour) keeps its previous value.
    var ink = NativeTabInk()
    /// "light" or "dark": the web theme's scheme, nil until the web sends one.
    var scheme: String?

    /// The bar's interface style: the web's scheme, the system's until one
    /// arrives.
    var interfaceStyle: UIUserInterfaceStyle {
        switch scheme {
        case "dark": return .dark
        case "light": return .light
        default: return .unspecified
        }
    }

    /// The bar shows only when the web asked for it AND there is something
    /// to draw.
    var shown: Bool { visible && !items.isEmpty }

    /// This state with a bridge payload applied. A missing key, or a value of
    /// the wrong type, leaves that field unchanged. `items` drops unknown and
    /// repeated keys and keeps the first five (logging the cut); a missing or
    /// empty `items`, or one with no known key, keeps the previous items.
    func applying(
        _ payload: [String: Any], catalog: [NativeTab] = NativeTab.catalog, log: (String) -> Void = { NSLog("%@", $0) }
    ) -> NativeTabBarState {
        var next = self
        if let raw = payload["items"] as? [Any] {
            var keys: [String] = []
            for case let key as String in raw where NativeTab.named(key, in: catalog) != nil && !keys.contains(key) {
                keys.append(key)
            }
            if keys.count > NativeTab.maxItems {
                log("native tab bar: \(keys.count) items, keeping the first \(NativeTab.maxItems): \(keys.joined(separator: ","))")
                keys = Array(keys.prefix(NativeTab.maxItems))
            }
            if !keys.isEmpty { next.items = keys }
        }
        if let value = payload["selected"] {
            if value is NSNull {
                next.selected = nil
            } else if let key = value as? String, NativeTab.named(key, in: catalog) != nil {
                next.selected = key
            }
        }
        if let dot = payload["more_dot"] as? Bool { next.moreDot = dot }
        if let visible = payload["visible"] as? Bool { next.visible = visible }
        if let ink = payload["ink"] as? [String: Any] {
            if let selected = ink["selected"] as? String { next.ink.selected = selected }
            if let unselected = ink["unselected"] as? String { next.ink.unselected = unselected }
        }
        if let scheme = payload["scheme"] as? String, scheme == "light" || scheme == "dark" {
            next.scheme = scheme
        }
        return next
    }

    /// A tap on `key` is a reselect when that tab is the selected one.
    func isReselect(_ key: String) -> Bool { key == selected }
}

/// The bar's material. iOS 26+ draws Liquid Glass when nothing is set. On
/// iOS 17-25 a bar with no tracked scroll view would use its transparent
/// scroll-edge appearance, so both appearances get the system DEFAULT
/// background: still the stock material, never a custom colour.
enum NativeTabBarMaterial {
    static var liquidGlassAvailable: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }

    static func apply(to bar: UITabBar, liquidGlass: Bool = liquidGlassAvailable) {
        guard !liquidGlass else { return }
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
    }
}

/// Hosting measured in stage 1 (clients/ios/README.md, "Native tab bar"):
/// a UITabBar pinned to the bottom of the web view. A UITabBarController
/// child drew the same glass on an iPhone but needs five empty pages and a
/// touch-passthrough container, always keeps a selection, and turns into a
/// sidebar at regular width.
@MainActor
protocol NativeTabBarHosting: AnyObject {
    var bar: UITabBar { get }
    /// The keys the bar is drawing, in order.
    var renderedKeys: [String] { get }
    /// The tab key tapped. Selection does NOT change on a tap; it follows the
    /// web's next state.
    var onTap: ((String) -> Void)? { get set }
    func install(in parent: UIViewController)
    func render(_ state: NativeTabBarState)
}

@MainActor
enum NativeTabBarFactory {
    static func make() -> NativeTabBarHosting {
        StandaloneTabBarHost()
    }

    static func item(_ tab: NativeTab, index: Int, compatibleWith traits: UITraitCollection? = nil) -> UITabBarItem {
        let glyph = tab.glyph
        let item = UITabBarItem(title: tab.title, image: glyph, selectedImage: glyph)
        item.largeContentSizeImage = glyph
        NativeTabLabel.apply(to: item, compatibleWith: traits)
        item.tag = index
        item.accessibilityIdentifier = "native-tab-\(tab.key)"
        return item
    }

    /// The stock material; the inks start at the Burrow fallback until the
    /// web sends its own. The Large Content Viewer stays on, so a label past
    /// the font cap is still readable at the largest text sizes.
    static func configure(_ bar: UITabBar) {
        paint(bar, ink: .fallback, style: .unspecified)
        bar.showsLargeContentViewer = true
        bar.accessibilityIdentifier = "native-tab-bar"
        NativeTabBarMaterial.apply(to: bar)
    }

    /// The web theme's inks and scheme on the bar: the selected tab in
    /// `tintColor`, the rest in `unselectedItemTintColor`, the glass in the
    /// web's light or dark.
    static func paint(_ bar: UITabBar, ink: NativeTabInkColors, style: UIUserInterfaceStyle) {
        bar.tintColor = ink.selected
        bar.unselectedItemTintColor = ink.unselected
        bar.overrideUserInterfaceStyle = style
    }

    /// The badge for `key`: `""` (the system red dot) on More while
    /// `more_dot` is true, nil everywhere else. Chat never has one.
    static func badge(for key: String, _ state: NativeTabBarState) -> String? {
        key == "more" && state.moreDot ? "" : nil
    }

    /// The More badge (nil before the first state).
    static func moreBadge(_ state: NativeTabBarState) -> String? {
        badge(for: "more", state)
    }

    /// The bar's height above the bottom safe area: what the web pads with
    /// `--native-tab-bar-height`.
    static func heightAboveSafeArea(barHeight: CGFloat, safeAreaBottom: CGFloat) -> CGFloat {
        max(0, (barHeight - safeAreaBottom).rounded())
    }
}

@MainActor
final class StandaloneTabBarHost: NSObject, NativeTabBarHosting, UITabBarDelegate {
    let bar = UITabBar()
    var onTap: ((String) -> Void)?
    private var state = NativeTabBarState()
    /// The tints last painted; a web ink that does not parse keeps these.
    private(set) var ink = NativeTabInkColors.fallback
    /// The keys `bar.items` was last built from.
    private(set) var renderedKeys: [String] = []
    /// Where the bar is heading; a hide finishing after a newer show does
    /// not hide it.
    private var shownTarget = false

    func install(in parent: UIViewController) {
        bar.items = []
        bar.delegate = self
        NativeTabBarFactory.configure(bar)
        bar.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        // A Dynamic Type change re-scales the labels (a bar item's title
        // font does not follow it on its own).
        bar.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UITabBar, _: UITraitCollection) in
            self?.applyLabelFonts()
        }
        parent.view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor),
        ])
    }

    func render(_ state: NativeTabBarState) {
        self.state = state
        if state.items != renderedKeys {
            renderedKeys = state.items
            let tabs = state.items.compactMap { NativeTab.named($0) }
            let traits = bar.traitCollection
            bar.setItems(tabs.enumerated().map { NativeTabBarFactory.item($1, index: $0, compatibleWith: traits) }, animated: false)
        }
        ink = ink.applying(state.ink)
        NativeTabBarFactory.paint(bar, ink: ink, style: state.interfaceStyle)
        let index = state.selected.flatMap { renderedKeys.firstIndex(of: $0) }
        bar.selectedItem = index.flatMap { bar.items?[$0] }
        for (key, item) in zip(renderedKeys, bar.items ?? []) {
            item.badgeValue = NativeTabBarFactory.badge(for: key, state)
        }
        setShown(state.shown)
    }

    /// Every label at the font for the bar's current content size.
    func applyLabelFonts() {
        let traits = bar.traitCollection
        for item in bar.items ?? [] { NativeTabLabel.apply(to: item, compatibleWith: traits) }
    }

    /// The bar slides down out of view and back with a standard UIKit
    /// animation; hidden (so not hittable) once it is out.
    private func setShown(_ shown: Bool) {
        guard shown != shownTarget else { return }
        shownTarget = shown
        let offset = CGAffineTransform(translationX: 0, y: max(bar.bounds.height, 100))
        if shown {
            if bar.isHidden {
                bar.transform = offset
                bar.isHidden = false
            }
            UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                self.bar.transform = .identity
            }
        } else {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) {
                self.bar.transform = offset
            } completion: { _ in
                guard !self.shownTarget else { return }
                self.bar.isHidden = true
                self.bar.transform = .identity
            }
        }
    }

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        // UITabBar has already moved its selection; put it back. Selection
        // follows the web's next state.
        render(state)
        guard renderedKeys.indices.contains(item.tag) else { return }
        onTap?(renderedKeys[item.tag])
    }
}

#if DEBUG
    /// DEBUG measurement: what the system drew for the bar. Walks the bar's
    /// host (not the web content) and reports glass effect views and their
    /// frames in window coordinates.
    @MainActor
    enum NativeTabBarProbe {
        /// What the bar is drawing right now, for the fixture page:
        /// `keys=chat,voice selected=chat badges=more hidden=false
        /// ink=ad4b07ff/0000008c style=light truncated=none
        /// fonts=Public Sans 11 w550`.
        static func rendered(bar: UITabBar, keys: [String]) -> String {
            let selected = bar.selectedItem.flatMap { item in bar.items?.firstIndex(of: item) }.map { keys[$0] } ?? "none"
            let badges = zip(keys, bar.items ?? []).filter { $0.1.badgeValue != nil }.map(\.0)
            let titles = (bar.items ?? []).compactMap(\.title)
            let styles: [UIUserInterfaceStyle: String] = [.light: "light", .dark: "dark"]
            let style = styles[bar.overrideUserInterfaceStyle] ?? "unspecified"
            return "keys=\(keys.joined(separator: ",")) titles=\(titles.joined(separator: ",")) selected=\(selected) "
                + "badges=\(badges.isEmpty ? "none" : badges.joined(separator: ",")) hidden=\(bar.isHidden) "
                + "ink=\(hex(bar.tintColor, bar))/\(hex(bar.unselectedItemTintColor, bar)) style=\(style) "
                + "truncated=\(truncatedLabels(bar)) fonts=\(labelFonts(bar))"
        }

        /// The visible tab labels the system cut short (task 01a174e8 stage
        /// 3): the text at the label's font is wider than the label (a label
        /// that shrinks to fit counts at its smallest scale). `none` when
        /// every visible label fits.
        static func truncatedLabels(_ bar: UITabBar) -> String {
            var cut: [String] = []
            func visible(_ view: UIView) -> Bool {
                var current: UIView? = view
                while let node = current, node !== bar.superview {
                    if node.isHidden || node.alpha <= 0.01 { return false }
                    current = node.superview
                }
                return true
            }
            func walk(_ view: UIView) {
                if let label = view as? UILabel, let text = label.text, !text.isEmpty, label.bounds.width > 1, visible(label) {
                    let needed = (text as NSString).size(withAttributes: [.font: label.font as Any]).width
                    let floor = label.adjustsFontSizeToFitWidth ? max(label.minimumScaleFactor, 0.01) : 1
                    if needed * floor > label.bounds.width + 0.5, !cut.contains(text) { cut.append(text) }
                }
                for child in view.subviews { walk(child) }
            }
            walk(bar)
            return cut.isEmpty ? "none" : cut.joined(separator: ",")
        }

        /// A tint as `rrggbbaa`, resolved in the bar's own traits.
        static func hex(_ colour: UIColor?, _ bar: UITabBar) -> String {
            guard let colour else { return "none" }
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            guard colour.resolvedColor(with: bar.traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a) else { return "unresolved" }
            return [r, g, b, a].map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
        }

        /// The fonts the system actually drew the tab labels in (the labels
        /// under the bar), e.g. `Public Sans 11 w550`; `none` if no label
        /// was found. This is the check that iOS honoured the per-item font.
        static func labelFonts(_ bar: UITabBar) -> String {
            var fonts: [String] = []
            func walk(_ view: UIView) {
                if let label = view as? UILabel, let text = label.text, !text.isEmpty {
                    let weight = NativeTabLabel.variationWeight(of: label.font).map { "w\(Int($0.rounded()))" } ?? "w-"
                    let name = "\(label.font.familyName) \(Int(label.font.pointSize.rounded())) \(weight)"
                    if !fonts.contains(name) { fonts.append(name) }
                }
                for child in view.subviews { walk(child) }
            }
            walk(bar)
            return fonts.isEmpty ? "none" : fonts.joined(separator: ";")
        }

        static func describe(_ frame: CGRect) -> String {
            "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
        }

        static func report(bar: UITabBar, root: UIView) -> [String: Any] {
            var lines: [String] = []
            var glassEffect = false
            var glassNamed = false
            var platters: [CGRect] = []
            let window = root.window ?? root
            func walk(_ view: UIView, depth: Int) {
                if view is UIScrollView, !(view.isDescendant(of: bar)) { return }
                let name = NSStringFromClass(type(of: view))
                if name.localizedCaseInsensitiveContains("glass") || name.contains("LiquidLens") { glassNamed = true }
                if #available(iOS 26, *), let effectView = view as? UIVisualEffectView, effectView.effect is UIGlassEffect {
                    glassEffect = true
                }
                let frame = view.convert(view.bounds, to: window)
                if name.contains("Platter"), !view.isHidden, view.alpha > 0 { platters.append(frame) }
                if depth <= 8, view.isDescendant(of: bar) {
                    lines.append("\(String(repeating: " ", count: depth))\(name) \(describe(frame))")
                }
                for child in view.subviews { walk(child, depth: depth + 1) }
            }
            walk(root, depth: 0)
            // Floating: the bar's platter is inset from the screen's sides
            // and bottom, rather than an edge-to-edge strip.
            let screen = window.bounds
            let widest = platters.max { $0.width < $1.width }
            let floating = widest.map { $0.minX > 1 && $0.maxX < screen.width - 1 && $0.maxY < screen.height - 1 } ?? false
            let barFrame = bar.convert(bar.bounds, to: window)
            return [
                "glass_effect": glassEffect,
                "glass_class": glassNamed,
                "floating": floating,
                "platter": widest.map(describe) ?? "none",
                "bar": describe(barFrame),
                "os": UIDevice.current.systemVersion,
                "tree": lines.joined(separator: "\n"),
            ]
        }
    }
#endif
