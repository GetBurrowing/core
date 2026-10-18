import XCTest
@testable import App

/// An intent that joins a meeting starts a native call in the app and keeps
/// opening the web page where no launcher is installed (the widget process).
final class MeetingLauncherTests: XCTestCase {
    private var savedStart: ((String, String) -> Void)?
    private var savedHandler: ((DeepLink) -> Void)?
    private var defaultsName = ""

    override func setUp() {
        super.setUp()
        savedStart = MeetingLauncher.start
        savedHandler = IntentNavigator.handler
        defaultsName = "MeetingLauncherTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        MeetingLauncher.start = savedStart
        IntentNavigator.handler = savedHandler
        UserDefaults().removePersistentDomain(forName: defaultsName)
        super.tearDown()
    }

    private var installs: InstallStore { InstallStore(defaults: UserDefaults(suiteName: defaultsName)!) }
    private let link = DeepLink.meeting(host: "burrow.example.com", slug: "design-review")!

    func testWithoutALauncherTheDeepLinkOpens() {
        MeetingLauncher.start = nil
        var opened: [DeepLink] = []
        IntentNavigator.handler = { opened.append($0) }

        let route = MeetingLauncher.open(host: "burrow.example.com", meetingID: "m1", fallback: link, installs: installs)

        XCTAssertEqual(route, .web(link))
        XCTAssertEqual(opened, [link])
    }

    func testWithALauncherTheCallIsNativeAndNoPageOpens() {
        var started: [String] = []
        MeetingLauncher.start = { host, id in started.append("\(host)|\(id)") }
        var opened: [DeepLink] = []
        IntentNavigator.handler = { opened.append($0) }

        let route = MeetingLauncher.open(host: "burrow.example.com", meetingID: "m1", fallback: link, installs: installs)

        XCTAssertEqual(route, .native)
        XCTAssertEqual(started, ["burrow.example.com|m1"])
        XCTAssertEqual(opened, [], "a native join must not also open the web meeting page")
    }

    func testTheAppInstallsTheLauncher() {
        MeetingLauncher.start = nil
        IntentAppHooks.install()
        XCTAssertNotNil(MeetingLauncher.start)
    }
}
