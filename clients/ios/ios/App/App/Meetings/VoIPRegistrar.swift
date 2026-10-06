import CallKit
import Foundation
import PushKit
import os

/// PushKit for rings (task 01a10db7 stage 5).
///
/// Created in `application(_:didFinishLaunchingWithOptions:)` before it
/// returns, so a VoIP push that launched the app is delivered. The VoIP
/// push credential goes hex-encoded to `POST /api/app/voip_devices` on
/// every install this app holds a bearer for, and nowhere else: it is
/// never logged, stored or shown. Sign-out needs nothing here: the server
/// drops the VoIP row with the session (stage 1).
@MainActor
final class VoIPRegistrar: NSObject, PKPushRegistryDelegate {
    static let shared = VoIPRegistrar()

    private static let log = Logger(subsystem: "com.kobo-ai.burrow", category: "rings")

    private var registry: PKPushRegistry?
    /// The current credential, hex. In memory only.
    private var hexCredential: String?
    /// Installs already told about `hexCredential` in this process.
    private var registeredHosts: Set<String> = []

    func start() {
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    /// Registers the credential with any signed-in install not yet told
    /// (after a sign-in, and when the app becomes active).
    func registerWithSignedInInstalls() {
        guard let hexCredential else { return }
        for install in InstallStore.shared.installs
        where !registeredHosts.contains(install.host) && SuiteAPIClient.shared.isSignedIn(host: install.host) {
            registeredHosts.insert(install.host)
            let host = install.host
            Task {
                do {
                    try await Self.post(hex: hexCredential, host: host)
                    Self.log.info("voip device registered host=\(host, privacy: .public)")
                } catch {
                    Self.log.error("voip device registration failed host=\(host, privacy: .public)")
                    self.registeredHosts.remove(host)
                }
            }
        }
    }

    /// The only request the credential travels in.
    static func voipDeviceBody(hex: String) -> [String: Any] {
        [
            "token": hex,
            "environment": SuiteAPI.pushEnvironment,
            "bundle_id": Bundle.main.bundleIdentifier ?? "com.kobo-ai.burrow",
            "app_install_id": InstallStore.shared.appInstallID,
        ]
    }

    static let voipDevicesPath = "/api/app/voip_devices"

    private static func post(hex: String, host: String) async throws {
        let response = try await SuiteAPIClient.shared.send(
            host: host, path: voipDevicesPath, method: "POST", json: voipDeviceBody(hex: hex))
        guard response.isSuccess else { throw SuiteAPIClient.Failure.status(response.status) }
    }

    // MARK: PKPushRegistryDelegate (delivered on the main queue)

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let hex = PushRegistrar.hex(pushCredentials.token)
        MainActor.assumeIsolated {
            if hex != self.hexCredential { self.registeredHosts = [] }
            self.hexCredential = hex
            self.registerWithSignedInInstalls()
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        MainActor.assumeIsolated {
            self.hexCredential = nil
            self.registeredHosts = []
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        let dictionary = payload.dictionaryPayload
        MainActor.assumeIsolated {
            VoIPEntry.receive(payload: dictionary, completion: completion)
        }
    }
}

/// `IncomingCallReporting` on the app's one `CXProvider`. CallKit answers
/// on its own queue; the answer is handed back on the main queue.
final class ProviderCallReporter: IncomingCallReporting {
    private let provider: CXProvider

    init(provider: CXProvider) {
        self.provider = provider
    }

    func reportIncoming(uuid: UUID, callerName: String, completion: @escaping (Error?) -> Void) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = false
        update.supportsHolding = true
        update.supportsDTMF = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    func reportEnded(uuid: UUID, reason: CXCallEndedReason) {
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
    }
}

#if DEBUG
    /// DEBUG-only VoIP injection: a simulator cannot receive a VoIP push
    /// (`xcrun simctl push`: "VoIP ... not supported"), so the review rig
    /// feeds a captured payload in here. Both doors go through
    /// `VoIPEntry.receive`, exactly as the PushKit delegate does.
    ///
    ///   * launch argument `-SuiteInjectVoIP <base64 JSON>`
    ///   * `burrow://debug/voip?payload=<base64 JSON>`
    ///
    /// Compiled out of Release.
    @MainActor
    enum DebugVoIPSeam {
        static let argument = "SuiteInjectVoIP"

        /// Decodes standard or URL-safe base64 of a JSON object.
        static func payload(base64: String) -> [AnyHashable: Any]? {
            var text = base64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while text.count % 4 != 0 { text += "=" }
            guard let data = Data(base64Encoded: text),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object
        }

        /// A payload that is not base64 JSON still goes in (as an empty,
        /// malformed payload): the seam must behave like a real bad push.
        static func inject(base64: String, completion: @escaping () -> Void = {}) {
            VoIPEntry.receive(payload: payload(base64: base64) ?? [:], completion: completion)
        }

        /// `burrow://debug/voip?payload=...`; false for any other URL.
        @discardableResult
        static func handle(url: URL, completion: @escaping () -> Void = {}) -> Bool {
            guard url.scheme?.lowercased() == DeepLink.scheme, url.host?.lowercased() == "debug", url.path == "/voip",
                let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "payload" })?.value
            else { return false }
            inject(base64: encoded, completion: completion)
            return true
        }

        /// The launch argument, once the shell is up.
        static func applyLaunchArgument() {
            guard let encoded = UserDefaults.standard.string(forKey: argument) else { return }
            inject(base64: encoded)
        }
    }
#endif
