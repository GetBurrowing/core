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
        let framed =
            view
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
    private func snapshot<V: View>(_ name: String, _ view: V, size: CGSize, settle: TimeInterval = 0.6) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .light
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
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
        try! JSONDecoder().decode(
            SuiteSpace.self,
            from: Data(
                """
                {"id":"s1","name":"Internal Fabrikam SXI","slug":"sxi","kind":"channel","agents":[{"id":"a1","name":"Saru","slug":"saru"}]}
                """.utf8))
    ]

    func testShareSheetStates() throws {
        let size = CGSize(width: 402, height: 560)
        let url = SharePayload.url(URL(string: "https://example.com/launch-brief")!)
        try snapshot(
            "share-loading",
            sheet {
                $0.payload = url
                $0.debugSet(phase: .loadingSpaces)
            }, size: size)
        try snapshot("share-not-signed-in", sheet { $0.debugSet(phase: .notSignedIn) }, size: size)
        try snapshot(
            "share-sent",
            sheet {
                $0.payload = url
                $0.debugSet(phase: .ready, spaces: spaces)
                $0.selectedSpaceID = "s1"
                $0.debugSet(phase: .sent(spaceName: "Internal Fabrikam SXI"))
            }, size: size)
        try snapshot(
            "share-failed",
            sheet {
                $0.payload = url
                $0.debugSet(phase: .ready, spaces: spaces)
                $0.selectedSpaceID = "s1"
                $0.selectedAgentID = "a1"
                $0.message = "Can you check the dates?"
                $0.debugSet(phase: .ready, banner: .sendFailed)
            }, size: size)
    }

    // MARK: iPad (task 01a10db6 stage 2)

    /// iPad Pro 13-inch (M5), in points.
    private let padPortrait = CGSize(width: 1032, height: 1376)
    private let padLandscape = CGSize(width: 1376, height: 1032)
    /// A 1/3 Split View column in landscape: compact width.
    private let padSplitThird = CGSize(width: 438, height: 1032)
    private let phone = CGSize(width: 402, height: 874)

    private func picker(_ sizeClass: UserInterfaceSizeClass) -> some View {
        let defaults = UserDefaults(suiteName: "ExtensionRenderTests.\(UUID().uuidString)")
        let model = InstallPickerModel(store: InstallStore(defaults: defaults))
        return InstallPickerView(model: model, onContinue: { _ in })
            .environment(\.horizontalSizeClass, sizeClass)
    }

    /// The share extension as the system presents it on iPad: a form sheet
    /// of `SuiteLayout.sheetWidth` x 620 centred over the host app.
    private func shareFormSheet<V: View>(_ sheet: V, in size: CGSize) -> some View {
        ZStack {
            SuiteColor.surfaceMuted.color
            sheet
                .environment(\.horizontalSizeClass, .regular)
                .frame(width: SuiteLayout.sheetWidth, height: 620)
                .clipShape(RoundedRectangle(cornerRadius: SuiteRadius.box, style: .continuous))
        }
        .frame(width: size.width, height: size.height)
    }

    private func readySheet() -> some View {
        sheet {
            $0.payload = SharePayload.url(URL(string: "https://example.com/launch-brief")!)
            $0.debugSet(phase: .ready, spaces: spaces)
            $0.selectedSpaceID = "s1"
            $0.message = "Can you check the dates?"
        }
    }

    func testInstallPickerOnIPadAndIPhone() throws {
        try snapshot("ipad-picker-portrait", picker(.regular), size: padPortrait, settle: 1.5)
        try snapshot("ipad-picker-landscape", picker(.regular), size: padLandscape, settle: 1.5)
        try snapshot("ipad-picker-split-third", picker(.compact), size: padSplitThird, settle: 1.5)
        try snapshot("iphone-picker", picker(.compact), size: phone, settle: 1.5)
    }

    func testShareSheetOnIPadAndIPhone() throws {
        try snapshot("ipad-share-portrait", shareFormSheet(readySheet(), in: padPortrait), size: padPortrait)
        try snapshot("ipad-share-landscape", shareFormSheet(readySheet(), in: padLandscape), size: padLandscape)
        try snapshot(
            "ipad-share-split-third", readySheet().environment(\.horizontalSizeClass, .compact),
            size: CGSize(width: padSplitThird.width, height: 620))
        try snapshot(
            "iphone-share", readySheet().environment(\.horizontalSizeClass, .compact),
            size: CGSize(width: phone.width, height: 560))
    }

    // MARK: Widgets

    private func entry(approvals: Int, tasks: Int, minutesOld: Double = 2, signedIn: Bool = true) -> CountsEntry {
        CountsEntry(
            date: now, host: "suite.example.com", signedIn: signedIn,
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
        for (name, e) in [
            ("live", entry(approvals: 3, tasks: 12)),
            ("zero", entry(approvals: 0, tasks: 0)),
            ("stale", entry(approvals: 3, tasks: 12, minutesOld: 47)),
            ("signed-out", entry(approvals: 0, tasks: 0, signedIn: false)),
            ("four-digit", entry(approvals: 1284, tasks: 0)),
        ] {
            try save(
                "widget-small-\(name)",
                widgetFrame(SingleCountView(kind: .approvals, entry: e, family: .systemSmall).frame(width: 170, height: 170)),
                size: size)
        }
    }

    func testMediumWidgetLightAndDark() throws {
        let size = CGSize(width: 388, height: 194)
        let e = entry(approvals: 3, tasks: 0)
        for dark in [false, true] {
            try save(
                "widget-medium-\(dark ? "dark" : "light")",
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
        try save(
            "lock-circular", lock(SingleCountView(kind: .approvals, entry: e, family: .accessoryCircular).frame(width: 72, height: 72)),
            size: CGSize(width: 96, height: 96), dark: true)
        try save(
            "lock-rectangular", lock(OverviewView(entry: e, family: .accessoryRectangular).frame(width: 172, height: 76)),
            size: CGSize(width: 196, height: 100), dark: true)
        try save(
            "lock-inline", lock(SingleCountView(kind: .approvals, entry: e, family: .accessoryInline).frame(width: 260, height: 24)),
            size: CGSize(width: 284, height: 48), dark: true)
    }

    // MARK: Siri and Shortcuts snippets (task 01a10db6 stage 3)

    /// The system card a snippet sits in: the spoken/printed dialog line on
    /// top, then the snippet, on the system material over a wallpaper. The
    /// card and the dialog line are iOS's; only the snippet is ours. iOS
    /// draws its own Confirm and Cancel under a confirmation, not shown here.
    private func siriCard<V: View>(dialog: String, _ snippet: V) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(white: 0.55), Color(white: 0.35)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Text(dialog)
                    .font(.body)
                    .foregroundStyle(SuiteColor.onSurface.color)
                    .padding([.horizontal, .top], 16)
                snippet
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(12)
        }
    }

    func testSiriSnippets() throws {
        let size = CGSize(width: 402, height: 520)
        func row(_ n: Int, _ title: String, _ space: String) -> (id: String, approval: SuiteApproval) {
            (
                "suite.example.com|ap\(n)",
                SuiteApproval(
                    id: "ap\(n)", kind: n == 1 ? "plan" : "review", title: title, spaceName: space, spacePathSegment: nil, taskID: nil,
                    insertedAt: nil, summary: nil)
            )
        }
        let summary = WaitingSummary(
            approvals: [row(1, "Burrow iOS intents plan", "Burrow iOS"), row(2, "Banner copy review", "Internal Fabrikam SXI")],
            tasks: [
                SuiteTask(id: "t1", title: "Ship the widget confirm strip", status: "in_progress", projectName: "Burrow iOS"),
                SuiteTask(id: "t2", title: "Rotate the APNs key", status: "todo", projectName: "Infrastructure"),
            ])
        try snapshot(
            "snippet-whats-waiting",
            siriCard(
                dialog: summary.dialog,
                WaitingSnippetView(summary: summary) { row in
                    if row.approvalID != nil {
                        HStack(spacing: 8) {
                            Button("Approve") {}.buttonStyle(SuiteApproveButtonStyle())
                            Button("Reject") {}.buttonStyle(SuiteRejectButtonStyle())
                        }
                    }
                }), size: size)
        try snapshot(
            "snippet-nothing-waiting",
            siriCard(dialog: IntentCopy.nothingWaiting, WaitingSnippetView(summary: WaitingSummary(approvals: [], tasks: []))),
            size: CGSize(width: 402, height: 200))
        try snapshot(
            "snippet-approve-confirm",
            siriCard(
                dialog: IntentCopy.approveConfirm(isPlan: true, title: "Burrow iOS: App Intents", space: "Burrow iOS", install: nil),
                ConfirmSnippetView.approve(isPlan: true, title: "Burrow iOS: App Intents", space: "Burrow iOS", install: nil)),
            size: CGSize(width: 402, height: 320))
        try snapshot(
            "snippet-approve-confirm-multi-install",
            siriCard(
                dialog: IntentCopy.approveConfirm(isPlan: true, title: "Burrow iOS: App Intents", space: "Burrow iOS", install: "Fabrikam Suite"),
                ConfirmSnippetView.approve(isPlan: true, title: "Burrow iOS: App Intents", space: "Burrow iOS", install: "Fabrikam Suite")),
            size: CGSize(width: 402, height: 340))
        let question = "Is the banner copy final?"
        try snapshot(
            "snippet-ask-working",
            siriCard(dialog: question, AskAgentSnippetView(agent: "Saru", question: question, state: .working)),
            size: CGSize(width: 402, height: 240))
        try snapshot(
            "snippet-ask-timed-out",
            siriCard(dialog: IntentCopy.agentTimedOut(agent: "Saru"), AskAgentSnippetView(agent: "Saru", question: question, state: .timedOut)),
            size: CGSize(width: 402, height: 300))
        let reply = "Yes. The copy is final and approved by marketing. I'll post the PR link once CI is green."
        try snapshot(
            "snippet-ask-reply",
            siriCard(dialog: IntentCopy.agentSays(agent: "Saru", reply: reply), AskAgentSnippetView(agent: "Saru", question: question, state: .reply(reply))),
            size: CGSize(width: 402, height: 340))
    }

    // MARK: Interactive approvals widget and controls (task 01a10db6 stage 4)

    private func approvalsEntry(
        _ displays: [ApprovalsEntry.Display], extra: Int = 0, signedIn: Bool = true, minutesOld: Double = 2, installName: String? = nil
    ) -> ApprovalsEntry {
        let titles = [
            ("Burrow iOS intents plan", "Burrow iOS", "Add App Intents, entities and Spotlight"),
            ("Banner copy review", "Internal Fabrikam SXI", "Final wording for the launch banner"),
            ("Rotate the APNs key", "Infrastructure", "Move to the new team key before expiry"),
            ("Android share target", "Burrow Android", "Share sheet and Glance widgets"),
            ("Meeting notes export", "Meetings", "Export transcripts as Markdown"),
            ("Quota alerts", "Control", "Warn at 80 percent of the monthly budget"),
        ]
        let host = "suite.example.com"
        let all = displays + Array(repeating: ApprovalsEntry.Display.live, count: extra)
        let rows = all.enumerated().map { index, display in
            let t = titles[index % titles.count]
            let approval = SuiteApproval(
                id: "ap\(index)", kind: index == 1 ? "review" : "plan", title: t.0, spaceName: t.1, spacePathSegment: nil,
                taskID: "7a000000-0000-4000-8000-00000000000\(index)", insertedAt: nil, summary: t.2)
            return ApprovalsEntry.Row(id: "\(host)|ap\(index)", approval: approval, display: display)
        }
        return ApprovalsEntry(
            date: now, host: host, installName: installName, signedIn: signedIn,
            fetchedAt: signedIn ? now.addingTimeInterval(-minutesOld * 60) : nil, rows: signedIn ? rows : [])
    }

    func testApprovalsWidgetStates() throws {
        let states: [(String, ApprovalsEntry)] = [
            ("live", approvalsEntry([.live, .live], extra: 3)),
            ("confirming", approvalsEntry([.confirming, .live], extra: 3)),
            ("approving", approvalsEntry([.approving, .live], extra: 3)),
            ("approved", approvalsEntry([.approved, .live], extra: 3)),
            ("failed", approvalsEntry([.failed, .live], extra: 3)),
            ("already-handled", approvalsEntry([.alreadyHandled(by: "Rowan Ellis"), .live], extra: 3)),
            ("stale", approvalsEntry([.stale, .stale], extra: 0, minutesOld: 47)),
            ("zero", approvalsEntry([])),
            ("signed-out", approvalsEntry([], signedIn: false)),
            ("multi-install", approvalsEntry([.live, .live], extra: 1, installName: "Fabrikam Suite")),
        ]
        let sizes: [(String, WidgetFamily, CGSize)] = [
            ("medium", .systemMedium, CGSize(width: 364, height: 170)),
            ("large", .systemLarge, CGSize(width: 364, height: 382)),
            ("xl", .systemExtraLarge, CGSize(width: 716, height: 342)),
        ]
        for (sizeName, family, size) in sizes {
            for (stateName, entry) in states {
                try save(
                    "approvals-\(sizeName)-\(stateName)",
                    widgetFrame(ApprovalsWidgetView(entry: entry, family: family).frame(width: size.width, height: size.height)),
                    size: CGSize(width: size.width + 24, height: size.height + 24))
            }
        }
        try save(
            "approvals-medium-live-dark",
            widgetFrame(ApprovalsWidgetView(entry: states[0].1, family: .systemMedium).frame(width: 364, height: 170)),
            size: CGSize(width: 388, height: 194), dark: true)
        try save(
            "approvals-small-live",
            widgetFrame(ApprovalsWidgetView(entry: states[0].1, family: .systemSmall).frame(width: 170, height: 170)),
            size: CGSize(width: 194, height: 194))
    }

    /// Stand-in for the system's control tile: iOS draws the tile and its
    /// tint; Burrow supplies the symbol, label and value line.
    private func controlTile(_ copy: ControlCopy) -> some View {
        HStack(spacing: 12) {
            Image(systemName: copy.symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(0.25)))
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.label).font(.system(size: 15, weight: .semibold))
                if !copy.value.isEmpty { Text(copy.value).font(.system(size: 13)).opacity(0.8) }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(width: 220, height: 76)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.black.opacity(0.55)))
    }

    func testControls() throws {
        let copies: [(String, ControlCopy)] = [
            ("waiting-live", .waiting(signedIn: true, approvals: 3, install: nil)),
            ("waiting-zero", .waiting(signedIn: true, approvals: 0, install: nil)),
            ("waiting-signed-out", .waiting(signedIn: false, approvals: nil, install: nil)),
            ("waiting-multi-install", .waiting(signedIn: true, approvals: 2, install: "Fabrikam Suite")),
            ("start-meeting", .startMeeting(lastSpace: "Burrow iOS", install: nil)),
            ("start-meeting-first", .startMeeting(lastSpace: nil, install: nil)),
        ]
        for (name, copy) in copies {
            try save(
                "control-\(name)", controlTile(copy).padding(12).background(Color(white: 0.3)), size: CGSize(width: 244, height: 100), dark: true)
        }
    }
}
