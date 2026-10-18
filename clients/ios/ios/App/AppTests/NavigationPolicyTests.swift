import XCTest
@testable import App

final class NavigationPolicyTests: XCTestCase {
    private let policy = NavigationPolicy(installHost: "suite.example.net")

    func testInstallHostStaysInTheView() {
        XCTAssertEqual(policy.decide(url: URL(string: "https://suite.example.net/chat/abc"), isMainFrame: true), .allow)
        XCTAssertEqual(policy.decide(url: URL(string: "https://SUITE.example.net/inbox"), isMainFrame: true), .allow)
    }

    func testForeignHostOpensInSafari() {
        XCTAssertEqual(policy.decide(url: URL(string: "https://github.com/Startup-Suite/core"), isMainFrame: true), .openExternally)
        // A look-alike suffix is a different host.
        XCTAssertEqual(policy.decide(url: URL(string: "https://suite.example.net.evil.example/"), isMainFrame: true), .openExternally)
        // Another install is a different host too: switching goes through the picker.
        XCTAssertEqual(policy.decide(url: URL(string: "https://suite.example.org/chat"), isMainFrame: true), .openExternally)
    }

    func testForeignSubframeIsPartOfThePage() {
        XCTAssertEqual(policy.decide(url: URL(string: "https://www.youtube.com/embed/x"), isMainFrame: false), .allow)
    }

    func testNonWebSchemesLeaveTheApp() {
        XCTAssertEqual(policy.decide(url: URL(string: "mailto:a@example.com"), isMainFrame: true), .openExternally)
        XCTAssertEqual(policy.decide(url: URL(string: "about:blank"), isMainFrame: true), .allow)
    }

    func testWebLoginIsTakenOverByTheNativeFlow() {
        XCTAssertEqual(policy.decide(url: URL(string: "https://suite.example.net/auth/login"), isMainFrame: true), .startNativeLogin)
        XCTAssertEqual(policy.decide(url: URL(string: "https://suite.example.net/auth/login?app_challenge=x"), isMainFrame: true), .allow)
    }

    func testPullToRefreshIsOffInChat() {
        XCTAssertFalse(NavigationPolicy.allowsPullToRefresh(path: "/chat"))
        XCTAssertFalse(NavigationPolicy.allowsPullToRefresh(path: "/chat/0198-abc"))
        XCTAssertTrue(NavigationPolicy.allowsPullToRefresh(path: "/inbox"))
        XCTAssertTrue(NavigationPolicy.allowsPullToRefresh(path: "/chatter"))
    }
}
