import XCTest
@testable import App

final class MultipartFormTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("MultipartFormTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String, _ bytes: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    /// Writes the form and returns the body, after checking the length
    /// `contentLength()` predicted is the length written.
    private func body(_ form: MultipartForm) throws -> Data {
        let out = dir.appendingPathComponent("body-\(UUID().uuidString)")
        try form.write(to: out, chunkSize: 7)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(Int64(data.count), try form.contentLength(), "contentLength must match the bytes written")
        return data
    }

    private func part(_ name: String, _ value: String, boundary: String) -> Data {
        Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
    }

    func testImage() throws {
        // Not valid UTF-8, so a builder that round-trips the file through a
        // String would corrupt it.
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x80, 0x81, 0xFE]) + Data(repeating: 0xAB, count: 100)
        let url = try file("Photo.jpg", bytes)
        let payload = SharePayload.image(.init(filename: "Photo.jpg", mimeType: "image/jpeg", url: url))
        let form = payload.form(message: "  the banner ", agentID: "agent-1", boundary: "B")

        var expected = part("text", "the banner", boundary: "B")
        expected += part("agent_id", "agent-1", boundary: "B")
        expected += Data("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"Photo.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        expected += bytes
        expected += Data("\r\n--B--\r\n".utf8)
        XCTAssertEqual(try body(form), expected)
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=B")
    }

    func testPDFWithNoMessageSendsOnlyTheFile() throws {
        let bytes = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\n1 0 obj".utf8)
        let url = try file("Q3 board deck.pdf", bytes)
        let payload = SharePayload.pdf(.init(filename: "Q3 board deck.pdf", mimeType: "application/pdf", url: url))
        let form = payload.form(message: "", agentID: nil, boundary: "B")

        var expected = Data("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"Q3 board deck.pdf\"\r\nContent-Type: application/pdf\r\n\r\n".utf8)
        expected += bytes
        expected += Data("\r\n--B--\r\n".utf8)
        XCTAssertEqual(try body(form), expected)
        XCTAssertNil(form.value(of: "text"))
        XCTAssertNil(form.value(of: "agent_id"))
    }

    func testURLGoesInTheTextAfterTheMessage() throws {
        let payload = SharePayload.url(URL(string: "https://example.com/a?b=c")!)
        let form = payload.form(message: "worth a read", agentID: nil, boundary: "B")
        XCTAssertNil(form.file)
        XCTAssertEqual(form.value(of: "text"), "worth a read\nhttps://example.com/a?b=c")
        XCTAssertEqual(try body(form), part("text", "worth a read\nhttps://example.com/a?b=c", boundary: "B") + Data("--B--\r\n".utf8))

        XCTAssertEqual(payload.form(message: " ", agentID: nil).value(of: "text"), "https://example.com/a?b=c",
                       "no message: just the URL")
    }

    func testTextKeepsUnicodeAndAddsTheAgent() throws {
        let payload = SharePayload.text("Café — naïve 日本")
        let form = payload.form(message: "", agentID: "agent-9", boundary: "B")
        XCTAssertEqual(try body(form),
                       part("text", "Café — naïve 日本", boundary: "B") + part("agent_id", "agent-9", boundary: "B") + Data("--B--\r\n".utf8))
    }

    func testFilenameQuotesCannotBreakTheHeader() throws {
        let url = try file("x.pdf", Data("x".utf8))
        let payload = SharePayload.pdf(.init(filename: "a\"b\r\nc.pdf", mimeType: "application/pdf", url: url))
        let text = String(decoding: try body(payload.form(message: "", agentID: nil, boundary: "B")), as: UTF8.self)
        XCTAssertTrue(text.contains("filename=\"a%22b%0D%0Ac.pdf\""), text)
    }

    /// The server's multipart parser takes 8_000_000 bytes for the whole
    /// body. One byte over is refused by the client before any request.
    func testBodyOverEightMegabytesIsRefusedBeforeAnyRequest() throws {
        let url = dir.appendingPathComponent("big.pdf")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let header = MultipartForm(boundary: "B", file: .init(filename: "big.pdf", mimeType: "application/pdf", url: url))
        try handle.truncate(atOffset: 0)
        try handle.close()
        let overhead = try header.contentLength()
        let fileBytes = BurrowAPIClient.maxRequestBytes - overhead + 1
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: UInt64(fileBytes))
        try writer.close()
        XCTAssertEqual(try header.contentLength(), BurrowAPIClient.maxRequestBytes + 1)

        StubURLProtocol.reset()
        let client = BurrowAPIClient(session: StubURLProtocol.session(), tokens: MemoryTokenStore(tokens: ["a.example.com": "tok-a"]))
        let done = expectation(description: "send")
        client.sendMessage(host: "a.example.com", spaceID: "s1", form: header) { result in
            guard case .failure(BurrowAPIClient.Failure.tooLarge(let bytes)) = result else {
                return XCTFail("expected tooLarge, got \(result)")
            }
            XCTAssertEqual(bytes, BurrowAPIClient.maxRequestBytes + 1)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
        XCTAssertEqual(ShareSheetModel.Banner.tooLarge(bytes: 9_400_000).text,
                       "This item is 9.4 MB. Burrow takes up to 8 MB from the share sheet.")
    }
}
