import Foundation

/// A space the person can post into, from `GET /api/app/spaces`, with the
/// agents participating in it (the share sheet's optional agent row).
struct SuiteSpace: Decodable, Equatable, Identifiable {
    struct Agent: Decodable, Equatable, Identifiable {
        let id: String
        let name: String
        let slug: String?
    }

    /// What a space with no name is called: the server leaves a DM's name
    /// null (fixed server-side to always send one; this is the fallback).
    static let unnamedDirectMessage = "Direct message"

    let id: String
    let name: String
    let slug: String?
    let kind: String?
    /// `Chat.space_path_segment/1`: what `/chat/<segment>` takes. A DM has
    /// no slug, so deep links use this, never `slug`.
    let pathSegment: String?
    let agents: [Agent]

    /// What `/chat/<segment>` opens this space by. The server's
    /// `path_segment` when it sends one; otherwise the id, which
    /// `/chat/:segment` always resolves (a slug would be wrong for an org
    /// space, whose segment is its id).
    var linkSegment: String { pathSegment ?? id }

    var isDirectMessage: Bool { kind == "dm" }

    private enum CodingKeys: String, CodingKey {
        case id, name, slug, kind, agents
        case pathSegment = "path_segment"
        case displayName = "display_name"
    }

    init(id: String, name: String, slug: String? = nil, kind: String? = nil, pathSegment: String? = nil, agents: [Agent] = []) {
        self.id = id
        self.name = name
        self.slug = slug
        self.kind = kind
        self.pathSegment = pathSegment
        self.agents = agents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        // `display_name` (a DM named for the other participant) wins over
        // `name`; both may be absent or null.
        let displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name)
        name = [displayName, decodedName].compactMap { $0 }.first { !$0.isEmpty } ?? Self.unnamedDirectMessage
        slug = try container.decodeIfPresent(String.self, forKey: .slug)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        pathSegment = try container.decodeIfPresent(String.self, forKey: .pathSegment)
        agents = try container.decodeIfPresent([Agent].self, forKey: .agents) ?? []
    }
}

/// Bearer requests to one install's `/api/app/*` routes.
///
/// The token is looked up by the SAME host the request is built for, at
/// the moment the request is built, in one place (`authorizedRequest`).
/// Nothing caches a token or a "current" host, so install A's bearer cannot
/// be sent to install B. A host with no token fails `notSignedIn` before any
/// request exists, so a signed-out share sheet or widget makes no network
/// call at all.
struct SuiteAPIClient {
    enum Failure: Error, Equatable {
        case notSignedIn
        case status(Int)
        case badResponse
        /// The multipart body would exceed `maxRequestBytes`.
        case tooLarge(bytes: Int64)
        /// A non-2xx answer with the server's `{"error": code}`.
        case refused(status: Int, code: String?)
    }

    /// Plug.Parsers' default multipart `:length`, 8_000_000 bytes for the
    /// WHOLE request body. The server's endpoint does not raise it, so a
    /// larger body gets a 413 before the controller runs, even though chat
    /// itself allows 15 MB per file. The share sheet refuses past this.
    static let maxRequestBytes: Int64 = 8_000_000

    static let shared = SuiteAPIClient()

    let session: URLSession
    let tokens: TokenStore

    init(session: URLSession = .shared, tokens: TokenStore = KeychainTokenStore.shared) {
        self.session = session
        self.tokens = tokens
    }

    func isSignedIn(host: String) -> Bool {
        tokens.token(for: host) != nil
    }

