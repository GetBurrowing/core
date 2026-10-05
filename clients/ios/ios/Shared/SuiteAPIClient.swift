import Foundation

/// A space the person can post into, from `GET /api/app/spaces`, with the
/// agents participating in it (the share sheet's optional agent row).
struct SuiteSpace: Decodable, Equatable, Identifiable {
    struct Agent: Decodable, Equatable, Identifiable {
        let id: String
        let name: String
        let slug: String?
    }

    let id: String
    let name: String
    let slug: String?
    let kind: String?
    let agents: [Agent]
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
            completion(result.flatMap { data in
                Result { try JSONDecoder().decode(Body.self, from: data).spaces }
                    .mapError { _ in Failure.badResponse }
            })
        }
    }

    func counts(host: String, now: @escaping () -> Date = Date.init,
                completion: @escaping (Result<SuiteCounts, Error>) -> Void) {
        struct Body: Decodable { let approvals: Int; let tasks: Int }
        get(host: host, path: "/api/app/counts") { result in
            completion(result.flatMap { data in
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
            run(session.dataTask(with: request) { data, response, error in
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
            completion(result.flatMap { data in
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let url = (object["handoff_url"] as? String).flatMap(URL.init(string:)),
                      url.host?.lowercased() == host.lowercased() else {
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
            run(session.dataTask(with: request) { data, response, error in
                completion(Self.check(data, response, error).map { _ in () })
            })
        } catch {
            completion(.failure(error))
        }
    }

    /// `POST /api/app/spaces/:space_id/messages` as multipart. The body is
    /// written to a file first and uploaded from it, so a large attachment
    /// is streamed from disk and never held in the extension's memory.
    func sendMessage(host: String, spaceID: String, form: MultipartForm,
                     completion: @escaping (Result<Void, Error>) -> Void) {
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
            run(session.uploadTask(with: request, fromFile: bodyURL) { data, response, error in
                try? FileManager.default.removeItem(at: bodyURL)
                completion(Self.check(data, response, error).map { _ in () })
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

    private static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? value
    }

    // MARK: Plumbing

    private func get(host: String, path: String, completion: @escaping (Result<Data, Error>) -> Void) {
        do {
            var request = try authorizedRequest(host: host, path: path)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            run(session.dataTask(with: request) { data, response, error in
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
