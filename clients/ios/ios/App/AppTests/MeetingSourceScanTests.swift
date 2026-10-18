import XCTest

/// Guards for the native meetings code (task 01a10db7 stage 3):
///
///   * no log call under `App/Meetings` (or the meetings plugin) may
///     interpolate anything token-shaped: the LiveKit JWT and the app
///     bearer travel through this code;
///   * LiveKit is linked into the App target ONLY. `../Intents` and
///     `../Shared` compile into the widgets and the share extension, so no
///     file there may import LiveKit, and project.yml may not give either
///     extension the package.
final class MeetingSourceScanTests: XCTestCase {
    private static let logCall = try! NSRegularExpression(
        pattern: #"(\bLogger\s*\(|\blog\.\w+\s*\(|\blogger\.\w+\s*\(|\bos_log\s*\(|\bprint\s*\(|\bdebugPrint\s*\(|\bNSLog\s*\()"#)
    private static let interpolation = try! NSRegularExpression(pattern: #"\\\(([^)]*)\)"#)
    /// `hex`: the PushKit VoIP credential is hex-encoded before it is sent
    /// (stage 5), so a log of any `hex…` value is a log of it.
    private static let forbidden = ["token", "credential", "jwt", "bearer", "join)", "hex"]

    static func violations(in line: String) -> [String] {
        let range = NSRange(line.startIndex..., in: line)
        guard logCall.firstMatch(in: line, range: range) != nil else { return [] }
        return interpolation.matches(in: line, range: range).compactMap { match in
            guard let inner = Range(match.range(at: 1), in: line) else { return nil }
            let expression = line[inner].lowercased()
            return forbidden.contains { expression.contains($0) } ? String(line[inner]) : nil
        }
    }

    /// .../clients/ios/ios/App
    private var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func swiftFiles(_ relative: String) throws -> [URL] {
        let dir = appRoot.appendingPathComponent(relative)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no Swift files in \(dir.path)")
        return files
    }

    func testTheScannerCatchesATokenInALogLine() {
        XCTAssertEqual(Self.violations(in: #"Self.log.info("joined \(join.token)")"#), ["join.token"])
        XCTAssertEqual(Self.violations(in: #"print("connect \(credential)")"#), ["credential"])
        XCTAssertEqual(Self.violations(in: #"Self.log.info("room=\(roomName) remote=\(count)")"#), [])
        XCTAssertEqual(Self.violations(in: #"let x = "\(join.token)""#), [], "not a log call")
    }

    func testTheScannerCatchesAVoIPCredentialInALogLine() {
        XCTAssertEqual(Self.violations(in: #"Self.log.info("voip \(pushCredentials.token)")"#), ["pushCredentials.token"])
        XCTAssertEqual(Self.violations(in: #"Self.log.info("voip \(hexCredential ?? "")")"#), [#"hexCredential ?? """#])
        XCTAssertEqual(Self.violations(in: #"Self.log.info("registered host=\(host, privacy: .public)")"#), [])
    }

    /// The PushKit code is in the scanned directory, and the credential goes
    /// to exactly one place: the `/api/app/voip_devices` body.
    func testTheVoIPCredentialOnlyTravelsToVoIPDevices() throws {
        let files = try swiftFiles("App/Meetings").map(\.lastPathComponent)
        XCTAssertTrue(files.contains("VoIPRegistrar.swift"), "the scan covers the pushRegistry code: \(files)")
        let source = try String(contentsOf: appRoot.appendingPathComponent("App/Meetings/VoIPRegistrar.swift"), encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "pushCredentials.token").count - 1, 1, "read once, to hex it")
        XCTAssertEqual(source.components(separatedBy: "\"token\": hex").count - 1, 1, "sent in one body")
        XCTAssertTrue(source.contains(#"static let voipDevicesPath = "/api/app/voip_devices""#))
        XCTAssertFalse(source.contains(".set("), "the credential is never persisted")
    }

    func testNoMeetingsLogLineInterpolatesAToken() throws {
        let files = try swiftFiles("App/Meetings") + [appRoot.appendingPathComponent("App/Plugins/BurrowMeetingsPlugin.swift")]
        var logLines = 0
        var offences: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for (n, line) in lines.enumerated() {
                if Self.logCall.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { logLines += 1 }
                offences += Self.violations(in: line).map { "\(file.lastPathComponent):\(n + 1) interpolates \($0)" }
            }
        }
        XCTAssertGreaterThan(logLines, 0, "the scan found no log calls; is it reading the sources?")
        XCTAssertEqual(offences, [])
    }

    func testSharedAndIntentsCodeNeverImportsLiveKit() throws {
        let root = appRoot.deletingLastPathComponent()
        var offences: [String] = []
        for dir in ["Intents", "Shared"] {
            let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
            XCTAssertFalse(files.isEmpty)
            for file in files {
                let imports = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
                    .contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("import LiveKit") }
                if imports { offences.append("\(dir)/\(file.lastPathComponent)") }
            }
        }
        XCTAssertEqual(offences, [], "these compile into the widgets / share extension")
    }

    /// Reads project.yml's target blocks: only `App` may depend on the
    /// LiveKit package.
    /// The meeting trace file (task 01a13c62 stage 1) holds constants,
    /// booleans and counts only: no token, name, identity or room name.
    func testNoMeetingTraceLineInterpolatesAnIdentityOrName() throws {
        let call = try NSRegularExpression(pattern: #"MeetingTrace\.append\s*\("#)
        let banned = ["token", "identity", "name", "join", "room)", "metadata", "sid", "host"]
        var traceLines = 0
        var offences: [String] = []
        for file in try swiftFiles("App/Meetings") {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for (n, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard call.firstMatch(in: line, range: range) != nil else { continue }
                traceLines += 1
                for match in Self.interpolation.matches(in: line, range: range) {
                    guard let inner = Range(match.range(at: 1), in: line) else { continue }
                    let expression = line[inner].lowercased()
                    if banned.contains(where: { expression.contains($0) }) {
                        offences.append("\(file.lastPathComponent):\(n + 1) traces \(line[inner])")
                    }
                }
            }
        }
        XCTAssertGreaterThan(traceLines, 5, "the scan found no trace calls; is it reading the sources?")
        XCTAssertEqual(offences, [])
    }

    func testOnlyTheAppTargetLinksLiveKit() throws {
        let yml = try String(contentsOf: appRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let targets = Self.targetBlocks(yml)
        XCTAssertTrue(targets.keys.contains("BurrowWidgets") && targets.keys.contains("ShareExtension"), "parsed: \(targets.keys.sorted())")
        let linking = targets.filter { $0.value.contains("package: LiveKit") }.map(\.key).sorted()
        XCTAssertEqual(linking, ["App"])
    }

    /// `targets:` children at two-space indent, each with its body.
    static func targetBlocks(_ yml: String) -> [String: String] {
        var blocks: [String: String] = [:]
        var inTargets = false
        var current: String?
        for line in yml.components(separatedBy: .newlines) {
            if line.hasPrefix("targets:") {
                inTargets = true
                continue
            }
            guard inTargets else { continue }
            if !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("#") { break }
            if line.hasPrefix("  "), !line.hasPrefix("   "), line.hasSuffix(":"), !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                current = line.trimmingCharacters(in: .whitespaces).dropLast().description
                blocks[current!] = ""
            } else if let current {
                blocks[current, default: ""] += line + "\n"
            }
        }
        return blocks
    }
}
