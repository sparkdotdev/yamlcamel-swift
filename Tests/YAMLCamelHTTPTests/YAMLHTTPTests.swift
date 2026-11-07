import Foundation
import Testing
@testable import YAMLCamelHTTP
import YAMLCamel
import YAMLCamelGzip

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct Word: Codable, Equatable {
    var hu: String
    var en: String
}

/// Builds a response without a network, so the rules that decide an exchange can be tested on both
/// platforms with nothing running.
private func response(status: Int = 200,
                      contentType: String? = "application/yaml",
                      contentEncoding: String? = nil,
                      body: Data = Data()) -> YAMLTransportResponse {
    var headers: [String: String] = [:]
    if let contentType = contentType { headers["Content-Type"] = contentType }
    if let contentEncoding = contentEncoding { headers["Content-Encoding"] = contentEncoding }
    let http = HTTPURLResponse(url: URL(string: "https://example.invalid/words.yaml")!,
                               statusCode: status,
                               httpVersion: "HTTP/1.1",
                               headerFields: headers)!
    return YAMLTransportResponse(http, body: body)
}

private let sampleYAML = "- hu: ház\n  en: house\n- hu: kutya\n  en: dog\n"
private let sampleWords = [Word(hu: "ház", en: "house"), Word(hu: "kutya", en: "dog")]

/// Answers every send with what a test hands it and records the request, so `YAMLHTTPClient` can be
/// exercised without a network.
private final class MockTransport: YAMLTransport, @unchecked Sendable {
    private(set) var requests: [YAMLTransportRequest] = []
    private(set) var maxResponseBytesSeen: [Int] = []
    private let respond: @Sendable (YAMLTransportRequest) throws -> YAMLTransportResponse

    init(respond: @escaping @Sendable (YAMLTransportRequest) throws -> YAMLTransportResponse) {
        self.respond = respond
    }

    func send(_ request: YAMLTransportRequest, maxResponseBytes: Int) async throws -> YAMLTransportResponse {
        requests.append(request)
        maxResponseBytesSeen.append(maxResponseBytes)
        return try respond(request)
    }
}

/// Delegates to the real `Gzip` calls while counting every one, so a test can prove a
/// `compression:` argument is actually used rather than the default.
private final class RecordingCompression: YAMLCompression, @unchecked Sendable {
    private(set) var compressCalls = 0
    private(set) var decompressCalls = 0

    func compress(_ data: Data, level: Gzip.Level) throws -> Data {
        compressCalls += 1
        return try Gzip.compress(data, level: level)
    }

    func decompress(_ data: Data, limits: GzipLimits) throws -> Data {
        decompressCalls += 1
        return try Gzip.decompress(data, limits: limits)
    }
}

@Suite("YAML over HTTP")
struct YAMLHTTPTests {

    // MARK: - Request building

