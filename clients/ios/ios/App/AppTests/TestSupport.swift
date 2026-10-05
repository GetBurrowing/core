import Foundation
@testable import App

/// An in-memory `TokenStore`: host -> bearer.
struct MemoryTokenStore: TokenStore {
    var tokens: [String: String] = [:]
    func token(for host: String) -> String? { tokens[host] }
}

/// Records every request a stubbed URLSession makes and answers it with
/// `StubURLProtocol.respond`. Lets a test assert how many requests went
/// out, to which host, with which Authorization header.
final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _requests: [URLRequest] = []
    static var respond: (URLRequest) -> (Int, Data) = { _ in (200, Data("{}".utf8)) }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    static func reset() {
        lock.lock(); _requests = []; lock.unlock()
        respond = { _ in (200, Data("{}".utf8)) }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self._requests.append(request); Self.lock.unlock()
        let (status, data) = Self.respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