    /// The only place a bearer is attached to a request.
    func authorizedRequest(host: String, path: String) throws -> URLRequest {
        guard let token = tokens.token(for: host) else { throw Failure.notSignedIn }
        guard let url = URL(string: "https://\(host)\(path)") else { throw Failure.badResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: Routes

    func spaces(host: String, completion: @escaping (Result<[SuiteSpace], Error>) -> Void) {
        struct Body: Decodable { let spaces: [SuiteSpace] }
        get(host: host, path: "/api/app/spaces") { result in
            completion(
                result.flatMap { data in
                    Result { try JSONDecoder().decode(Body.self, from: data).spaces }
                        .mapError { _ in Failure.badResponse }
                })
        }
    }

    func counts(
        host: String, now: @escaping () -> Date = Date.init,
        completion: @escaping (Result<SuiteCounts, Error>) -> Void
    ) {
        struct Body: Decodable {
            let approvals: Int
            let tasks: Int
        }
        get(host: host, path: "/api/app/counts") { result in
            completion(
                result.flatMap { data in
                    Result {
                        let body = try JSONDecoder().decode(Body.self, from: data)
                        return SuiteCounts(approvals: body.approvals, tasks: body.tasks, fetchedAt: now())
                    }.mapError { _ in Failure.badResponse }
                })
        }
    }

    func postJSON(host: String, path: String, json: [String: Any], completion: @escaping (Result<Data, Error>) -> Void) {
        do {
            var request = try authorizedRequest(host: host, path: path)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            run(
                session.dataTask(with: request) { data, response, error in
                    completion(Self.check(data, response, error))
                })
        } catch {
            completion(.failure(error))
        }
    }

    /// `POST /api/app/handoff`: a fresh one-time URL that signs the web view
    /// in as the bearer's user (WKWebView's session cookie does not outlive
    /// the app process). `path` is where it lands; the server keeps only a
    /// local path. A URL on any other host than `host` is refused.
    func handoff(host: String, path: String?, completion: @escaping (Result<URL, Error>) -> Void) {
        var json: [String: Any] = [:]
        if let path { json["path"] = path }
        postJSON(host: host, path: "/api/app/handoff", json: json) { result in
            completion(
                result.flatMap { data in
                    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let url = (object["handoff_url"] as? String).flatMap(URL.init(string:)),
                        url.host?.lowercased() == host.lowercased()
                    else {
                        return .failure(Failure.badResponse)
                    }
                    return .success(url)
                })
        }
    }

    /// A bearer `DELETE` (`/api/app/session`, `/api/app/devices/:id`).
    func delete(host: String, path: String, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            var request = try authorizedRequest(host: host, path: path)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 20
            run(
                session.dataTask(with: request) { data, response, error in
                    completion(Self.check(data, response, error).map { _ in () })
                })
        } catch {
            completion(.failure(error))
        }
    }

    /// `POST /api/app/spaces/:space_id/messages` as multipart. The body is
    /// written to a file first and uploaded from it, so a large attachment
    /// is streamed from disk and never held in the extension's memory.
    func sendMessage(
        host: String, spaceID: String, form: MultipartForm,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        upload(host: host, spaceID: spaceID, form: form) { completion($0.map { _ in () }) }
    }

    /// `sendMessage`, keeping the response body (the posted message's id).
    func upload(
        host: String, spaceID: String, form: MultipartForm,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        do {
            var request = try authorizedRequest(host: host, path: Self.messagesPath(spaceID))
            let size = try form.contentLength()
            guard size <= Self.maxRequestBytes else { throw Failure.tooLarge(bytes: size) }
            let bodyURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("suite-share-\(UUID().uuidString).multipart")
            try form.write(to: bodyURL)
            request.httpMethod = "POST"
            request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
            request.setValue(String(size), forHTTPHeaderField: "Content-Length")
            run(
                session.uploadTask(with: request, fromFile: bodyURL) { data, response, error in
                    try? FileManager.default.removeItem(at: bodyURL)
                    completion(Self.check(data, response, error))
                })
        } catch {
            completion(.failure(error))
        }
    }

    static func messagesPath(_ spaceID: String) -> String {
        "/api/app/spaces/\(segment(spaceID))/messages"
    }

    static func devicePath(_ appInstallID: String) -> String {
        "/api/app/devices/\(segment(appInstallID))"
    }

    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? value
    }

    // MARK: Plumbing

    private func get(host: String, path: String, completion: @escaping (Result<Data, Error>) -> Void) {
        do {
            var request = try authorizedRequest(host: host, path: path)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            run(
                session.dataTask(with: request) { data, response, error in
                    completion(Self.check(data, response, error))
                })
        } catch {
            completion(.failure(error))
        }
    }

    private func run(_ task: URLSessionTask) { task.resume() }

    private static func check(_ data: Data?, _ response: URLResponse?, _ error: Error?) -> Result<Data, Error> {
        if let error { return .failure(error) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { return .failure(Failure.status(status)) }
        return .success(data ?? Data())
    }
}

/// A `multipart/form-data` body: text fields plus at most one file, written
/// to disk in chunks so the file is never read into memory whole.
struct MultipartForm {
    struct FilePart: Equatable {
        var fieldName = "file"
        var filename: String
        var mimeType: String
        var url: URL
    }

    let boundary: String
    var fields: [(name: String, value: String)]
    var file: FilePart?

