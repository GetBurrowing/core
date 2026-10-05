import SwiftUI
import WidgetKit
import XCTest

/// Evidence only, not an assertion suite: renders the share sheet and the
/// widgets with ImageRenderer to PNGs for the stage evidence canvas. The
/// share sheet and widgets are hard to drive headlessly on a simulator.
/// Run with the Render scheme and `TEST_RUNNER_SUITE_RENDER_DIR=<dir>`.
@MainActor
final class ExtensionRenderTests: XCTestCase {
    private var outDir: URL!
    private let now = Date()

    override func setUpWithError() throws {
        let dir = ProcessInfo.processInfo.environment["SUITE_RENDER_DIR"]
        try XCTSkipIf(dir == nil, "SUITE_RENDER_DIR not set")
        outDir = URL(fileURLWithPath: dir!)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    private func save<V: View>(_ name: String, _ view: V, size: CGSize, dark: Bool = false) throws {
        let framed = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage, name)
        try XCTUnwrap(image.pngData()).write(to: outDir.appendingPathComponent("\(name).png"))
    }

    /// ImageRenderer draws neither ScrollView nor UIKit-backed controls
    /// (TextField, Menu), so the share sheet is snapshotted from a real
    /// window instead.
    private func snapshot<V: View>(_ name: String, _ view: V, size: CGSize) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .light
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        try XCTUnwrap(image.pngData()).write(to: outDir.appendingPathComponent("\(name).png"))
    }

    // MARK: Share sheet

    private func sheet(_ configure: (ShareSheetModel) -> Void) -> some View {
        let model = ShareSheetModel(install: Install(host: "suite.example.com"))
        configure(model)
        return ShareSheetView(model: model, onCancel: {}, onDone: {})
    }

    private let spaces = [
        try! JSONDecoder().decode(SuiteSpace.self, from: Data("""
        {"id":"s1","name":"Internal Fabrikam SXI","slug":"sxi","kind":"channel","agents":[{"id":"a1","name":"Saru","slug":"saru"}]}
        """.utf8))
    ]

    func testShareSheetStates() throws {
        let size = CGSize(width: 402, height: 560)
        let url = SharePayload.url(URL(string: "https://example.com/launch-brief")!)
        try snapshot("share-loading", sheet { $0.payload = url; $0.debugSet(phase: .loadingSpaces) }, size: size)
        try snapshot("share-not-signed-in", sheet { $0.debugSet(phase: .notSignedIn) }, size: size)
        try snapshot("share-sent", sheet {
            $0.payload = url
            $0.debugSet(phase: .ready, spaces: spaces)
            $0.selectedSpaceID = "s1"
            $0.debugSet(phase: .sent(spaceName: "Internal Fabrikam SXI"))
        }, size: size)
        try snapshot("share-failed", sheet {
            $0.payload = url
            $0.debugSet(phase: .ready, spaces: spaces)
            $0.selectedSpaceID = "s1"
            $0.selectedAgentID = "a1"
            $0.message = "Can you check the dates?"
            $0.debugSet(phase: .ready, banner: .sendFailed)
        }, size: size)
    }

    // MARK: Widgets

    private func entry(approvals: Int, tasks: Int, minutesOld: Double = 2, signedIn: Bool = true) -> CountsEntry {
        CountsEntry(date: now, host: "suite.example.com", signedIn: signedIn,
                    counts: SuiteCounts(approvals: approvals, tasks: tasks, fetchedAt: now.addingTimeInterval(-minutesOld * 60)))
    }

    private func widgetFrame<V: View>(_ view: V) -> some View {
        view
            .background(SuiteColor.surface.color)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(12)
            .background(SuiteColor.surfaceMuted.color)
    }

    func testSmallWidgetStates() throws {
        let size = CGSize(width: 194, height: 194)
        for (name, e) in [("live", entry(approvals: 3, tasks: 12)),
                          ("zero", entry(approvals: 0, tasks: 0)),
                          ("stale", entry(approvals: 3, tasks: 12, minutesOld: 47)),
                          ("signed-out", entry(approvals: 0, tasks: 0, signedIn: false)),
                          ("four-digit", entry(approvals: 1284, tasks: 0))] {
            try save("widget-small-\(name)",
                     widgetFrame(SingleCountView(kind: .approvals, entry: e, family: .systemSmall).frame(width: 170, height: 170)),
                     size: size)
        }
    }

    func testMediumWidgetLightAndDark() throws {
        let size = CGSize(width: 388, height: 194)
        let e = entry(approvals: 3, tasks: 0)
        for dark in [false, true] {
            try save("widget-medium-\(dark ? "dark" : "light")",
                     widgetFrame(OverviewView(entry: e, family: .systemMedium).frame(width: 364, height: 170)),
                     size: size, dark: dark)
        }
    }

    func testLockScreenAccessories() throws {
        let e = entry(approvals: 3, tasks: 12)
        func lock<V: View>(_ view: V) -> some View {
            view
                .foregroundStyle(.white)
                .padding(12)
                .background(Color.black.opacity(0.75))
        }
        try save("lock-circular", lock(SingleCountView(kind: .approvals, entry: e, family: .accessoryCircular).frame(width: 72, height: 72)),
                 size: CGSize(width: 96, height: 96), dark: true)
        try save("lock-rectangular", lock(OverviewView(entry: e, family: .accessoryRectangular).frame(width: 172, height: 76)),
                 size: CGSize(width: 196, height: 100), dark: true)
        try save("lock-inline", lock(SingleCountView(kind: .approvals, entry: e, family: .accessoryInline).frame(width: 260, height: 24)),
                 size: CGSize(width: 284, height: 48), dark: true)
    }
}
