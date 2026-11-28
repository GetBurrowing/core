import SwiftUI

/// Render-test guard for the widgets' fit rules (task 01a21e75 stage 7):
/// a count never truncates, an install label is dropped whole before a name
/// truncates, and no row is drawn outside the widget. Off in the app and the
/// extension (`isEnabled` is false, so every probe below is the view
/// unchanged); ExtensionRenderTests switches it on and asserts `misses()` is
/// empty after each render. Ids, sizes and frames only: never the text.
enum FitProbe {
    static var isEnabled = false
    static let space = "fit-probe-root"

    private static var lines: [String: (ideal: CGSize, placed: CGSize)] = [:]
    private static var wraps: [String: (ideal: CGFloat, placed: CGFloat)] = [:]
    private static var frames: [String: CGRect] = [:]
    /// Frames that must not overlap each other, by group.
    private static var groups: [String: [String: CGRect]] = [:]
    private static var root: CGSize?

    static func reset() {
        lines = [:]
        wraps = [:]
        frames = [:]
        groups = [:]
        root = nil
    }

    static func line(_ id: String, ideal: CGSize, placed: CGSize) {
        if placed.width > 0 { lines[id] = (ideal, placed) }
    }

    static func wrap(_ id: String, ideal: CGFloat, placed: CGFloat) {
        if placed > 0 { wraps[id] = (ideal, placed) }
    }

    static func frame(_ id: String, _ rect: CGRect) {
        if rect.width > 0 { frames[id] = rect }
    }

    static func member(_ group: String, _ id: String, _ rect: CGRect) {
        if rect.width > 0 { groups[group, default: [:]][id] = rect }
    }

    static func setRoot(_ size: CGSize) {
        if size.width > 0 { root = size }
    }

    /// Every rule broken by the last render, by probe id.
    static func misses(tolerance: CGFloat = 0.5) -> [String] {
        var out: [String] = []
        for (id, m) in lines {
            if m.ideal.width > m.placed.width + tolerance {
                out.append("\(id): truncated (needs \(Int(m.ideal.width.rounded(.up))), has \(Int(m.placed.width)))")
            }
            if m.ideal.height > m.placed.height + tolerance {
                out.append("\(id): clipped (needs \(Int(m.ideal.height.rounded(.up))) tall, has \(Int(m.placed.height)))")
            }
        }
        for (id, m) in wraps where m.ideal > m.placed + tolerance {
            out.append("\(id): cut (needs \(Int(m.ideal.rounded(.up))) tall, has \(Int(m.placed)))")
        }
        if let root {
            let bounds = CGRect(origin: .zero, size: root).insetBy(dx: -tolerance, dy: -tolerance)
            for (id, rect) in frames where !bounds.contains(rect) {
                out.append("\(id): drawn outside the widget (\(Int(rect.minY))...\(Int(rect.maxY)) of \(Int(root.height)))")
            }
        }
        for (group, members) in groups {
            let sorted = members.sorted { $0.key < $1.key }
            for (i, a) in sorted.enumerated() {
                for b in sorted.dropFirst(i + 1) where a.value.insetBy(dx: tolerance, dy: tolerance).intersects(b.value.insetBy(dx: tolerance, dy: tolerance)) {
                    out.append("\(group): \(a.key) overlaps \(b.key)")
                }
                if let root, !CGRect(origin: .zero, size: root).insetBy(dx: -tolerance, dy: -tolerance).contains(a.value) {
                    out.append("\(group): \(a.key) drawn outside the widget")
                }
            }
        }
        return out.sorted()
    }
}

extension View {
    /// One line that must never truncate: its single-line ideal width fits
    /// the width it was given.
    @ViewBuilder func neverTruncates(_ id: String) -> some View {
        if FitProbe.isEnabled {
            background(
                GeometryReader { placed in
                    self.lineLimit(1).fixedSize().hidden()
                        .background(
                            GeometryReader { ideal in
                                let _ = FitProbe.line(id, ideal: ideal.size, placed: placed.size)
                                Color.clear
                            })
                })
        } else {
            self
        }
    }

    /// Wrapping text that must never be cut: at the width it was given, all
    /// of it fits the height it was given. Apply BEFORE any `lineLimit`.
    @ViewBuilder func neverCut(_ id: String) -> some View {
        if FitProbe.isEnabled {
            background(
                GeometryReader { placed in
                    self.lineLimit(nil).fixedSize(horizontal: false, vertical: true).frame(width: placed.size.width).hidden()
                        .background(
                            GeometryReader { ideal in
                                let _ = FitProbe.wrap(id, ideal: ideal.size.height, placed: placed.size.height)
                                Color.clear
                            })
                })
        } else {
            self
        }
    }

    /// A row that must be drawn inside the widget (`fitProbeRoot`).
    @ViewBuilder func staysInside(_ id: String) -> some View {
        if FitProbe.isEnabled {
            background(
                GeometryReader { proxy in
                    let _ = FitProbe.frame(id, proxy.frame(in: .named(FitProbe.space)))
                    Color.clear
                })
        } else {
            self
        }
    }

    /// Text that must not overlap any other member of `group`, nor leave
    /// the widget (`fitProbeRoot`).
    @ViewBuilder func noOverlap(_ group: String, _ id: String) -> some View {
        if FitProbe.isEnabled {
            background(
                GeometryReader { proxy in
                    let _ = FitProbe.member(group, id, proxy.frame(in: .named(FitProbe.space)))
                    Color.clear
                })
        } else {
            self
        }
    }

    /// The widget's drawing area, which `staysInside` rows are measured against.
    @ViewBuilder func fitProbeRoot() -> some View {
        if FitProbe.isEnabled {
            coordinateSpace(name: FitProbe.space)
                .background(
                    GeometryReader { proxy in
                        let _ = FitProbe.setRoot(proxy.size)
                        Color.clear
                    })
        } else {
            self
        }
    }
}