    init(boundary: String = "suite-\(UUID().uuidString)", fields: [(name: String, value: String)] = [], file: FilePart? = nil) {
        self.boundary = boundary
        self.fields = fields
        self.file = file
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    func value(of name: String) -> String? {
        fields.first { $0.name == name }?.value
    }

    /// The exact byte length `write(to:)` produces, computed without reading
    /// the file.
    func contentLength() throws -> Int64 {
        var total = Int64(headerData().count + trailerData().count)
        if let file {
            let size = try FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber
            total += size?.int64Value ?? 0
        }
        return total
    }

    func write(to url: URL, chunkSize: Int = 64 * 1024) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        out.write(headerData())
        if let file {
            let input = try FileHandle(forReadingFrom: file.url)
            defer { try? input.close() }
            while true {
                let chunk = input.readData(ofLength: chunkSize)
                if chunk.isEmpty { break }
                out.write(chunk)
            }
        }
        out.write(trailerData())
    }

    /// Every field, then the file part's headers (its bytes follow).
    private func headerData() -> Data {
        var text = ""
        for field in fields {
            text += "--\(boundary)\r\n"
            text += "Content-Disposition: form-data; name=\"\(Self.escape(field.name))\"\r\n\r\n"
            text += "\(field.value)\r\n"
        }
        if let file {
            text += "--\(boundary)\r\n"
            text += "Content-Disposition: form-data; name=\"\(Self.escape(file.fieldName))\"; filename=\"\(Self.escape(file.filename))\"\r\n"
            text += "Content-Type: \(file.mimeType)\r\n\r\n"
        }
        return Data(text.utf8)
    }

    private func trailerData() -> Data {
        Data(((file == nil ? "" : "\r\n") + "--\(boundary)--\r\n").utf8)
    }

    /// Quotes and line breaks cannot appear inside a quoted header value.
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }
}

// MARK: - App Intents routes (task 01a10db6)

/// One approval inbox row from `GET /api/app/approvals`: a plan or a
/// review waiting on the person.
struct SuiteApproval: Codable, Equatable {
    let id: String
    /// `plan` or `review`.
    let kind: String
    let title: String
    let spaceName: String?
    let spacePathSegment: String?
    let taskID: String?
    let insertedAt: String?
    let summary: String?

    var isPlan: Bool { kind == "plan" }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, summary
        case spaceName = "space_name"
        case spacePathSegment = "space_path_segment"
        case taskID = "task_id"
        case insertedAt = "inserted_at"
    }
}

/// What approving or rejecting came to.
enum ApprovalOutcome: Equatable {
    /// The server's new status (`approved`, `rejected`).
    case done(String)
    /// 409 `already_handled`: someone settled it first. `by` is who
    /// approved it, nil when nobody is named (a rejected plan).
    case alreadyHandled(by: String?)
}

struct SuiteTask: Decodable, Equatable {
    let id: String
    let title: String
    let status: String?
    let projectName: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, status
        case projectName = "project_name"
    }
}

struct SuiteMeeting: Decodable, Equatable {
    let id: String
    let slug: String
    let name: String
    let startsAt: String?
    let spaceName: String?

    private enum CodingKeys: String, CodingKey {
        case id, slug, name
        case startsAt = "starts_at"
        case spaceName = "space_name"
    }
}

/// `POST /api/app/meetings`: 201 `{id, slug, path}`.
struct CreatedMeeting: Decodable, Equatable {
    let id: String
    let slug: String
}

struct SuiteAgent: Decodable, Equatable {
    let id: String
    let name: String
    let slug: String?
    let role: String?
}

/// `POST /api/app/agents/:id/dm`: the DM's space id and `path_segment`.
struct AgentDM: Decodable, Equatable {
    let spaceID: String
    let pathSegment: String?

    private enum CodingKeys: String, CodingKey {
        case spaceID = "space_id"
        case pathSegment = "path_segment"
    }
}

/// One message from `GET /api/app/spaces/:id/messages?after=`.
struct SuiteMessage: Decodable, Equatable {
    let id: String
    let authorType: String?
    let authorID: String?
    let authorName: String?
    let content: String?

    private enum CodingKeys: String, CodingKey {
        case id, content
        case authorType = "author_type"
        case authorID = "author_id"
        case authorName = "author_name"
    }
}

/// Async forms of the App Intents routes. Every request is built by
/// `authorizedRequest` for the host it names, at the moment it is sent.
extension SuiteAPIClient {
    struct Response {
        let status: Int
        let data: Data

        var isSuccess: Bool { (200..<300).contains(status) }

        /// The `{"error": code}` a refusal carries, if any.
        var errorCode: String? {
            (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        }
    }