    @Test("a YAML request asks for and accepts YAML")
    func requestHeaders() throws {
        let request = URLRequest(yaml: URL(string: "https://example.invalid/words.yaml")!)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/yaml")
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "gzip")
        #expect(request.httpMethod == "GET")
    }

    @Test("a request can decline gzip, which keeps the body as it was sent")
    func requestDecliningGzip() throws {
        let request = URLRequest(yaml: URL(string: "https://example.invalid/w")!, acceptsGzip: false)
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
    }

    @Test("a YAML body is encoded and typed")
    func requestBody() throws {
        var request = URLRequest(yaml: URL(string: "https://example.invalid/w")!, method: "POST")
        try request.setYAMLBody(sampleWords)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/yaml")
        #expect(request.value(forHTTPHeaderField: "Content-Encoding") == nil)
        let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(try YAMLDecoder().decode([Word].self, from: text) == sampleWords)
    }

    @Test("compression is a choice rather than a default, and is announced when taken")
    func compressedRequestBody() throws {
        var plain = URLRequest(yaml: URL(string: "https://example.invalid/w")!, method: "POST")
        try plain.setYAMLBody(sampleWords)
        #expect(plain.value(forHTTPHeaderField: "Content-Encoding") == nil)

        var compressed = URLRequest(yaml: URL(string: "https://example.invalid/w")!, method: "POST")
        try compressed.setYAMLBody(sampleWords, compressed: true)
        #expect(compressed.value(forHTTPHeaderField: "Content-Encoding") == "gzip")
        #expect(Gzip.hasGzipMagic(compressed.httpBody!))

        let inflated = try Gzip.decompress(compressed.httpBody!)
        #expect(inflated == plain.httpBody)
    }

    // MARK: - Response handling

    @Test("a plain YAML response decodes")
    func plainResponse() throws {
        let decoded = try YAMLHTTPResponse.decode([Word].self,
                                                  body: Data(sampleYAML.utf8),
                                                  response: response())
        #expect(decoded == sampleWords)
    }

    @Test("a gzipped response decodes")
    func gzippedResponse() throws {
        let body = try Gzip.compress(Data(sampleYAML.utf8))
        let decoded = try YAMLHTTPResponse.decode([Word].self,
                                                  body: body,
                                                  response: response(contentEncoding: "gzip"))
        #expect(decoded == sampleWords)
    }

    @Test("a server that ignores Accept-Encoding and answers uncompressed still decodes")
    func serverIgnoredAcceptEncoding() throws {
        // The header claims gzip and the bytes are plain, which is what a proxy that already
        // inflated the body leaves behind.
        let decoded = try YAMLHTTPResponse.decode([Word].self,
                                                  body: Data(sampleYAML.utf8),
                                                  response: response(contentEncoding: "gzip"))
        #expect(decoded == sampleWords)
    }

    @Test("every spelling of the YAML media type is accepted",
          arguments: ["application/yaml", "text/yaml", "application/x-yaml", "text/x-yaml",
                      "application/yaml; charset=utf-8", "APPLICATION/YAML"])
    func acceptedMediaTypes(contentType: String) throws {
        let decoded = try YAMLHTTPResponse.decode([Word].self,
                                                  body: Data(sampleYAML.utf8),
                                                  response: response(contentType: contentType))
        #expect(decoded == sampleWords)
    }

    @Test("a response that is not YAML is refused rather than parsed",
          arguments: ["application/json", "text/html", "application/octet-stream"])
    func wrongContentType(contentType: String) throws {
        #expect(throws: YAMLHTTPError.self) {
            try YAMLHTTPResponse.decode([Word].self,
                                        body: Data(sampleYAML.utf8),
                                        response: response(contentType: contentType))
        }
    }

    @Test("a response with no content type at all is refused")
    func missingContentType() throws {
        #expect(throws: YAMLHTTPError.self) {
            try YAMLHTTPResponse.decode([Word].self,
                                        body: Data(sampleYAML.utf8),
                                        response: response(contentType: nil))
        }
    }

    @Test("a failing status carries its code and body")
    func failingStatus() throws {
        do {
            _ = try YAMLHTTPResponse.decode([Word].self,
                                            body: Data("nope".utf8),
                                            response: response(status: 503))
            Issue.record("a 503 should not decode")
        } catch let error as YAMLHTTPError {
            guard case .status(let code, let body) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(code == 503)
            #expect(body == Data("nope".utf8))
        }
    }

    @Test("an encoding this module does not handle is named rather than guessed at")
    func unsupportedEncoding() throws {
        do {
            _ = try YAMLHTTPResponse.decode([Word].self,
                                            body: Data(sampleYAML.utf8),
                                            response: response(contentEncoding: "br"))
            Issue.record("brotli should not be accepted")
        } catch let error as YAMLHTTPError {
            guard case .unsupportedContentEncoding(let name) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(name == "br")
        }
    }

    // MARK: - Bounds

    @Test("a body over the response bound is refused before anything is inflated or parsed")
    func responseTooLarge() throws {
        var limits = YAMLHTTPLimits.default
        limits.maxResponseBytes = 10
        #expect(throws: YAMLHTTPError.self) {
            try YAMLHTTPResponse.decode([Word].self,
                                        body: Data(sampleYAML.utf8),
                                        response: response(),
                                        limits: limits)
        }
    }

    @Test("decode(_:body:response:) does not mutate a decoder the caller passed in")
    func decodeDoesNotMutateSharedDecoder() throws {
        // A decoder held by the caller, and reused across calls the way a long-lived YAMLHTTPClient
        // naturally would be. Two concurrent calls sharing one decoder must not race over its
        // limits: the only way to guarantee that is for neither call to ever write to it.
        let shared = YAMLDecoder()
        let before = shared.limits

        var limits = YAMLHTTPLimits.default
        limits.yaml.maxScalarLength = 1
        _ = try? YAMLHTTPResponse.decode([Word].self,
                                         body: Data(sampleYAML.utf8),
                                         response: response(),
                                         limits: limits,
                                         decoder: shared)

        #expect(shared.limits == before, "decode(_:body:response:) must not overwrite a shared decoder's limits")
    }

    @Test("a decompression bomb stops at the gzip bound rather than being inflated whole")
    func decompressionBomb() throws {
        let bomb = try Gzip.compress(Data(repeating: 0x41, count: 128 << 20), level: .best)
        var limits = YAMLHTTPLimits.default
        limits.gzip = GzipLimits(maxOutputBytes: 1 << 20)

        var caught: GzipError?
        do {
            _ = try YAMLHTTPResponse.decode([Word].self,
                                            body: bomb,
                                            response: response(contentEncoding: "gzip"),
                                            limits: limits)
        } catch let error as GzipError {
            caught = error
        }
        #expect(caught?.kind == .outputTooLarge)
    }

    @Test("a compression that ignores its own limits is still held to the gzip bound")
    func customCompressionIgnoringLimitsIsStillBounded() throws {
        // `compression:` is swappable so a caller can route inflation through its own layer, and
        // this module's own `GzipCompression` keeps to the bound it is handed while it inflates. A
        // substitute that does not, whether buggy or just careless about `limits`, used to have its
        // result trusted completely: whatever `Data` it handed back was turned into a `String` and
        // returned as the response body with nothing checked against `limits.gzip` at all.
        struct IgnoresLimits: YAMLCompression {
            func compress(_ data: Data, level: Gzip.Level) throws -> Data { data }
            func decompress(_ data: Data, limits: GzipLimits) throws -> Data {
                Data(repeating: 0x61, count: 8 << 20)
            }
        }
        let tinyBody = try Gzip.compress(Data("a: 1\n".utf8))
        var limits = YAMLHTTPLimits.default
        limits.gzip = GzipLimits(maxOutputBytes: 1 << 20)

        var caught: GzipError?
        do {
            _ = try YAMLHTTPResponse.yamlText(body: tinyBody,
                                              response: response(contentEncoding: "gzip"),
                                              limits: limits,
                                              compression: IgnoresLimits())
        } catch let error as GzipError {
            caught = error
        }
        #expect(caught?.kind == .outputTooLarge)
    }

    @Test("a body that inflates cleanly still has to pass the parser's bounds")
    func yamlBoundsApplyAfterInflating() throws {
        let deep = "k: " + String(repeating: "[", count: 4_000) + String(repeating: "]", count: 4_000)
        let body = try Gzip.compress(Data(deep.utf8))
        var caught: YAMLParseError?
        do {
            _ = try YAMLHTTPResponse.decode([Word].self,
                                            body: body,
                                            response: response(contentEncoding: "gzip"))
        } catch let error as YAMLParseError {
            caught = error
        }
        #expect(caught?.kind == .depthExceeded)
    }

    @Test("a gzipped body that is truncated is reported rather than decoded short")
    func truncatedGzipBody() throws {
        let whole = try Gzip.compress(Data(sampleYAML.utf8))
        var caught: GzipError?
        do {
            _ = try YAMLHTTPResponse.decode([Word].self,
                                            body: Data(whole.prefix(whole.count - 4)),
                                            response: response(contentEncoding: "gzip"))
        } catch let error as GzipError {
            caught = error
        }
        #expect(caught?.kind == .truncated || caught?.kind == .corrupt)
    }

    @Test("a body claiming gzip whose bytes are corrupt gzip is reported as corrupt")
    func corruptGzipBody() throws {
        var body = try Gzip.compress(Data(sampleYAML.utf8))
        for offset in 12 ..< 20 { body[body.startIndex + offset] ^= 0xAA }
        var caught: GzipError?
        do {
            _ = try YAMLHTTPResponse.decode([Word].self,
                                            body: body,
                                            response: response(contentEncoding: "gzip"))
        } catch let error as GzipError {
            caught = error
        }
        #expect(caught != nil)
    }

    @Test("a YAML body that does not match the type gives a decoding error")
    func wrongShape() throws {
        #expect(throws: DecodingError.self) {
            try YAMLHTTPResponse.decode([Word].self,
                                        body: Data("hu: ház\nen: house\n".utf8),
                                        response: response())
        }
    }

    @Test("a body that is not YAML at all gives a parse error")
    func notYAML() throws {
        #expect(throws: Error.self) {
            try YAMLHTTPResponse.decode([Word].self,
                                        body: Data("a: [1, 2\n".utf8),
                                        response: response())
        }
    }

    @Test("arbitrary bytes announced as YAML never crash the response handler")
    func arbitraryBodies() throws {
        var state: UInt64 = 0x243F_6A88_85A3_08D3
        func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
        for _ in 0 ..< 3_000 {
            var body = Data()
            for _ in 0 ..< 120 { body.append(next()) }
            let gzipped = next() % 2 == 0
            do {
                _ = try YAMLHTTPResponse.decode([Word].self,
                                                body: body,
                                                response: response(contentEncoding: gzipped ? "gzip" : nil))
            } catch is YAMLHTTPError {
            } catch is GzipError {
            } catch is YAMLParseError {
            } catch is DecodingError {
            } catch {
                Issue.record("unexpected error type \(type(of: error)): \(error)")
                return
            }
        }
    }

    // MARK: - Round trip through the header rules

    @Test("what a request writes, the response handler reads back")
    func requestAndResponseAgree() throws {
        for compressed in [false, true] {
            var request = URLRequest(yaml: URL(string: "https://example.invalid/w")!, method: "POST")
            try request.setYAMLBody(sampleWords, compressed: compressed)
            let decoded = try YAMLHTTPResponse.decode(
                [Word].self,
                body: request.httpBody!,
                response: response(contentType: request.value(forHTTPHeaderField: "Content-Type"),
                                   contentEncoding: request.value(forHTTPHeaderField: "Content-Encoding")))
            #expect(decoded == sampleWords)
        }
    }
}

