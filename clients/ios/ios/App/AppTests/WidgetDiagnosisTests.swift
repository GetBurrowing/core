import XCTest

@testable import App

/// Device rev 1 (task 01a21e75): the widget says which step failed, with
/// no host, name or token in it.
final class WidgetDiagnosisTests: XCTestCase {
    private let a = Install(host: "app.example.test", name: "Alpha")
    private let b = Install(host: "lab.example.test", name: "Lab")

    func testEachFailureMapsToItsStep() {
        XCTAssertEqual(WidgetDiagnosis.code(for: BurrowAPIClient.Failure.refused(status: 404, code: nil)), "HTTP 404")
        XCTAssertEqual(WidgetDiagnosis.code(for: BurrowAPIClient.Failure.status(500)), "HTTP 500")
        XCTAssertEqual(WidgetDiagnosis.code(for: BurrowAPIClient.Failure.badResponse), "decode")
        XCTAssertEqual(WidgetDiagnosis.code(for: BurrowAPIClient.Failure.notSignedIn), "no token")
        XCTAssertEqual(WidgetDiagnosis.code(for: InstallFanout.TimedOut()), "timeout")
        XCTAssertEqual(WidgetDiagnosis.code(for: URLError(.notConnectedToInternet)), "network -1009")
    }

    func testTheSummaryNamesTheFirstFailingStep() {
        XCTAssertEqual(WidgetDiagnosis.summary(saved: [], installs: [], signedIn: { _ in true }, failures: [:]), "no install")
        XCTAssertEqual(WidgetDiagnosis.summary(saved: [a], installs: [a], signedIn: { _ in false }, failures: [:]), "no token")
        XCTAssertNil(WidgetDiagnosis.summary(saved: [a], installs: [a], signedIn: { _ in true }, failures: [:]))
        let both = [a.host: "HTTP 404", b.host: "HTTP 404"]
        XCTAssertEqual(WidgetDiagnosis.summary(saved: [a, b], installs: [a, b], signedIn: { _ in true }, failures: both), "HTTP 404")
        let mixed = [a.host: "HTTP 404", b.host: "timeout"]
        let line = WidgetDiagnosis.summary(saved: [a, b], installs: [a, b], signedIn: { _ in true }, failures: mixed)
        XCTAssertEqual(line, "HTTP 404 · timeout")
        XCTAssertFalse(line!.contains("example"), "never a host")
    }

    func testTheLoaderRecordsTheStepAndClearsItOnSuccess() async {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let defaultsName = "diagnosis-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: defaultsName) }
        let store = WidgetDiagnosisStore(defaults: UserDefaults(suiteName: defaultsName))
        let cacheName = "feed-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: cacheName) }
        let cache = WidgetFeedCache(defaults: UserDefaults(suiteName: cacheName))
        let client = BurrowAPIClient(session: StubURLProtocol.session(), tokens: MemoryTokenStore(tokens: [a.host: "token-for-a"]))

        StubURLProtocol.respond = { _ in (404, Data(#"{"errors":{"detail":"Not Found"}}"#.utf8)) }
        _ = await WidgetFeedLoader.load(installs: [a], client: client, cache: cache, diagnosis: store)
        XCTAssertEqual(store.failures[a.host], "HTTP 404")

        StubURLProtocol.respond = { _ in
            (200, Data(#"{"as_of":null,"waiting":{"count":0,"rows":[]},"blocked":{"count":0,"rows":[]},"recent":{"rows":[]},"shipped":{"count":0,"newest_title":null}}"#.utf8))
        }
        _ = await WidgetFeedLoader.load(installs: [a], client: client, cache: cache, diagnosis: store)
        XCTAssertNil(store.failures[a.host])
    }
}