    /// One bearer request; returns whatever status came back.
    func send(host: String, path: String, method: String = "GET", json: [String: Any]? = nil) async throws -> Response {
        var request = try authorizedRequest(host: host, path: path)
        request.httpMethod = method
        request.timeoutInterval = 20
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await session.data(for: request)
        return Response(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }

    /// `send`, requiring a 2xx and decoding the body as `T`.
    func fetch<T: Decodable>(_ type: T.Type, host: String, path: String, method: String = "GET", json: [String: Any]? = nil) async throws -> T {
        let response = try await send(host: host, path: path, method: method, json: json)
        guard response.isSuccess else { throw Failure.refused(status: response.status, code: response.errorCode) }
        do {
            return try JSONDecoder().decode(T.self, from: response.data)
        } catch {
            throw Failure.badResponse
        }
    }

    func approvals(host: String) async throws -> [SuiteApproval] {
        struct Body: Decodable { let approvals: [SuiteApproval] }
        return try await fetch(Body.self, host: host, path: "/api/app/approvals").approvals
    }

    func approve(host: String, approvalID: String) async throws -> ApprovalOutcome {
        try await settle(host: host, path: "/api/app/approvals/\(Self.segment(approvalID))/approve", json: [:])
    }

    func reject(host: String, approvalID: String, feedback: String?) async throws -> ApprovalOutcome {
        var json: [String: Any] = [:]
        if let feedback { json["feedback"] = feedback }
        return try await settle(host: host, path: "/api/app/approvals/\(Self.segment(approvalID))/reject", json: json)
    }

    private func settle(host: String, path: String, json: [String: Any]) async throws -> ApprovalOutcome {
        let response = try await send(host: host, path: path, method: "POST", json: json)
        if response.status == 409 {
            let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            return .alreadyHandled(by: object?["by"] as? String)
        }
        guard response.isSuccess else { throw Failure.refused(status: response.status, code: response.errorCode) }
        let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        return .done(object?["status"] as? String ?? "")
    }

    func tasks(host: String, query: String? = nil, limit: Int? = nil) async throws -> [SuiteTask] {
        struct Body: Decodable { let tasks: [SuiteTask] }
        var components = URLComponents()
        components.path = "/api/app/tasks"
        var items: [URLQueryItem] = []
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        components.queryItems = items.isEmpty ? nil : items
        return try await fetch(Body.self, host: host, path: components.string ?? "/api/app/tasks").tasks
    }

    func meetings(host: String) async throws -> [SuiteMeeting] {
        struct Body: Decodable { let meetings: [SuiteMeeting] }
        return try await fetch(Body.self, host: host, path: "/api/app/meetings").meetings
    }

    /// Starts a meeting now. `spaceID` only picks the project; the server
    /// answers 422 `no_project` when the person has no project to hold it.
    func createMeeting(host: String, spaceID: String?) async throws -> CreatedMeeting {
        var json: [String: Any] = [:]
        if let spaceID { json["space_id"] = spaceID }
        return try await fetch(CreatedMeeting.self, host: host, path: "/api/app/meetings", method: "POST", json: json)
    }

    func agents(host: String) async throws -> [SuiteAgent] {
        struct Body: Decodable { let agents: [SuiteAgent] }
        return try await fetch(Body.self, host: host, path: "/api/app/agents").agents
    }

    func dmWithAgent(host: String, agentID: String) async throws -> AgentDM {
        try await fetch(AgentDM.self, host: host, path: "/api/app/agents/\(Self.segment(agentID))/dm", method: "POST", json: [:])
    }

    func messagesAfter(host: String, spaceID: String, after: String?) async throws -> [SuiteMessage] {
        struct Body: Decodable { let messages: [SuiteMessage] }
        var path = Self.messagesPath(spaceID)
        if let after { path += "?after=\(Self.segment(after))" }
        return try await fetch(Body.self, host: host, path: path).messages
    }

    func spaces(host: String) async throws -> [SuiteSpace] {
        try await withCheckedThrowingContinuation { continuation in
            spaces(host: host) { continuation.resume(with: $0) }
        }
    }

    /// A text-only message, through the same multipart route the share
    /// sheet uses. Returns the posted message's id.
    func sendText(host: String, spaceID: String, text: String) async throws -> String {
        struct Body: Decodable {
            struct Message: Decodable { let id: String }
            let message: Message
        }
        let form = MultipartForm(fields: [(name: "text", value: text)])
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            upload(host: host, spaceID: spaceID, form: form) { continuation.resume(with: $0) }
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw Failure.badResponse }
        return body.message.id
    }
}
