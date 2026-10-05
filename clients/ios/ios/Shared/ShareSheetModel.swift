import Foundation

/// What the person shared into Suite, already copied somewhere the
/// extension owns (a file the system hands over is deleted when its
/// callback returns).
enum SharePayload: Equatable {
    case image(MultipartForm.FilePart)
    case pdf(MultipartForm.FilePart)
    /// Any other single file. Sent as-is with its own MIME type.
    case file(MultipartForm.FilePart)
    case url(URL)
    case text(String)

    var filePart: MultipartForm.FilePart? {
        switch self {
        case .image(let part), .pdf(let part), .file(let part): return part
        case .url, .text: return nil
        }
    }

    /// The multipart body for `POST /api/app/spaces/:id/messages`: `text`
    /// (the message, then the shared URL or text on its own line), an
    /// optional `agent_id`, and for a file the single `file` part.
    func form(message: String, agentID: String?, boundary: String = "suite-\(UUID().uuidString)") -> MultipartForm {
        let note = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var text: String
        switch self {
        case .url(let url): text = [note, url.absoluteString].filter { !$0.isEmpty }.joined(separator: "\n")
        case .text(let shared): text = [note, shared].filter { !$0.isEmpty }.joined(separator: "\n")
        case .image, .pdf, .file: text = note
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [(name: String, value: String)] = []
        if !text.isEmpty { fields.append((name: "text", value: text)) }
        if let agentID, !agentID.isEmpty { fields.append((name: "agent_id", value: agentID)) }
        return MultipartForm(boundary: boundary, fields: fields, file: filePart)
    }
}

/// The share sheet's state, with no UI in it, so the states are testable.
/// States and copy: canvas 01a10887, "States" table.
final class ShareSheetModel: ObservableObject {
    enum Phase: Equatable {
        case loadingSpaces
        case notSignedIn
        case ready
        case sending
        case sent(spaceName: String)
    }

    enum Banner: Equatable {
        case sendFailed
        case spacesFailed
        case tooLarge(bytes: Int64)

        var text: String {
            switch self {
            case .sendFailed:
                return "Couldn't send. Your item is still here. Try again."
            case .spacesFailed:
                return "Couldn't load your spaces. Check your connection and try again."
            case .tooLarge(let bytes):
                return "This item is \(ShareSheetModel.megabytes(bytes)). Burrow takes up to \(ShareSheetModel.megabytes(SuiteAPIClient.maxRequestBytes)) from the share sheet."
            }
        }
    }

    static let notSignedInText = "Sign in to Burrow first. Open the Burrow app, sign in, then share again."
    /// How long `Sent to {space}` shows before the sheet closes.
    static let sentDwell: TimeInterval = 1.0

    @Published private(set) var phase: Phase = .loadingSpaces
    @Published private(set) var spaces: [SuiteSpace] = []
    @Published var selectedSpaceID: String? {
        didSet { if oldValue != selectedSpaceID { selectedAgentID = nil } }
    }
    @Published var selectedAgentID: String?
    @Published var message = ""
    @Published private(set) var banner: Banner?
    @Published var payload: SharePayload? {
        didSet { checkSize() }
    }

    let install: Install?
    private let client: SuiteAPIClient
    private let lastSpace: UserDefaults

    init(install: Install?, client: SuiteAPIClient = .shared,
         lastSpace: UserDefaults? = UserDefaults(suiteName: InstallStore.appGroup)) {
        self.install = install
        self.client = client
        self.lastSpace = lastSpace ?? .standard
    }

    var selectedSpace: SuiteSpace? { spaces.first { $0.id == selectedSpaceID } }
    var selectedAgent: SuiteSpace.Agent? { selectedSpace?.agents.first { $0.id == selectedAgentID } }

    /// Fields lock while sending and after sending.
    var fieldsLocked: Bool {
        switch phase {
        case .sending, .sent: return true
        default: return false
        }
    }

    var canSend: Bool {
        guard phase == .ready, selectedSpace != nil, payload != nil else { return false }
        if case .tooLarge = banner { return false }
        return true
    }

    /// Checks the Keychain BEFORE anything touches the network: with no
    /// bearer for the selected install the sheet is `notSignedIn` and no
    /// request is made.
    func start() {
        guard let install, client.isSignedIn(host: install.host) else {
            phase = .notSignedIn
            return
        }
        loadSpaces()
    }

    func loadSpaces() {
        guard let install else { return }
        phase = .loadingSpaces
        if banner == .spacesFailed { banner = nil }
        client.spaces(host: install.host) { [weak self] result in
            DispatchQueue.main.async { self?.spacesLoaded(result) }
        }
    }

    private func spacesLoaded(_ result: Result<[SuiteSpace], Error>) {
        switch result {
        case .success(let list):
            spaces = list
            if selectedSpaceID == nil, let host = install?.host,
               let last = lastSpace.string(forKey: Self.lastSpaceKey(host)), list.contains(where: { $0.id == last }) {
                selectedSpaceID = last
            }
            phase = .ready
        case .failure(SuiteAPIClient.Failure.notSignedIn), .failure(SuiteAPIClient.Failure.status(401)):
            phase = .notSignedIn
        case .failure:
            banner = .spacesFailed
            phase = .ready
        }
    }

    /// Sends, keeping everything the person entered if it fails. `onSent`
    /// runs after `Sent to {space}` has shown for `sentDwell`.
    func send(onSent: @escaping () -> Void) {
        guard canSend, let install, let space = selectedSpace, let payload else { return }
        banner = nil
        phase = .sending
        let form = payload.form(message: message, agentID: selectedAgentID)
        client.sendMessage(host: install.host, spaceID: space.id, form: form) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.lastSpace.set(space.id, forKey: Self.lastSpaceKey(install.host))
                    self.phase = .sent(spaceName: space.name)
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.sentDwell, execute: onSent)
                case .failure(SuiteAPIClient.Failure.tooLarge(let bytes)):
                    self.banner = .tooLarge(bytes: bytes)
                    self.phase = .ready
                case .failure(SuiteAPIClient.Failure.status(413)):
                    self.banner = .tooLarge(bytes: (try? form.contentLength()) ?? SuiteAPIClient.maxRequestBytes + 1)
                    self.phase = .ready
                case .failure(SuiteAPIClient.Failure.notSignedIn), .failure(SuiteAPIClient.Failure.status(401)):
                    self.phase = .notSignedIn
                case .failure:
                    self.banner = .sendFailed
                    self.phase = .ready
                }
            }
        }
    }

    /// Refuses an attachment past the server's cap as soon as it is known,
    /// not after the upload.
    private func checkSize() {
        guard let payload, payload.filePart != nil,
              let size = try? payload.form(message: message, agentID: nil).contentLength() else {
            if case .tooLarge = banner { banner = nil }
            return
        }
        if size > SuiteAPIClient.maxRequestBytes {
            banner = .tooLarge(bytes: size)
        } else if case .tooLarge = banner {
            banner = nil
        }
    }

    static func lastSpaceKey(_ host: String) -> String { "suite.share.last_space.v1.\(host)" }

    static func megabytes(_ bytes: Int64) -> String {
        let value = Double(bytes) / 1_000_000
        return value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value)) MB" : String(format: "%.1f MB", value)
    }

    #if DEBUG
    /// Screenshot evidence only: put the sheet in a state without a server.
    func debugSet(phase: Phase, banner: Banner? = nil, spaces: [SuiteSpace]? = nil) {
        if let spaces { self.spaces = spaces }
        self.phase = phase
        self.banner = banner
    }
    #endif
}
