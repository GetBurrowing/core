import XCTest

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
        for directory in ["Intents", "Shared"] {
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
}
