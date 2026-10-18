import CryptoKit
import XCTest

@testable import App

/// Fails if any log call in `Intents/` or `Shared/` interpolates something
/// that could carry a bearer, a message, an ask-an-agent question or reply,
/// or approval content. Logs may name routes, statuses, counts and hosts.
final class IntentSourceScanTests: XCTestCase {
    static let forbidden = ["token", "text", "content", "message", "feedback", "question", "reply", "title"]

    /// A log call: `Logger(...)`, `logger.<level>(`, `os_log(`, `print(`,
    /// `debugPrint(`, `NSLog(`.
    private static let logCall = try! NSRegularExpression(
        pattern: #"(\bLogger\s*\(|\blogger\.\w+\s*\(|\bos_log\s*\(|\bprint\s*\(|\bdebugPrint\s*\(|\bNSLog\s*\()"#)
    private static let interpolation = try! NSRegularExpression(pattern: #"\\\(([^)]*)\)"#)

    /// The offending interpolations in one source line, if it is a log call.
    static func violations(in line: String) -> [String] {
        let range = NSRange(line.startIndex..., in: line)
        guard logCall.firstMatch(in: line, range: range) != nil else { return [] }
        return interpolation.matches(in: line, range: range).compactMap { match in
            guard let inner = Range(match.range(at: 1), in: line) else { return nil }
            let expression = line[inner].lowercased()
            return forbidden.contains { expression.contains($0) } ? String(line[inner]) : nil
        }
    }

    private var iosRoot: URL {
        // .../clients/ios/ios/App/AppTests/IntentSourceScanTests.swift
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testTheScannerCatchesAForbiddenInterpolation() {
        XCTAssertEqual(Self.violations(in: #"logger.info("sent \(message.text, privacy: .public)")"#), ["message.text, privacy: .public"])
        XCTAssertEqual(Self.violations(in: #"print("bearer \(token)")"#), ["token"])
        XCTAssertEqual(Self.violations(in: #"os_log("%@", "\(approval.title)")"#), ["approval.title"])
        XCTAssertEqual(Self.violations(in: #"logger.info("route=\(name) status=\(status)")"#), [])
        XCTAssertEqual(Self.violations(in: #"let line = "Sent to \(space.title)""#), [], "not a log call")
    }

    func testNoLogLineInIntentsOrSharedInterpolatesContent() throws {
        var scannedLogLines = 0
        var offences: [String] = []
        for directory in ["Intents", "Shared", "NotificationService"] {
            let dir = iosRoot.appendingPathComponent(directory)
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
            XCTAssertFalse(files.isEmpty, "no Swift files found in \(dir.path)")
            for file in files {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
                for (number, line) in lines.enumerated() {
                    let range = NSRange(line.startIndex..., in: line)
                    if Self.logCall.firstMatch(in: line, range: range) != nil { scannedLogLines += 1 }
                    for bad in Self.violations(in: line) {
                        offences.append("\(directory)/\(file.lastPathComponent):\(number + 1) interpolates \(bad)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(scannedLogLines, 0, "the scan found no log calls at all; is it reading the sources?")
        XCTAssertEqual(offences, [])
    }

    /// The Notification Service Extension (task 01a111bb stage 4) makes no
    /// network request and logs nothing, so it can never log a title or body.
    func testTheNotificationServiceNeitherFetchesNorLogs() throws {
        let files = ["NotificationService/NotificationService.swift", "Intents/CommunicationNotification.swift"]
        let banned = ["URLSession", "URLRequest", "SuiteAPIClient", "Logger(", "os_log", "print(", "NSLog", "IntentLog"]
        for path in files {
            let source = try String(contentsOf: iosRoot.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains("UNNotification"), "\(path) was not read")
            for word in banned { XCTAssertFalse(source.contains(word), "\(path) uses \(word)") }
        }
    }

    /// Main donated every intent run whole (message text and questions
    /// included). The only call into the system's donation store is now the
    /// live DonationManaging, behind DonationPolicy's content check.
    func testOnlyTheDonationManagerDonates() throws {
        var callers: [String] = []
        for directory in ["Intents", "Shared", "App/App", "App/App/Intents", "App/App/Plugins", "App/App/Meetings", "NotificationService"] {
            let dir = iosRoot.appendingPathComponent(directory)
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
            for file in files where try String(contentsOf: file, encoding: .utf8).contains("IntentDonationManager.shared.donate(") {
                callers.append("\(directory)/\(file.lastPathComponent)")
            }
        }
        XCTAssertEqual(callers, ["Intents/DonationPolicy.swift"])
    }
}

/// Fails if shipped app code or config names a personal install host
/// (task 01a12787). The app ships no install list: a fresh install starts
/// empty. Test code is not scanned, since it does not ship.
///
/// The hosts are matched by sha256 digest, the rule core's install-identity
/// guard uses (apps/platform/test/support/install_identity_scanner.ex), so
/// this file does not spell them (task 01a14b9e stage 5). A line is
/// tokenised: every `[a-z0-9]+([.-][a-z0-9]+)+` run of the lowercased line
/// and each of its dot-suffixes is a host candidate, and every `[a-z0-9]+`
/// run is a name candidate. The bundle id is the app's identity, not an
/// install: none of its candidates hashes to a listed host.
///
/// Lives here rather than in its own file so it needs no project file edit
/// while PR #1219 also edits the project.
final class ShippedHostScanTests: XCTestCase {
    /// sha256 of the personal install hosts (three domains and one org name).
    static let personalHostDigests: Set<String> = [
        "5dea22a579e9477122312d9f7269eabfa8147527a8d24738683f6b6734487560",
        "b29a46a27acbba77b0aaba113e3d343cbd951a3a848f8356c164c3728b1c8e05",
        "b185c3068c145f728a1aab6f00091fb6735ddf72311b368f592cb7b0a2a5f37c",
        "44506f784f8d79f5c01259f925b02d157fc5703fa334313d7575d43f308c9a36",
    ]
    static let compound = try! NSRegularExpression(pattern: #"[a-z0-9]+(?:[.\-][a-z0-9]+)+"#)
    static let token = try! NSRegularExpression(pattern: #"[a-z0-9]+"#)

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Host candidates (each compound and its dot-suffixes) and name
    /// candidates (each token) of one line, lowercased.
    static func candidates(_ line: String) -> [String] {
        let low = line.lowercased()
        let range = NSRange(low.startIndex..., in: low)
        var out: [String] = []
        for match in compound.matches(in: low, range: range) {
            guard let r = Range(match.range, in: low) else { continue }
            let word = String(low[r])
            out.append(word)
            for index in word.indices where word[index] == "." {
                out.append(String(word[word.index(after: index)...]))
            }
        }
        for match in token.matches(in: low, range: range) {
            if let r = Range(match.range, in: low) { out.append(String(low[r])) }
        }
        return out
    }

    static func namesHost(_ line: String, digests: Set<String>) -> Bool {
        candidates(line).contains { digests.contains(sha256($0)) }
    }

    static func namesPersonalHost(_ line: String) -> Bool {
        namesHost(line, digests: personalHostDigests)
    }
    /// The only example hosts shipped code may name: the add-install
    /// placeholder and the widget gallery previews use it.
    static let allowedHosts: Set<String> = ["yourteam.example.com"]
    static let exampleHost = try! NSRegularExpression(pattern: #"[a-z0-9-]+(\.[a-z0-9-]+)*\.example\.(com|org|net)"#)

    private var iosRoot: URL {
        // .../clients/ios/ios/App/AppTests/IntentSourceScanTests.swift
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every shipped source and config file: the app, the shared code, the
    /// extensions, every Info.plist and entitlements file, and the
    /// Capacitor config.
    private func shippedFiles() throws -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        let directories = ["App/App", "Shared", "Intents", "ShareExtension", "SuiteWidgets", "NotificationService"]
        for directory in directories {
            let root = iosRoot.appendingPathComponent(directory)
            XCTAssertTrue(fm.fileExists(atPath: root.path), "missing \(root.path)")
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where ["swift", "plist", "entitlements", "json", "strings", "m", "h"].contains(url.pathExtension) {
                files.append(url)
            }
        }
        // Info.plist / .entitlements anywhere under the iOS project, wherever
        // a target keeps them, outside the build products and the tests.
        if let walker = fm.enumerator(at: iosRoot, includingPropertiesForKeys: nil) {
            for case let url as URL in walker
            where (url.lastPathComponent == "Info.plist" || url.pathExtension == "entitlements")
                && !url.path.contains("/build/") && !url.path.contains("Tests/")
            {
                files.append(url)
            }
        }
        files.append(iosRoot.deletingLastPathComponent().appendingPathComponent("capacitor.config.ts"))
        return Array(Set(files.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
    }

    static func matches(_ digests: Set<String>, in files: [URL]) throws -> [String] {
        var hits: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for (number, line) in lines.enumerated() where namesHost(line, digests: digests) {
                hits.append("\(file.lastPathComponent):\(number + 1)")
            }
        }
        return hits
    }

    /// Positive control: the same walk and scanner find a string that IS in
    /// a shipped file, so an empty result below is a real absence.
    func testTheScannerFindsAKnownShippedString() throws {
        let files = try shippedFiles()
        XCTAssertTrue(files.contains { $0.path.hasSuffix("Shared/InstallStore.swift") }, "the walk misses InstallStore.swift")
        XCTAssertTrue(files.contains { $0.lastPathComponent == "capacitor.config.ts" }, "the walk misses capacitor.config.ts")
        XCTAssertTrue(files.contains { $0.pathExtension == "entitlements" }, "the walk finds no entitlements")
        XCTAssertTrue(try Self.matches([Self.sha256("manifest.json")], in: files).contains { $0.hasPrefix("InstallStore.swift:") })
        // The matcher names a real personal host: the org's own domain,
        // built from project.yml's bundleIdPrefix so this file does not spell
        // it, and hidden inside a URL as shipped code would carry it.
        let project = try String(contentsOf: iosRoot.appendingPathComponent("App/project.yml"), encoding: .utf8)
        let prefix = try XCTUnwrap(project.components(separatedBy: .newlines).first { $0.contains("bundleIdPrefix:") })
        let org = try XCTUnwrap(prefix.components(separatedBy: ".").last)
        XCTAssertTrue(Self.namesPersonalHost("let url = \"https://chat.\(org).com/x\""))
        XCTAssertFalse(Self.namesPersonalHost("let url = \"https://chat.\(org).org/x\""))
    }

    func testNoShippedFileNamesAPersonalInstallHost() throws {
        XCTAssertEqual(try Self.matches(Self.personalHostDigests, in: shippedFiles()), [])
    }

    /// Every example host in shipped code is on the allow-list, and the
    /// allow-list never matches the deny-list.
    func testShippedExampleHostsAreAllowListed() throws {
        var found: Set<String> = []
        for file in try shippedFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in Self.exampleHost.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range, in: text) { found.insert(String(text[range])) }
            }
        }
        XCTAssertTrue(found.contains(AddInstallCopy.placeholder), "the scan did not see the placeholder")
        XCTAssertEqual(found.subtracting(Self.allowedHosts), [])
        for host in Self.allowedHosts {
            XCTAssertFalse(Self.namesPersonalHost(host), host)
        }
    }
}
