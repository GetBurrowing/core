import XCTest

@testable import App

final class ThemeTests: XCTestCase {
    func testEveryColourSlotHasANamedAsset() {
        for slot in BurrowColor.allCases {
            XCTAssertNotNil(
                UIColor(named: slot.rawValue, in: Bundle(for: BurrowBridgeViewController.self), compatibleWith: nil),
                "missing colour asset \(slot.rawValue)")
        }
    }

    func testPublicSansIsBundled() {
        XCTAssertTrue(UIFont.familyNames.contains("Public Sans"))
    }

    // MARK: No colour literal in the meetings code (task 01a10db7 stage 4)

    private static let systemColours =
        "red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|white|black|gray|grey|clear|primary|secondary|accentColor|label|systemBackground"
    private static let literal = try! NSRegularExpression(
        pattern: [
            #"\bColor\s*\("#,
            #"\bUIColor\s*\("#,
            #"\bColor\.\w+"#,
            #"\bUIColor\.\w+"#,
            #"#colorLiteral"#,
            #"\bCGColor\b"#,
            // `.tint(.red)`, `.fill(.white)`, `cond ? .black : ...`
            #"(\(|\?|:|,)\s*\.(\#(systemColours))\b"#,
        ].joined(separator: "|"))

    /// The literal-colour hits on one source line; comments are not code.
    static func literalColours(in line: String) -> [String] {
        let code = line.components(separatedBy: "//").first ?? ""
        let range = NSRange(code.startIndex..., in: code)
        return literal.matches(in: code, range: range).compactMap { Range($0.range, in: code).map { String(code[$0]) } }
    }

    func testTheScannerCatchesLiteralColours() {
        XCTAssertFalse(Self.literalColours(in: #"Circle().stroke(Color(red: 0, green: 0.8, blue: 0.9))"#).isEmpty)
        XCTAssertFalse(Self.literalColours(in: #".foregroundStyle(.white)"#).isEmpty)
        XCTAssertFalse(Self.literalColours(in: #".foregroundStyle(muted ? .gray : BurrowColor.onSurface.color)"#).isEmpty)
        XCTAssertFalse(Self.literalColours(in: #"view.backgroundColor = UIColor.black"#).isEmpty)
        XCTAssertFalse(Self.literalColours(in: #".tint(Color.cyan)"#).isEmpty)
        XCTAssertEqual(Self.literalColours(in: #".foregroundStyle(BurrowColor.info.color)"#), [])
        XCTAssertEqual(Self.literalColours(in: #".fill((inverted ? BurrowColor.onSurface : .surfaceMuted).color)"#), [])
        XCTAssertEqual(Self.literalColours(in: #"/// iOS `primary` is orange; Color(red:) is banned"#), [])
    }

    /// Every colour under App/Meetings comes through a `BurrowColor` slot.
    func testMeetingsCodeHasNoLiteralColour() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Meetings")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertTrue(files.contains { $0.lastPathComponent == "InCallView.swift" }, "is the scan reading the sources?")
        var slotUses = 0
        var offences: [String] = []
        for file in files {
            for (n, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines).enumerated() {
                slotUses += line.components(separatedBy: "BurrowColor.").count - 1
                offences += Self.literalColours(in: line).map { "\(file.lastPathComponent):\(n + 1) \($0)" }
            }
        }
        XCTAssertGreaterThan(slotUses, 10, "the screen draws through BurrowColor slots")
        XCTAssertEqual(offences, [])
    }
}