@Suite("YAMLHTTPClient")
struct YAMLHTTPClientTests {

    private let url = URL(string: "https://example.invalid/words.yaml")!

    @Test("get(_:from:) decodes a plain response through the injected transport")
    func getPlainSucceeds() async throws {
        let transport = MockTransport { _ in response(body: Data(sampleYAML.utf8)) }
        let client = YAMLHTTPClient(transport: transport)
        let decoded = try await client.get([Word].self, from: url)
        #expect(decoded == sampleWords)
        #expect(transport.requests.first?.headers["Accept"] == YAMLMediaType.canonical)
    }

    @Test("get(_:from:) decodes a gzipped response through the injected transport")
    func getGzipSucceeds() async throws {
        let compressed = try Gzip.compress(Data(sampleYAML.utf8))
        let transport = MockTransport { _ in response(contentEncoding: "gzip", body: compressed) }
        let client = YAMLHTTPClient(transport: transport)
        let decoded = try await client.get([Word].self, from: url)
        #expect(decoded == sampleWords)
    }

    @Test("get(_:from:) surfaces a failing status rather than decoding")
    func getFailingStatus() async throws {
        let transport = MockTransport { _ in response(status: 404, body: Data("not found".utf8)) }
        let client = YAMLHTTPClient(transport: transport)
        do {
            _ = try await client.get([Word].self, from: url)
            Issue.record("a 404 should not decode")
        } catch let error as YAMLHTTPError {
            guard case .status(let code, _) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(code == 404)
        }
    }

