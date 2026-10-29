import XCTest
@testable import App

final class NavigationPolicyTests: XCTestCase {
    private let policy = NavigationPolicy(installHost: "burrow.example.net")

    func testInstallHostStaysInTheView() {
        XCTAssertEqual(policy.decide(url: URL(string: "https://burrow.example.net/chat/abc"), isMainFrame: true), .allow)
        XCTAssertEqual(policy.decide(url: URL(string: "https://BURROW.example.net/inbox"), isMainFrame: true), .allow)
    }

    func testForeignHostOpensInSafari() {
        XCTAssertEqual(policy.decide(url: URL(string: "https://github.com/Startup-Suite/core"), isMainFrame: true), .openExternally)
        // A look-alike suffix is a different host.
        XCTAssertEqual(policy.decide(url: URL(string: "https://burrow.example.net.evil.example/"), isMainFrame: true), .openExternally)
        // Another install is a different host too: switching goes through the picker.
        XCTAssertEqual(policy.decide(url: URL(string: "https://burrow.example.org/chat"), isMainFrame: true), .openExternally)
    }

    func testForeignSubframeIsPartOfThePage() {
        XCTAssertEqual(policy.decide(url: URL(string: "https://www.youtube.com/embed/x"), isMainFrame: false), .allow)
    }

    func testNonWebSchemesLeaveTheApp() {
        XCTAssertEqual(policy.decide(url: URL(string: "mailto:a@example.com"), isMainFrame: true), .openExternally)
        XCTAssertEqual(policy.decide(url: URL(string: "about:blank"), isMainFrame: true), .allow)
    }

    func testWebLoginIsTakenOverByTheNativeFlow() {
        XCTAssertEqual(policy.decide(url: URL(string: "https://burrow.example.net/auth/login"), isMainFrame: true), .startNativeLogin)
        XCTAssertEqual(policy.decide(url: URL(string: "https://burrow.example.net/auth/login?app_challenge=x"), isMainFrame: true), .allow)
    }

    func testNewWindowOnInstallLoadsInMainView() {
        XCTAssertEqual(policy.decide(url: URL(string: "https://BURROW.example.net/tasks/abc"), isMainFrame: false, isNewWindow: true), .loadInMainView)
    }

    func testForeignNewWindowOpensExternally() {
        XCTAssertEqual(policy.decide(url: URL(string: "https://outside.example/tasks/abc"), isMainFrame: false, isNewWindow: true), .openExternally)
        XCTAssertEqual(policy.decide(url: URL(string: "https://burrow.example.net.evil.example/"), isMainFrame: false, isNewWindow: true), .openExternally)
    }

    func testNewWindowKeepsNativeAuthenticationPolicy() {
        XCTAssertEqual(policy.decide(url: URL(string: "https://burrow.example.net/auth/login"), isMainFrame: false, isNewWindow: true), .startNativeLogin)
        XCTAssertEqual(policy.decide(url: URL(string: "https://burrow.example.net/auth/logout"), isMainFrame: false, isNewWindow: true), .signOut)
        XCTAssertEqual(policy.decide(url: URL(string: "https://burrow.example.net/auth/login?app_challenge=x"), isMainFrame: false, isNewWindow: true), .loadInMainView)
    }

    func testPullToRefreshIsOffInChat() {
        XCTAssertFalse(NavigationPolicy.allowsPullToRefresh(path: "/chat"))
        XCTAssertFalse(NavigationPolicy.allowsPullToRefresh(path: "/chat/0198-abc"))
        XCTAssertTrue(NavigationPolicy.allowsPullToRefresh(path: "/inbox"))
        XCTAssertTrue(NavigationPolicy.allowsPullToRefresh(path: "/chatter"))
    }
}
