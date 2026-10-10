import Foundation

/// `GET /api/app/upload_config` (task 01a120be): the install's limits. The
/// share sheet never holds the per-file limit as a constant; it reads it
/// here, so lowering `CHAT_MAX_UPLOAD_BYTES` on an install changes the
/// sheet's decision without a client build.
struct UploadConfig: Decodable, Equatable {
    /// The largest file one upload may carry on this install.
    let maxUploadBytes: Int64
    /// `maxUploadBytes` as the server words it ("1 GB").
    let maxUploadLabel: String
    /// The largest body one chunked PATCH may carry.
    let chunkBytes: Int64
    /// The largest multipart request body the server's parser accepts
    /// (Plug.Parsers' 8_000_000). At or under it the sheet keeps today's
    /// multipart `POST /api/app/spaces/:id/messages`.
    let multipartMaxBytes: Int64

    private enum CodingKeys: String, CodingKey {
        case maxUploadBytes = "max_upload_bytes"
        case maxUploadLabel = "max_upload_label"
        case chunkBytes = "chunk_bytes"
        case multipartMaxBytes = "multipart_max_bytes"
    }
}

/// `POST /api/app/spaces/:space_id/uploads`: a reserved chunked upload. The
/// server posts the message itself when the last chunk lands, so nothing
/// needs to happen after the upload but a notification.
struct UploadReservation: Decodable, Equatable {
    let id: String
    /// A path on the install (`/chat/attachments/upload/<token>`); the token
    /// is the only auth, so the PATCHes carry no bearer.
    let uploadURL: String
    let chunkBytes: Int64
    let offset: Int64

    private enum CodingKeys: String, CodingKey {
        case id, offset
        case uploadURL = "upload_url"
        case chunkBytes = "chunk_bytes"
    }
}

/// Which way a shared file goes.
enum ShareRoute: Equatable {
    /// Today's single multipart POST.
    case multipart
    /// Reserve, then PATCH chunks on a background URLSession.
    case chunked
    /// Over the install's limit: refused before any byte moves.
    case tooLarge(name: String, bytes: Int64, label: String)

    /// Routes on the multipart REQUEST size, not the file size: the
    /// server's parser limit counts the whole body (Plug.Parsers.MULTIPART
    /// `:length`), so a file just under 8_000_000 bytes whose body is just
    /// over it would be refused with a 413.
    static func decide(fileName: String, fileBytes: Int64, multipartBodyBytes: Int64, config: UploadConfig) -> ShareRoute {
        if fileBytes > config.maxUploadBytes {
            return .tooLarge(name: fileName, bytes: fileBytes, label: config.maxUploadLabel)
        }
        return multipartBodyBytes <= config.multipartMaxBytes ? .multipart : .chunked
    }

    /// "<name> is 1.2 GB. This Suite accepts files up to 1 GB." (design
    /// canvas 01a120be-f336, "TOO LARGE").
    static func tooLargeText(name: String, bytes: Int64, label: String) -> String {
        "\(name) is \(ByteLabel.format(bytes)). This Suite accepts files up to \(label)."
    }
}

/// The one size-label rule every Suite surface uses (task 01a120be):
/// decimal units only, so "MB" always means 1_000_000 bytes.
///
/// Below 1000 it is "<n> bytes". Otherwise the largest unit in KB, MB, GB,
/// TB that the count reaches, one decimal rounded half up, promoted to the
/// next unit when that rounds to 1000 ("1 GB", not "1000 MB"), with no
/// trailing ".0". Integer arithmetic only, so no binary-float rounding
/// error moves a half-up boundary.
enum ByteLabel {
    private static let units = ["bytes", "KB", "MB", "GB", "TB"]

    private static func scale(_ k: Int) -> Int64 {
        (0..<k).reduce(Int64(1)) { acc, _ in acc * 1000 }
    }

    /// `bytes / 1000^k` in tenths, rounded half up.
    private static func tenths(_ bytes: Int64, _ k: Int) -> Int64 {
        let step = scale(k) / 10
        return (bytes + step / 2) / step
    }

    /// The unit index `total` reads in.
    private static func unit(for bytes: Int64) -> Int {
        guard bytes >= 1000 else { return 0 }
        var k = 1
        while k < 4 && bytes >= scale(k + 1) { k += 1 }
        if k < 4 && tenths(bytes, k) >= 10_000 { k += 1 }
        return k
    }

    private static func number(_ bytes: Int64, _ k: Int) -> String {
        if k == 0 { return String(bytes) }
        let t = tenths(bytes, k)
        return t % 10 == 0 ? String(t / 10) : "\(t / 10).\(t % 10)"
    }

    static func format(_ bytes: Int64) -> String {
        let k = unit(for: bytes)
        return "\(number(bytes, k)) \(units[k])"
    }

    /// "<sent> of <total> <unit>", the unit chosen by `total` and `sent`
    /// clamped to `total`: "412 of 900 MB".
    static func progress(sent: Int64, total: Int64) -> String {
        let k = unit(for: total)
        return "\(number(min(max(sent, 0), total), k)) of \(number(total, k)) \(units[k])"
    }
}

extension SuiteAPIClient {
    static let uploadConfigPath = "/api/app/upload_config"

    static func uploadsPath(_ spaceID: String) -> String {
        "/api/app/spaces/\(segment(spaceID))/uploads"
    }

    /// `GET /api/app/upload_config`.
    func uploadConfig(host: String, completion: @escaping (Result<UploadConfig, Error>) -> Void) {
        do {
            var request = try authorizedRequest(host: host, path: Self.uploadConfigPath)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            session.dataTask(with: request) { data, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let error { return completion(.failure(error)) }
                guard (200..<300).contains(status), let data else { return completion(.failure(Failure.status(status))) }
                completion(Result { try JSONDecoder().decode(UploadConfig.self, from: data) }.mapError { _ in Failure.badResponse })
            }.resume()
        } catch {
            completion(.failure(error))
        }
    }

    /// `POST /api/app/spaces/:space_id/uploads`. A refusal keeps the
    /// server's `{"error": code}` (`file_too_large` on 413).
    func reserveUpload(
        host: String, spaceID: String, filename: String, contentType: String, byteSize: Int64,
        text: String?, agentID: String?,
        completion: @escaping (Result<UploadReservation, Error>) -> Void
    ) {
        var json: [String: Any] = ["filename": filename, "content_type": contentType, "byte_size": byteSize]
        if let text, !text.isEmpty { json["text"] = text }
        if let agentID, !agentID.isEmpty { json["agent_id"] = agentID }
        do {
            var request = try authorizedRequest(host: host, path: Self.uploadsPath(spaceID))
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            session.dataTask(with: request) { data, response, error in
                if let error { return completion(.failure(error)) }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = data ?? Data()
                guard (200..<300).contains(status) else {
                    let code = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
                    return completion(.failure(Failure.refused(status: status, code: code)))
                }
                completion(Result { try JSONDecoder().decode(UploadReservation.self, from: body) }.mapError { _ in Failure.badResponse })
            }.resume()
        } catch {
            completion(.failure(error))
        }
    }
}