    @Test("post(_:to:expecting:) sends a plain body and decodes a plain response")
    func postPlainSucceeds() async throws {
        let transport = MockTransport { _ in response(body: Data(sampleYAML.utf8)) }
        let client = YAMLHTTPClient(transport: transport)
        let decoded = try await client.post(sampleWords, to: url, expecting: [Word].self)
        #expect(decoded == sampleWords)
        let sent = transport.requests.first
        #expect(sent?.headers["Content-Encoding"] == nil)
        #expect(try await YAMLDecoder().decode([Word].self, from: sent?.body ?? Data()) == sampleWords)
    }

    @Test("post(_:to:expecting:compressBody:) compresses the body it sends")
    func postGzipSucceeds() async throws {
        let transport = MockTransport { _ in response(body: Data(sampleYAML.utf8)) }
        let client = YAMLHTTPClient(transport: transport)
        _ = try await client.post(sampleWords, to: url, expecting: [Word].self, compressBody: true)
        let sent = transport.requests.first
        #expect(sent?.headers["Content-Encoding"] == "gzip")
        let inflated = try Gzip.decompress(sent?.body ?? Data())
        #expect(try await YAMLDecoder().decode([Word].self, from: inflated) == sampleWords)
    }

    @Test("the status-only post(_:to:) sends the body and ignores the response body")
    func postStatusOnlySucceeds() async throws {
        let transport = MockTransport { _ in response(body: Data()) }
        let client = YAMLHTTPClient(transport: transport)
        try await client.post(sampleWords, to: url)
        #expect(transport.requests.count == 1)
    }

