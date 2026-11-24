import XCTest

@testable import App

/// CONTRACT SOURCE SCAN, native side (task 01a20dc5). Reads the Voice tab's
/// web hook (apps/platform/assets/js/hooks/voice_tab.js and
/// voice_tab_native_runtime.js) from the checkout
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

    /// The hook is two files: voice_tab.js (in the web app bundle) and its
    /// on-device half, voice_tab_native_runtime.js (a separately loaded
    /// bundle). The scan reads both.
    private var hook: String {
        get throws {
            try ["voice_tab.js", "voice_tab_native_runtime.js"]
                .map {
                    try String(
                        contentsOf: Self.root.appendingPathComponent("apps/platform/assets/js/hooks/\($0)"), encoding: .utf8)
                }
                .joined(separator: "\n")
        }
    }

    private static let methods = [
        "capabilities", "prepare", "start", "stop", "cancel", "speak", "stopSpeaking", "openSettings", "voices",
    ]

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

    private var lib: String {
        get throws {
            try String(contentsOf: Self.root.appendingPathComponent("apps/platform/assets/js/lib/on_device_voice.js"), encoding: .utf8)
        }
    }

    private static func matches(_ pattern: String, in source: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return Set(
            regex.matches(in: source, range: range).compactMap { match in
                Range(match.range(at: 1), in: source).map { String(source[$0]) }
            })
    }

    /// The hook half (task 01a20dc5 stage 3): the web reaches the plugin by
    /// its jsName, and every method it calls and every event it listens for
    /// is one this plugin declares.
    func testTheHookUsesOnlyNamesThePluginDefines() throws {
        let hookSource = try hook
        let libSource = try lib
        XCTAssertTrue(libSource.contains("cap.Plugins && cap.Plugins.BurrowVoice"), "the web reaches the plugin by its jsName")

        let used = Self.matches(#"\bplugin\.(\w+)\("#, in: hookSource + libSource)
            .union(Self.matches(#"this\._native\.(\w+)\("#, in: hookSource))
            .union(Self.matches(#"_nativeCall\("(\w+)""#, in: hookSource))
            .subtracting(["addListener"])
        let registered = Set(BurrowVoicePlugin().pluginMethods.map(\.name))
        XCTAssertTrue(used.isSuperset(of: Set(Self.methods)), "the scan found every method: \(used.sorted())")
        for method in used {
            XCTAssertTrue(registered.contains(method), "the hook calls \(method), which the plugin does not register")
        }

        let events = Self.matches(#"\bon\("(\w+)""#, in: hookSource)
        XCTAssertTrue(events.isSuperset(of: ["partial", "ended", "speech", "route"]), "\(events.sorted())")
        for event in events {
            XCTAssertTrue(BurrowVoicePlugin.events.contains(event), "the hook listens for \(event), which the plugin never sends")
        }
    }
}
