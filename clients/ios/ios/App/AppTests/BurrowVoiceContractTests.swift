import XCTest

@testable import App

/// CONTRACT SOURCE SCAN, native side (task 01a20dc5). Reads the Voice tab's
/// web hook (apps/platform/assets/js/hooks/voice_tab.js) from the checkout
/// and asserts every plugin name, method and event it uses exists here, so a
/// rename on either side fails CI. Runs on a simulator, which reads the
/// host's files.
final class BurrowVoiceContractTests: XCTestCase {
    /// The repo root: this file is clients/ios/ios/App/AppTests/<file>.
    private static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()

    private var hook: String {
        get throws {
            try String(contentsOf: Self.root.appendingPathComponent("apps/platform/assets/js/hooks/voice_tab.js"), encoding: .utf8)
        }
    }

    private static let methods = ["capabilities", "prepare", "start", "stop", "cancel", "speak", "stopSpeaking", "openSettings"]

    /// The native half, always on: what the hook may call is registered, and
    /// each name is an Objective-C method Capacitor can dispatch to.
    func testEveryContractMethodIsRegistered() {
        let plugin = BurrowVoicePlugin()
        XCTAssertEqual(plugin.jsName, "BurrowVoice")
        let registered = Set(plugin.pluginMethods.map(\.name))
        for method in Self.methods {
            XCTAssertTrue(registered.contains(method), method)
            XCTAssertTrue(plugin.responds(to: NSSelectorFromString("\(method):")), "\(method): is not an @objc method")
        }
    }

    func testTheHookFileIsReadable() throws {
        XCTAssertTrue(try hook.contains("export"), "voice_tab.js is where the contract says")
    }

    /// The hook half: stage 3 adds the BurrowVoice bridge to voice_tab.js and
    /// removes this skip.
    func testTheHookUsesOnlyNamesThePluginDefines() throws {
        try XCTSkipIf(true, "task 01a20dc5 stage 3 adds the BurrowVoice bridge to voice_tab.js")
        let source = try hook
        XCTAssertTrue(source.contains("BurrowVoice"), "the hook reaches the plugin by its jsName")
        let registered = Set(BurrowVoicePlugin().pluginMethods.map(\.name))
        for method in Self.methods where source.contains(".\(method)(") {
            XCTAssertTrue(registered.contains(method), method)
        }
        for method in ["capabilities", "start", "stop", "cancel", "speak", "stopSpeaking"] {
            XCTAssertTrue(source.contains(".\(method)("), "the hook calls \(method)")
        }
        for event in BurrowVoicePlugin.events {
            XCTAssertTrue(source.contains("\"\(event)\""), "the hook listens for \(event)")
        }
    }
}