    @Test("the status-only post(_:to:) throws on a failing status")
    func postStatusOnlyFails() async throws {
        let transport = MockTransport { _ in response(status: 500, body: Data("nope".utf8)) }
        let client = YAMLHTTPClient(transport: transport)
        do {
            try await client.post(sampleWords, to: url)
            Issue.record("a 500 should throw")
        } catch let error as YAMLHTTPError {
            guard case .status(let code, _) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(code == 500)
        }
    }

    @Test("getSequence(_:from:) streams a plain top-level sequence")
    func getSequenceDecodesPlainBody() async throws {
        let transport = MockTransport { _ in response(body: Data(sampleYAML.utf8)) }
        let client = YAMLHTTPClient(transport: transport)
        let decoded = try await client.getSequence(Word.self, from: url)
        #expect(decoded == sampleWords)
    }

    @Test("getSequence(_:from:) streams a gzipped top-level sequence")
    func getSequenceDecodesGzipBody() async throws {
        let compressed = try Gzip.compress(Data(sampleYAML.utf8))
        let transport = MockTransport { _ in response(contentEncoding: "gzip", body: compressed) }
        let client = YAMLHTTPClient(transport: transport)
        let decoded = try await client.getSequence(Word.self, from: url)
        #expect(decoded == sampleWords)
    }

    @Test("a custom transport and compression pair is used instead of the defaults")
    func customTransportAndCompressionAreUsed() async throws {
        let compression = RecordingCompression()
        let responseBody = try Gzip.compress(Data(sampleYAML.utf8))
        let transport = MockTransport { _ in response(contentEncoding: "gzip", body: responseBody) }
        let client = YAMLHTTPClient(transport: transport, compression: compression)

        let decoded = try await client.post(sampleWords, to: url, expecting: [Word].self, compressBody: true)
        #expect(decoded == sampleWords)
        #expect(transport.requests.first?.headers["Content-Encoding"] == "gzip")
        // One compress call building the outgoing body, one decompress call reading the response.
        #expect(compression.compressCalls == 1)
        #expect(compression.decompressCalls == 1)
    }
}
