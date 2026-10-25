import UIKit

// The native tab bar (task 01a1557b): the system's own UITabBar over the web
// view, so iOS 26+ draws real Liquid Glass. The web names the tabs and their
// order (`items` in `SuiteNative.tabBarState`); native only knows how to draw
// each key. Labels always shown. Stock material: no backgroundColor and no
// custom appearance on iOS 26+ (design direction canvas 01a1724a, rule zero).

/// How one tab key is drawn: its label and the SF Symbols that match the
/// masters' glyphs (outline at rest, `.fill` when selected where one exists).
struct NativeTab: Equatable {
    let key: String
    let title: String
    let symbol: String
    let selectedSymbol: String

    /// Every key native can draw. A key the web sends that is not here is
    /// dropped; native never invents a tab.
    static let catalog: [NativeTab] = [
        NativeTab(key: "chat", title: "Chat", symbol: "ellipsis.bubble", selectedSymbol: "ellipsis.bubble.fill"),
        NativeTab(key: "voice", title: "Voice", symbol: "mic", selectedSymbol: "mic.fill"),
        NativeTab(key: "tasks", title: "Tasks", symbol: "checklist", selectedSymbol: "checklist"),
        NativeTab(key: "meetings", title: "Meetings", symbol: "video", selectedSymbol: "video.fill"),
        NativeTab(key: "more", title: "More", symbol: "ellipsis", selectedSymbol: "ellipsis"),
    ]

    /// At most five, so iOS never adds its own "More" overflow item.
    static let maxItems = 5

    static func named(_ key: String, in catalog: [NativeTab] = catalog) -> NativeTab? {
        catalog.first { $0.key == key }
    }
}

/// The tab inks the web resolved from its theme (`ink` in
/// `SuiteNative.tabBarState`, task 01a174e8): each a '#rrggbbaa' string,
/// stored as sent. Nothing draws with them yet; nil until the web sends one.
struct NativeTabInk: Equatable {
    var selected: String?
    var unselected: String?
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

    static func item(_ tab: NativeTab, index: Int) -> UITabBarItem {
        let item = UITabBarItem(title: tab.title, image: UIImage(systemName: tab.symbol), selectedImage: UIImage(systemName: tab.selectedSymbol))
        item.tag = index
        item.accessibilityIdentifier = "native-tab-\(tab.key)"
        return item
    }

    /// Selected tint is base-content (onSurface), not the brand colour;
    /// unselected items keep the system default.
    static func configure(_ bar: UITabBar) {
        bar.tintColor = BurrowColor.onSurface.uiColor
        bar.accessibilityIdentifier = "native-tab-bar"
        NativeTabBarMaterial.apply(to: bar)
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
            bar.setItems(tabs.enumerated().map { NativeTabBarFactory.item($1, index: $0) }, animated: false)
        }
        let index = state.selected.flatMap { renderedKeys.firstIndex(of: $0) }
        bar.selectedItem = index.flatMap { bar.items?[$0] }
        for (key, item) in zip(renderedKeys, bar.items ?? []) {
            item.badgeValue = NativeTabBarFactory.badge(for: key, state)
        }
        setShown(state.shown)
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
        /// `keys=chat,voice selected=chat badges=more hidden=false`.
        static func rendered(bar: UITabBar, keys: [String]) -> String {
            let selected = bar.selectedItem.flatMap { item in bar.items?.firstIndex(of: item) }.map { keys[$0] } ?? "none"
            let badges = zip(keys, bar.items ?? []).filter { $0.1.badgeValue != nil }.map(\.0)
            let titles = (bar.items ?? []).compactMap(\.title)
            return "keys=\(keys.joined(separator: ",")) titles=\(titles.joined(separator: ",")) selected=\(selected) "
                + "badges=\(badges.isEmpty ? "none" : badges.joined(separator: ",")) hidden=\(bar.isHidden)"
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
