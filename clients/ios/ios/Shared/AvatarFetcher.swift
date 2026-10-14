import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The sender's picture for a communication notification (task 01a12773
/// stage 4), from the push's `author_avatar_url`. Every failure is nil and
/// the caller draws the letter disc (`AvatarRenderer`); a notification is
/// never late or missing because of its avatar. Logs nothing.
///
/// The rules, each pinned by a test (AvatarTests):
/// - https only.
/// - The install's bearer goes ONLY to a url on the payload's own
///   `install_host` (compared after `InstallStore.normalizeHost`); an OIDC
///   picture on any other host is fetched with no Authorization header.
/// - No redirect is followed (the session delegate answers nil), so a
///   bearer can never ride a redirect to another host; the 3xx is a failure.
/// - Bounded: `timeoutIntervalForRequest` 2.0 s and
///   `timeoutIntervalForResource` 2.5 s, the TOTAL bound, inside the
///   extension's own time.
/// - At most 256 KB, decoded by ImageIO to a thumbnail of at most 192 px.
/// - Cached on disk (the App Group container in the app and the extension)
///   by sha256 of the FULL url, whose `?v=` token changes when the bytes do.
///   A failure is remembered for 10 minutes, so a dead host costs one
///   bounded attempt, not one per message.
final class AvatarFetcher {
    static let requestTimeout: TimeInterval = 2.0
    static let resourceTimeout: TimeInterval = 2.5
    static let maxBytes = 256 * 1024
    static let maxPixels = 192
    static let negativeTTL: TimeInterval = 10 * 60

    private let tokens: TokenStore
    private let cacheDirectory: URL?
    private let now: () -> Date
    private let session: URLSession

    /// `protocolClasses` is for tests (a URLProtocol stub); the app passes nil.
    init(tokens: TokenStore, cacheDirectory: URL?, protocolClasses: [AnyClass]? = nil, now: @escaping () -> Date = Date.init) {
        self.tokens = tokens
        self.cacheDirectory = cacheDirectory
        self.now = now
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.timeoutIntervalForResource = Self.resourceTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        if let protocolClasses { config.protocolClasses = protocolClasses }
        session = URLSession(configuration: config, delegate: RedirectRefuser(), delegateQueue: nil)
    }

    /// The live fetcher: the shared Keychain's bearers, the App Group cache.
    static func live() -> AvatarFetcher {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: InstallStore.appGroup)
        return AvatarFetcher(
            tokens: KeychainTokenStore.shared,
            cacheDirectory: container?.appendingPathComponent("Library/Caches/avatars", isDirectory: true))
    }

    deinit { session.invalidateAndCancel() }

    /// An https url, or nil: the only kind this ever requests.
    static func usable(_ text: String?) -> URL? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
            let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// True when [url] is on exactly [installHost]: same name, and a
    /// non-default port must be part of the host.
    static func sameHost(_ url: URL, _ installHost: String?) -> Bool {
        guard let installHost, let normalized = InstallStore.normalizeHost(installHost), let name = url.host?.lowercased() else { return false }
        let authority = (url.port == nil || url.port == 443) ? name : "\(name):\(url.port!)"
        return authority == normalized.lowercased()
    }

    /// The picture's thumbnail (PNG data), from disk or the network, or nil.
    func fetch(_ url: URL?, installHost: String?) async -> Data? {
        guard let url, url.scheme?.lowercased() == "https" else { return nil }
        if let hit = cached(url) { return hit }
        if recentlyFailed(url) { return nil }
        guard let thumbnail = await download(url, installHost: installHost) else {
            markFailed(url)
            return nil
        }
        store(thumbnail, for: url)
        return thumbnail
    }

    /// The disk cache only; never the network.
    func cached(_ url: URL?) -> Data? {
        guard let url, let file = file(for: url, suffix: "png") else { return nil }
        return try? Data(contentsOf: file)
    }

    private func download(_ url: URL, installHost: String?) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if Self.sameHost(url, installHost), let host = installHost.flatMap(InstallStore.normalizeHost), let bearer = tokens.token(for: host) {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            http.expectedContentLength <= Int64(Self.maxBytes), data.count <= Self.maxBytes
        else { return nil }
        return Self.thumbnail(data)
    }

    /// ImageIO thumbnail of at most `maxPixels` on a side, as PNG; nil when not an image.
    static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    // MARK: Disk

    private func file(for url: URL, suffix: String) -> URL? {
        guard let cacheDirectory else { return nil }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(digest).\(suffix)")
    }

    private func store(_ data: Data, for url: URL) {
        guard let cacheDirectory, let target = file(for: url, suffix: "png") else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: target, options: .atomic)
        if let failed = file(for: url, suffix: "failed") { try? FileManager.default.removeItem(at: failed) }
    }

    private func markFailed(_ url: URL) {
        guard let cacheDirectory, let marker = file(for: url, suffix: "failed") else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? Data(String(now().timeIntervalSince1970).utf8).write(to: marker, options: .atomic)
    }

    private func recentlyFailed(_ url: URL) -> Bool {
        guard let marker = file(for: url, suffix: "failed"), let data = try? Data(contentsOf: marker),
            let stamp = Double(String(decoding: data, as: UTF8.self))
        else { return false }
        return now().timeIntervalSince1970 - stamp < Self.negativeTTL
    }
}

/// The session delegate: no redirect is followed, so the task completes
/// with the 3xx, which `AvatarFetcher` treats as a failure. A separate
/// object because a URLSession retains its delegate.
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
