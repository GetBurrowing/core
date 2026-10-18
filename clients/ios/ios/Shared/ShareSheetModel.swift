import Foundation

/// What the person shared into Burrow, already copied somewhere the
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
    func form(message: String, agentID: String?, boundary: String = "burrow-\(UUID().uuidString)") -> MultipartForm {
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
        /// A large file handed to the background uploader (task 01a120be):
        /// the sheet closes at once; the server posts the message when the
        /// last chunk lands and a notification says so.
        case handedOff
    }

    /// "Uploading in the background. You can close this." (design canvas
    /// 01a120be-f336, share sheet).
    static let handedOffText = "Uploading in the background. You can close this."

    enum Banner: Equatable {
        case sendFailed
        case spacesFailed
        case tooLarge(bytes: Int64)
        /// Over the install's own limit, worded with the server's label.
        case overLimit(name: String, bytes: Int64, label: String)

        var text: String {
            switch self {
            case .sendFailed:
                return "Couldn't send. Your item is still here. Try again."
            case .spacesFailed:
                return "Couldn't load your spaces. Check your connection and try again."
            case .tooLarge(let bytes):
                return
                    "This item is \(ByteLabel.format(bytes)). Burrow takes up to \(ByteLabel.format(BurrowAPIClient.maxRequestBytes)) from the share sheet."
            case .overLimit(let name, let bytes, let label):
                return ShareRoute.tooLargeText(name: name, bytes: bytes, label: label)
            }
        }
    }

    static let notSignedInText = "Sign in to Burrow first. Open the Burrow app, sign in, then share again."
    /// How long `Sent to {space}` shows before the sheet closes.
    static let sentDwell: TimeInterval = 1.0

    @Published private(set) var phase: Phase = .loadingSpaces
    @Published private(set) var spaces: [BurrowSpace] = []
    @Published var selectedSpaceID: String? {
        didSet { if oldValue != selectedSpaceID { selectedAgentID = nil } }
    }
    @Published var selectedAgentID: String?
    @Published var message = ""
    @Published private(set) var banner: Banner?
    @Published var payload: SharePayload? {
        didSet { checkSize() }
    }
    /// The install's upload limits (`GET /api/app/upload_config`). Nil
    /// until loaded, or on a server that predates it; then only the
    /// multipart path exists and its transport cap applies.
    @Published private(set) var uploadConfig: UploadConfig? {
        didSet { checkSize() }
    }

    let install: Install?
    private let client: BurrowAPIClient
    private let lastSpace: UserDefaults
    private let uploader: LargeFileUploading

    init(
        install: Install?, client: BurrowAPIClient = .shared,
        lastSpace: UserDefaults? = UserDefaults(suiteName: InstallStore.appGroup),
        uploader: LargeFileUploading = BackgroundUploader.shared
    ) {
        self.install = install
        self.client = client
        self.lastSpace = lastSpace ?? .standard
        self.uploader = uploader
    }

    var selectedSpace: BurrowSpace? { spaces.first { $0.id == selectedSpaceID } }
    var selectedAgent: BurrowSpace.Agent? { selectedSpace?.agents.first { $0.id == selectedAgentID } }

    /// Fields lock while sending and after sending.
    var fieldsLocked: Bool {
        switch phase {
        case .sending, .sent, .handedOff: return true
        default: return false
        }
    }

    var canSend: Bool {
        guard phase == .ready, selectedSpace != nil, payload != nil else { return false }
        if case .tooLarge = banner { return false }
        if case .overLimit = banner { return false }
        return true
    }

    /// Where the current payload goes, given what is known of the server.
    var route: ShareRoute {
        guard let payload, let part = payload.filePart,
            let body = try? payload.form(message: message, agentID: selectedAgentID).contentLength()
        else { return .multipart }
        let fileBytes = Self.fileSize(part.url)
        guard let uploadConfig else {
            return body <= BurrowAPIClient.maxRequestBytes ? .multipart : .tooLarge(name: part.filename, bytes: fileBytes, label: "")
        }
        return ShareRoute.decide(fileName: part.filename, fileBytes: fileBytes, multipartBodyBytes: body, config: uploadConfig)
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
        loadUploadConfig()
    }

    func loadUploadConfig() {
        guard let install else { return }
        client.uploadConfig(host: install.host) { [weak self] result in
            DispatchQueue.main.async {
                if case .success(let config) = result { self?.uploadConfig = config }
            }
        }
    }

    func loadSpaces() {
        guard let install else { return }
        phase = .loadingSpaces
        if banner == .spacesFailed { banner = nil }
        client.spaces(host: install.host) { [weak self] result in
            DispatchQueue.main.async { self?.spacesLoaded(result) }
        }
    }

    private func spacesLoaded(_ result: Result<[BurrowSpace], Error>) {
        switch result {
        case .success(let list):
            spaces = list
            if selectedSpaceID == nil, let host = install?.host,
                let last = lastSpace.string(forKey: Self.lastSpaceKey(host)), list.contains(where: { $0.id == last })
            {
                selectedSpaceID = last
            }
            phase = .ready
        case .failure(BurrowAPIClient.Failure.notSignedIn), .failure(BurrowAPIClient.Failure.status(401)):
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
        if route == .chunked, let part = payload.filePart {
            return sendChunked(install: install, space: space, part: part, onSent: onSent)
        }
        let form = payload.form(message: message, agentID: selectedAgentID)
        client.sendMessage(host: install.host, spaceID: space.id, form: form) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.lastSpace.set(space.id, forKey: Self.lastSpaceKey(install.host))
                    self.phase = .sent(spaceName: space.name)
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.sentDwell, execute: onSent)
                case .failure(BurrowAPIClient.Failure.tooLarge(let bytes)):
                    self.banner = .tooLarge(bytes: bytes)
                    self.phase = .ready
                case .failure(BurrowAPIClient.Failure.status(413)):
                    self.banner = .tooLarge(bytes: (try? form.contentLength()) ?? BurrowAPIClient.maxRequestBytes + 1)
                    self.phase = .ready
                case .failure(BurrowAPIClient.Failure.notSignedIn), .failure(BurrowAPIClient.Failure.status(401)):
                    self.phase = .notSignedIn
                case .failure:
                    self.banner = .sendFailed
                    self.phase = .ready
                }
            }
        }
    }

    /// A file over the multipart limit: reserve it, hand it to the
    /// background uploader, and close the sheet at once.
    private func sendChunked(install: Install, space: BurrowSpace, part: MultipartForm.FilePart, onSent: @escaping () -> Void) {
        let size = Self.fileSize(part.url)
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        client.reserveUpload(
            host: install.host, spaceID: space.id, filename: part.filename, contentType: part.mimeType, byteSize: size,
            text: text, agentID: selectedAgentID
        ) { [weak self] result in
            guard let self else { return }
            let handedOff: Result<Void, Error> = result.flatMap { reservation in
                Result {
                    try self.uploader.enqueue(
                        reservation: reservation, host: install.host, file: part.url, filename: part.filename, byteSize: size,
                        spaceName: space.name)
                }
            }
            DispatchQueue.main.async {
                switch handedOff {
                case .success:
                    self.lastSpace.set(space.id, forKey: Self.lastSpaceKey(install.host))
                    self.phase = .handedOff
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.sentDwell, execute: onSent)
                case .failure(BurrowAPIClient.Failure.refused(413, _)):
                    self.checkSize()
                    self.phase = .ready
                case .failure(BurrowAPIClient.Failure.notSignedIn), .failure(BurrowAPIClient.Failure.refused(401, _)):
                    self.phase = .notSignedIn
                case .failure:
                    self.banner = .sendFailed
                    self.phase = .ready
                }
            }
        }
    }

    /// Refuses an attachment past the install's limit as soon as it is
    /// known, not after the upload. With the server's config this is the
    /// server's limit and label; without it (an older server) only the
    /// multipart path exists and its cap applies.
    private func checkSize() {
        let isSizeBanner: Bool = {
            switch banner {
            case .tooLarge, .overLimit: return true
            default: return false
            }
        }()
        switch route {
        case .tooLarge(let name, let bytes, let label) where uploadConfig != nil:
            banner = .overLimit(name: name, bytes: bytes, label: label)
        case .tooLarge:
            let body = (try? payload?.form(message: message, agentID: nil).contentLength()) ?? nil
            banner = .tooLarge(bytes: body ?? BurrowAPIClient.maxRequestBytes + 1)
        default:
            if isSizeBanner { banner = nil }
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    static func lastSpaceKey(_ host: String) -> String { "suite.share.last_space.v1.\(host)" }

    #if DEBUG
        /// Screenshot evidence only: put the sheet in a state without a server.
        func debugSet(phase: Phase, banner: Banner? = nil, spaces: [BurrowSpace]? = nil, uploadConfig: UploadConfig? = nil) {
            if let spaces { self.spaces = spaces }
            if let uploadConfig { self.uploadConfig = uploadConfig }
            self.phase = phase
            self.banner = banner
        }
    #endif
}
