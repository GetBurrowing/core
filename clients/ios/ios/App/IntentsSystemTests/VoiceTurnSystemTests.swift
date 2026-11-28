import AppIntentsTesting
import XCTest

/// Task 01a21e75 stage 5: StartVoiceTurnIntent run out of process against
/// the installed Burrow, with the app in the background (see
/// MessagesDomainSystemTests for how to run).
///
/// What AppIntentsTesting can and cannot say here: it runs the intent and
/// XCUIApplication reports whether Burrow came to the foreground. It has no
/// API for another process's Live Activities (`Activity.activities` answers
/// only inside the app that requested them), so "an Activity exists" is NOT
/// asserted here; VoiceTurnRunnerTests covers the request through its seam,
/// and only a device shows the activity itself.
///
/// Which process ran `perform` (task 01a21e75 stage 7): a Debug perform
/// writes `step=voice.perform process=app|extension hook=…` (ids and kinds
/// only) to `Library/Caches/intent-trace.log` in the container of the
/// process that ran it. On the simulator that container is a sibling of
/// this runner's own, so the test reads Burrow's file and asserts a NEW
/// line says `process=app`.
@available(iOS 27.0, *)
final class VoiceTurnSystemTests: XCTestCase {
    let definitions = IntentDefinitions(bundleIdentifier: "com.kobo-ai.burrow")

    func testStartVoiceTurnRunsInTheAppProcessWithoutForegroundingIt() async throws {
        let app = await MainActor.run { XCUIApplication() }
        await MainActor.run {
            app.launch()
            XCUIDevice.shared.press(.home)
        }
        _ = await MainActor.run { app.wait(for: .runningBackground, timeout: 10) }
        let trace = try XCTUnwrap(Self.burrowCachesFile("intent-trace.log"), "Burrow's data container was not found beside the runner's")
        let before = Self.performLines(trace).count

        _ = try await definitions.intents["StartVoiceTurnIntent"].makeIntent().run()

        let state = await MainActor.run { app.state }
        print("system-test StartVoiceTurnIntent app_state=\(state.rawValue)")
        XCTAssertNotEqual(state, .runningForeground, "the intent brought Burrow to the foreground")

        let new = Array(Self.performLines(trace).dropFirst(before))
        print("system-test StartVoiceTurnIntent perform_lines=\(new.count) \(new.map { $0.components(separatedBy: "step=").last ?? "" })")
        XCTAssertEqual(new.count, 1, "exactly one perform was traced")
        XCTAssertTrue(new.allSatisfy { $0.contains("step=voice.perform process=app hook=true") }, "perform ran outside the app process")
    }

    /// The `step=voice.perform` lines of `url`, oldest first.
    private static func performLines(_ url: URL) -> [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init).filter { $0.contains("step=voice.perform ") }
    }

    /// `Library/Caches/<name>` in Burrow's own data container, found by its
    /// container metadata among this runner's sibling containers.
    private static func burrowCachesFile(_ name: String) -> URL? {
        let siblings = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let containers = (try? FileManager.default.contentsOfDirectory(at: siblings, includingPropertiesForKeys: nil)) ?? []
        for container in containers {
            let metadata = container.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard let plist = NSDictionary(contentsOf: metadata), plist["MCMMetadataIdentifier"] as? String == "com.kobo-ai.burrow" else { continue }
            return container.appendingPathComponent("Library/Caches").appendingPathComponent(name)
        }
        return nil
    }
}
