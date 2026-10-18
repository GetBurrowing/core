import CryptoKit
import Intents
import UIKit
import UserNotifications
import XCTest

@testable import App

/// A URLProtocol stub for the avatar fetch: records requests, can hold a
/// response for a delay (honouring cancellation), and can answer with a
/// redirect. Separate from `StubURLProtocol`, whose answers are immediate.
final class AvatarStubProtocol: URLProtocol {
    struct Answer {
        var status = 200
        var body = Data()
        var delay: TimeInterval = 0
        var location: String?
    }

    private static let lock = NSLock()
    private static var _requests: [URLRequest] = []
    static var answer: (URLRequest) -> Answer = { _ in Answer() }
    private var cancelled = false

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    static func reset() {
        lock.lock()
        _requests = []
        lock.unlock()
        answer = { _ in Answer() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._requests.append(request)
        Self.lock.unlock()
        let answer = Self.answer(request)
        let respond = { [weak self] in
            guard let self, !self.cancelled else { return }
            var headers: [String: String] = [:]
            if let location = answer.location { headers["Location"] = location }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            if let location = answer.location, let target = URL(string: location) {
                self.client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: answer.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if answer.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + answer.delay, execute: respond)
        } else {
            respond()
        }
    }

    override func stopLoading() { cancelled = true }
}

/// Task 01a12773 stage 4: the sender's picture on a communication
/// notification. AvatarFetcher's bounds and host rule, the renderer's
/// in-app colours and opaque flatten, and the extension's exactly-once
/// delivery.
final class AvatarTests: XCTestCase {
    private let host = "suite.example.com"
    private let bearer = "tok_live_bearer_9f8e7d"
    private var cache: URL!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        AvatarStubProtocol.reset()
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cache)
        AvatarStubProtocol.reset()
        super.tearDown()
    }

    private func fetcher() -> AvatarFetcher {
        AvatarFetcher(
            tokens: MemoryTokenStore(tokens: [host: bearer, "idp.example": "a-bearer-for-another-host"]), cacheDirectory: cache,
            protocolClasses: [AvatarStubProtocol.self], now: { [unowned self] in self.now })
    }

    private func png(_ color: UIColor, size: CGFloat = 64, opaque: Bool = true) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    private func pixel(_ data: Data, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let image = UIImage(data: data)!.cgImage!
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }

    private func near(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8), _ rgb: UInt32, tolerance: Int = 6) -> Bool {
        abs(Int(p.r) - Int((rgb >> 16) & 0xFF)) <= tolerance && abs(Int(p.g) - Int((rgb >> 8) & 0xFF)) <= tolerance
            && abs(Int(p.b) - Int(rgb & 0xFF)) <= tolerance
    }

    private var agentURL: URL { URL(string: "https://\(host)/api/app/agents/0f000000-0000-4000-8000-000000000001/avatar?v=c0ffee12")! }

    // MARK: AvatarFetcher

    func testASameHostURLSendsTheInstallsBearer() async throws {
        AvatarStubProtocol.answer = { _ in .init(body: self.png(.red)) }
        let data = await fetcher().fetch(agentURL, installHost: host)
        XCTAssertNotNil(data)
        XCTAssertEqual(AvatarStubProtocol.requests.single?.value(forHTTPHeaderField: "Authorization"), "Bearer \(bearer)")
    }

    func testAForeignHostURLSendsNoAuthorizationAtAll() async throws {
        AvatarStubProtocol.answer = { _ in .init(body: self.png(.red)) }
        let data = await fetcher().fetch(URL(string: "https://idp.example/face.png")!, installHost: host)
        XCTAssertNotNil(data)
        let request = try XCTUnwrap(AvatarStubProtocol.requests.single)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testTheSameNameOnAnotherPortIsAnotherHost() {
        XCTAssertTrue(AvatarFetcher.sameHost(URL(string: "https://SUITE.example.com/a")!, host))
        XCTAssertTrue(AvatarFetcher.sameHost(URL(string: "https://suite.example.com:443/a")!, host))
        XCTAssertFalse(AvatarFetcher.sameHost(URL(string: "https://suite.example.com:8443/a")!, host))
        XCTAssertFalse(AvatarFetcher.sameHost(URL(string: "https://suite.example.com.evil.example/a")!, host))
        XCTAssertFalse(AvatarFetcher.sameHost(URL(string: "https://suite.example.com/a")!, nil))
    }

    func testARedirectIsNotFollowedAndItsTargetSeesNothing() async {
        AvatarStubProtocol.answer = { request in
            request.url?.host == "evil.example" ? .init(body: self.png(.red)) : .init(status: 302, location: "https://evil.example/stolen.png")
        }
        let data = await fetcher().fetch(agentURL, installHost: host)
        XCTAssertNil(data)
        XCTAssertEqual(AvatarStubProtocol.requests.map { $0.url?.host }, [host], "the redirect target got no request")
    }

    func testAHostThatHoldsTheResponseFor10SecondsIsAbandonedWithin3() async {
        AvatarStubProtocol.answer = { _ in .init(body: self.png(.red), delay: 10) }
        let start = Date()
        let data = await fetcher().fetch(agentURL, installHost: host)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(data)
        XCTAssertLessThan(elapsed, 3, "took \(elapsed) s")
    }

    func testABodyOver256KBAndBytesThatAreNotAnImageAreRefused() async {
        AvatarStubProtocol.answer = { request in
            request.url!.path.hasSuffix("big.png") ? .init(body: Data(repeating: 7, count: 300 * 1024)) : .init(body: Data("<html>sign in</html>".utf8))
        }
        let f = fetcher()
        let big = await f.fetch(URL(string: "https://idp.example/big.png")!, installHost: host)
        let html = await f.fetch(URL(string: "https://idp.example/page.png")!, installHost: host)
        XCTAssertNil(big)
        XCTAssertNil(html)
        XCTAssertEqual(AvatarStubProtocol.requests.count, 2)
    }

    func testNoURLOrANonHTTPSURLMakesNoRequest() async {
        let f = fetcher()
        let none = await f.fetch(nil, installHost: host)
        let http = await f.fetch(URL(string: "http://\(host)/a.png")!, installHost: host)
        XCTAssertNil(none)
        XCTAssertNil(http)
        XCTAssertNil(AvatarFetcher.usable("/agents/a/avatar"))
        XCTAssertEqual(AvatarStubProtocol.requests.count, 0)
    }

    func testAPictureIsFetchedOnceThenServedFromTheDiskCache() async {
        AvatarStubProtocol.answer = { _ in .init(body: self.png(.red)) }
        let first = await fetcher().fetch(agentURL, installHost: host)
        // A second extension launch: a new fetcher over the same cache.
        let second = await fetcher().fetch(agentURL, installHost: host)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(AvatarStubProtocol.requests.count, 1)
    }

    func testAFailureIsRememberedForTenMinutesThenRetried() async {
        AvatarStubProtocol.answer = { _ in .init(status: 500) }
        let f = fetcher()
        _ = await f.fetch(agentURL, installHost: host)
        now += 9 * 60
        _ = await f.fetch(agentURL, installHost: host)
        XCTAssertEqual(AvatarStubProtocol.requests.count, 1)
        AvatarStubProtocol.answer = { _ in .init(body: self.png(.red)) }
        now += 2 * 60
        let retried = await f.fetch(agentURL, installHost: host)
        XCTAssertNotNil(retried)
        XCTAssertEqual(AvatarStubProtocol.requests.count, 2)
    }

    func testALargePictureBecomesAThumbnailOfAtMost192Pixels() throws {
        let thumb = try XCTUnwrap(AvatarFetcher.thumbnail(png(.green, size: 1000)))
        let image = try XCTUnwrap(UIImage(data: thumb)?.cgImage)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 192)
    }

    // MARK: Renderer

    func testInitialsFollowTheInAppRule() {
        XCTAssertEqual(AvatarRenderer.initials("Sam Lee", count: 2), "SL")
        XCTAssertEqual(AvatarRenderer.initials("  ada  bea cy ", count: 2), "AB")
        XCTAssertEqual(AvatarRenderer.initials("Octavius Bot", count: 1), "O")
        XCTAssertEqual(AvatarRenderer.initials("élodie durand", count: 2), "ÉD")
        XCTAssertEqual(AvatarRenderer.initials("\u{1F469}\u{200D}\u{1F4BB} dev", count: 2), "\u{1F469}\u{200D}\u{1F4BB}D", "a ZWJ emoji is one grapheme")
        XCTAssertEqual(AvatarRenderer.initials("   ", count: 2), "U")
        XCTAssertEqual(AvatarRenderer.initials(nil, count: 1), "U")
    }

    func testEveryFallbackPairAndTheAgentPairPassAA() {
        func luminance(_ rgb: UInt32) -> Double {
            func channel(_ c: UInt32) -> Double {
                let v = Double(c) / 255
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel((rgb >> 16) & 0xFF) + 0.7152 * channel((rgb >> 8) & 0xFF) + 0.0722 * channel(rgb & 0xFF)
        }
        func contrast(_ a: UInt32, _ b: UInt32) -> Double {
            let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
            return (hi + 0.05) / (lo + 0.05)
        }
        for (i, pair) in AvatarRenderer.fallbackPairs.enumerated() {
            XCTAssertGreaterThanOrEqual(contrast(pair.background, pair.foreground), 4.5, "avatar-fallback-\(i)")
        }
        for theme in [AvatarRenderer.light, AvatarRenderer.dark] {
            XCTAssertGreaterThanOrEqual(contrast(theme.base300, theme.primary), 4.5)
        }
    }

    func testTheDiscIsTheTonesColourAndAnAgentGetsBase300() {
        let person = AvatarRenderer.fallback(name: "Sam Lee", tone: "3", theme: AvatarRenderer.light)
        XCTAssertTrue(near(pixel(person, x: 96, y: 8), AvatarRenderer.fallbackPairs[3].background))
        let agent = AvatarRenderer.fallback(name: "Octavius", tone: "agent", theme: AvatarRenderer.light)
        XCTAssertTrue(near(pixel(agent, x: 96, y: 8), AvatarRenderer.light.base300))
    }

    func testATransparentPictureIsFlattenedOntoOpaqueBase100() throws {
        let clear = png(.clear, opaque: false)
        for theme in [AvatarRenderer.light, AvatarRenderer.dark] {
            let flat = try XCTUnwrap(AvatarRenderer.flatten(clear, theme: theme))
            let centre = pixel(flat, x: 96, y: 96)
            XCTAssertEqual(centre.a, 255)
            XCTAssertTrue(near(centre, theme.base100))
        }
    }

    // MARK: Communication notification

    private func chatInfo(avatar: String? = nil, tone: String? = nil) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            "kind": "chat_mention", "install_host": host, "space_id": "0f000000-0000-4000-8000-0000000000a1",
            "message_id": "0f000000-0000-4000-8000-0000000000b1", "author_id": "0f000000-0000-4000-8000-000000000001",
            "author_type": "agent", "author_name": "Octavius", "space_name": "launch",
        ]
        if let avatar { info["author_avatar_url"] = avatar }
        if let tone { info["author_avatar_tone"] = tone }
        return info
    }

    func testThePayloadParsesTheAvatarURLHTTPSOnlyAndTheTone() throws {
        let payload = try XCTUnwrap(CommunicationPayload(userInfo: chatInfo(avatar: agentURL.absoluteString, tone: "agent")))
        XCTAssertEqual(payload.avatarURL, agentURL)
        XCTAssertEqual(payload.avatarTone, "agent")
        let bad = try XCTUnwrap(CommunicationPayload(userInfo: chatInfo(avatar: "http://idp.example/a.png", tone: "9")))
        XCTAssertNil(bad.avatarURL)
        XCTAssertNil(bad.avatarTone)
        XCTAssertEqual(bad.effectiveTone, "agent", "an agent author still gets the agent disc")
    }

    func testTheSenderImageIsNeverNilOnSuccessOrFailure() throws {
        let payload = try XCTUnwrap(CommunicationPayload(userInfo: chatInfo(avatar: agentURL.absoluteString, tone: "agent")))
        XCTAssertNotNil(CommunicationNotification.sendMessageIntent(payload, image: png(.red)).sender?.image)
        XCTAssertNotNil(CommunicationNotification.sendMessageIntent(payload, image: nil).sender?.image)
        XCTAssertNotNil(CommunicationNotification.sendMessageIntent(payload, image: Data("not an image".utf8)).sender?.image)
    }

    func testARelayedSealedPushYieldsTheAvatarURL() throws {
        let url =
            Bundle(for: Self.self).url(forResource: "push_seal_v1", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/push_seal_v1.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let fixtureHost = try XCTUnwrap(json["install_host"] as? String)
        var inner = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((json["plaintext"] as! String).utf8)) as? [String: Any])
        let avatar = "https://\(fixtureHost)/api/app/agents/agent-1/avatar?v=sealed"
        inner["author_avatar_url"] = avatar
        inner["author_avatar_tone"] = "agent"

        // Seal the amended inner map the way the server does.
        let publicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: try XCTUnwrap(PushKeyStore.data(base64url: json["recipient_public_key"] as! String)))
        var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: PushSeal.ciphersuite, info: PushSeal.info)
        let ciphertext = try sender.seal(try JSONSerialization.data(withJSONObject: inner), authenticating: Data(fixtureHost.utf8))
        let sealed = PushKeyStore.base64url(sender.encapsulatedKey + ciphertext)

        let privateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: try XCTUnwrap(PushKeyStore.data(base64url: json["recipient_private_key"] as! String)))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "avatar-tests-\(UUID().uuidString)"))
        let preparer = PushContentPreparer(
            privateKey: { _ in privateKey }, unread: InstallUnreadStore(defaults: defaults), installs: { [] }, isSignedIn: { _ in false })
        let relayed = UNMutableNotificationContent()
        relayed.userInfo = ["install_host": fixtureHost, "sealed": sealed]
        // The url is NOT in what the relay delivered, only inside the blob.
        XCTAssertFalse("\(relayed.userInfo)".contains("/api/app/agents/"))

        let prepared = preparer.prepare(relayed)
        let payload = try XCTUnwrap(CommunicationPayload(userInfo: prepared.userInfo))
        XCTAssertEqual(payload.avatarURL?.absoluteString, avatar)
        XCTAssertEqual(payload.avatarTone, "agent")
    }

    // MARK: Extension delivery

    private func content(_ info: [AnyHashable: Any]) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Octavius in launch"
        content.body = "Deck is updated."
        content.userInfo = info
        return content
    }

    func testNoAvatarURLDeliversTheLetterVersionAtOnceWithNoRequest() {
        var delivered: [UNNotificationContent] = []
        let f = fetcher()
        let delivery = AvatarNotificationDelivery(fetch: { url, host in await f.fetch(url, installHost: host) }, deliver: { delivered.append($0) })
        delivery.start(content(chatInfo(tone: "agent")))
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(AvatarStubProtocol.requests.count, 0)
    }

    func testAFetchedPictureIsDeliveredOnce() async throws {
        AvatarStubProtocol.answer = { _ in .init(body: self.png(.red)) }
        let done = expectation(description: "delivered")
        let lock = NSLock()
        var count = 0
        let f = fetcher()
        let delivery = AvatarNotificationDelivery(
            fetch: { url, host in await f.fetch(url, installHost: host) },
            deliver: { _ in
                lock.lock()
                count += 1
                lock.unlock()
                done.fulfill()
            })
        delivery.start(content(chatInfo(avatar: agentURL.absoluteString, tone: "agent")))
        await fulfillment(of: [done], timeout: 5)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(AvatarStubProtocol.requests.count, 1)
    }

    func testExpiryMidFetchDeliversTheBestAttemptExactlyOnce() async throws {
        AvatarStubProtocol.answer = { _ in .init(body: self.png(.red), delay: 10) }
        let lock = NSLock()
        var delivered: [UNNotificationContent] = []
        let f = fetcher()
        let delivery = AvatarNotificationDelivery(
            fetch: { url, host in await f.fetch(url, installHost: host) },
            deliver: { content in
                lock.lock()
                delivered.append(content)
                lock.unlock()
            })
        delivery.start(content(chatInfo(avatar: agentURL.absoluteString, tone: "agent")))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(delivered.count, 0, "still fetching")
        delivery.expire()
        XCTAssertEqual(delivered.count, 1)
        XCTAssertTrue(delivered.first === delivery.bestAttempt, "the letter version, already a communication notification")
        // The fetch ends later (timeout): nothing more is delivered.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(delivered.count, 1)
    }
}

extension Array {
    fileprivate var single: Element? { count == 1 ? first : nil }
}
