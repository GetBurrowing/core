import XCTest

@testable import App

/// `burrow://open?host=&path=`: the path validator, the constructors App
/// Intents use, and the null-name space decode the share sheet depends on.
final class DeepLinkTests: XCTestCase {
    private let host = "suite.example.com"
    private let dmSegment = "019f7d30-4a54-7730-aecc-5df5caa400b9"
    private let taskID = "01A10DB6-DD0B-7001-94EB-C06DEBB66A4A"

    // MARK: Accept / reject tables

    func testAcceptedPaths() {
        let accepted = [
            "/",
            "/inbox",
            "/tasks",
            "/meetings",
            "/tasks/\(taskID)",
            "/tasks/\(taskID.lowercased())",
            "/chat/general",
            "/chat/internal-fabrikam_sxi",
            // A DM's path_segment is its bare UUID: DMs have no slug.
            "/chat/\(dmSegment)",
            "/meetings/standup-2026-10-05",
            "/chat/" + String(repeating: "a", count: DeepLink.maxSegmentLength),
        ]
        for path in accepted {
            XCTAssertTrue(DeepLink.isAllowed(path: path), "should accept \(path)")
            let link = DeepLink(url: DeepLink(host: host, path: path).url)
            XCTAssertEqual(link?.path, path, "should round-trip \(path)")
            XCTAssertEqual(link?.destination.absoluteString, "https://\(host)\(path)")
        }
    }

    func testRejectedPaths() {
        let rejected = [
            "",
            "inbox",
            "/admin",
            "/inbox/",
            "/tasks/",
            "/chat",
            "/chat/",
            "/chat/../admin",
            "/chat/..",
            "/chat/a.b",
            "//evil.example",
            "//evil.example/chat/x",
            "/chat/a%2Fb",
            "/chat/a%2fb",
            "/chat/a/b",
            "/chat//x",
            "/chat/x?y=1",
            "/chat/x#frag",
            "/chat/x y",
            "/chat/caf\u{E9}",
            "/chat/" + String(repeating: "a", count: DeepLink.maxSegmentLength + 1),
            "/tasks/not-a-uuid",
            "/tasks/\(taskID)x",
            "/tasks/0000000g-0000-0000-0000-000000000000",
            "/meetings/x/y",
            "/inbox?x=1",
            "https://evil.example/inbox",
            "/settings/agent-1",
        ]
        for path in rejected {
            XCTAssertFalse(DeepLink.isAllowed(path: path), "should reject \(path)")
            XCTAssertNil(DeepLink(url: DeepLink(host: host, path: path).url), "should refuse a link to \(path)")
        }
    }

    /// The decoded `path` query value is what is validated, so an encoded
    /// slash, query or traversal arriving in the raw URL is refused too.
    func testRawURLsWithSmuggledPartsAreRefused() {
        let raw = [
            "burrow://open?host=\(host)&path=/chat/a%2Fb",
            "burrow://open?host=\(host)&path=/chat/a%252Fb",
            "burrow://open?host=\(host)&path=/chat/x%3Fy=1",
            "burrow://open?host=\(host)&path=/chat/x%23y",
            "burrow://open?host=\(host)&path=/chat/%2E%2E/admin",
            "burrow://open?host=\(host)&path=%2F%2Fevil.example",
        ]
        for string in raw {
            XCTAssertNil(DeepLink(url: URL(string: string)!), string)
        }
        // Only `path` is read: a second query item is not appended to it.
        let extra = DeepLink(url: URL(string: "burrow://open?host=\(host)&path=/chat/x&y=1")!)
        XCTAssertEqual(extra?.path, "/chat/x")
        XCTAssertEqual(extra?.destination.absoluteString, "https://\(host)/chat/x")
    }

    // MARK: Constructors

    func testConstructorsBuildValidatedLinksForTheirOwnHost() throws {
        XCTAssertEqual(DeepLink.space(host: host, pathSegment: dmSegment)?.path, "/chat/\(dmSegment)")
        XCTAssertEqual(DeepLink.task(host: host, id: taskID)?.path, "/tasks/\(taskID)")
        XCTAssertEqual(
            DeepLink.meeting(host: "Suite.Milv.Life", slug: "standup")?.destination.absoluteString,
            "https://suite.milv.life/meetings/standup")

        // Each link carries the host it was built for, and nothing else.
        let a = DeepLink.space(host: "a.example.com", pathSegment: "general")
        let b = DeepLink.space(host: "b.example.com", pathSegment: "general")
        XCTAssertEqual(a?.host, "a.example.com")
        XCTAssertEqual(b?.host, "b.example.com")
        XCTAssertEqual(DeepLink(url: try XCTUnwrap(a).url)?.host, "a.example.com")

        XCTAssertNil(DeepLink.space(host: host, pathSegment: "../admin"))
        XCTAssertNil(DeepLink.space(host: host, pathSegment: "a/b"))
        XCTAssertNil(DeepLink.space(host: host, pathSegment: ""))
        XCTAssertNil(DeepLink.task(host: host, id: "42"))
        XCTAssertNil(DeepLink.meeting(host: host, slug: "x?y=1"))
    }

    // MARK: Spaces with no name

    func testSpaceWithNullNameDecodesWithFallback() throws {
        let json = Data(
            """
            {"spaces":[
              {"id":"d1","name":null,"slug":null,"kind":"dm","path_segment":"\(dmSegment)","agents":[]},
              {"id":"s1","name":"Internal Fabrikam SXI","slug":"sxi","kind":"channel","path_segment":"sxi",
               "agents":[{"id":"a1","name":"Saru","slug":"saru"}]},
              {"id":"d2","kind":"dm"}
            ]}
            """.utf8)
        struct Body: Decodable { let spaces: [SuiteSpace] }
        let spaces = try JSONDecoder().decode(Body.self, from: json).spaces

        XCTAssertEqual(spaces.map(\.name), ["Direct message", "Internal Fabrikam SXI", "Direct message"])
        XCTAssertEqual(spaces[0].pathSegment, dmSegment)
        XCTAssertNil(spaces[0].slug)
        XCTAssertEqual(spaces[1].agents.map(\.name), ["Saru"])
        XCTAssertEqual(spaces[2].agents, [])
        XCTAssertNotNil(DeepLink.space(host: host, pathSegment: try XCTUnwrap(spaces[0].pathSegment)))
    }
}
