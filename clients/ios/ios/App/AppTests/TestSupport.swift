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
    private static var _bodies: [Data?] = []
    static var respond: (URLRequest) -> (Int, Data) = { _ in (200, Data("{}".utf8)) }
    /// Response headers per request (task 01a120be: `Upload-Offset`).
    static var respondHeaders: (URLRequest) -> [String: String] = { _ in [:] }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    /// Each request's body (read from its stream), in request order.
    static var bodies: [Data?] {
        lock.lock()
        defer { lock.unlock() }
        return _bodies
    }

    /// Request `index`'s body as a JSON object, or nil.
    static func json(at index: Int) -> [String: Any]? {
        let all = bodies
        guard index < all.count, let data = all[index] else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func reset() {
        lock.lock()
        _requests = []
        _bodies = []
        lock.unlock()
        respond = { _ in (200, Data("{}".utf8)) }
        respondHeaders = { _ in [:] }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        Self.lock.lock()
        Self._requests.append(request)
        Self._bodies.append(body)
        Self.lock.unlock()
        let (status, data) = Self.respond(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: Self.respondHeaders(request))!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
