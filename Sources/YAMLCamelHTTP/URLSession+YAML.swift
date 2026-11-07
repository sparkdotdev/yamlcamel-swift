import Foundation
import YAMLCamel
import YAMLCamelGzip

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension URLSession {

    /// Sends a request and decodes a YAML response. Pass the type to decode, the request, and
    /// optionally your own limits and decoder. Returns the decoded value.
    ///
    /// Throws `YAMLHTTPError` for a non-YAML or failing response, `GzipError` for a body that does
    /// not inflate or inflates past the bound, `YAMLParseError` for a body that is not valid YAML,
    /// and `DecodingError` when the document does not match the type.
    func yaml<T: Decodable>(_ type: T.Type,
                            for request: URLRequest,
                            limits: YAMLHTTPLimits = .default,
                            decoder: YAMLDecoder = YAMLDecoder()) async throws -> T {
        let response = try await URLSessionTransport(session: self)
            .send(request.asTransportRequest(), maxResponseBytes: limits.maxResponseBytes)
        return try YAMLHTTPResponse.decode(type, body: response.body, response: response,
                                           limits: limits, decoder: decoder)
    }

    /// Fetches a url and decodes a YAML response. Pass the type to decode and the url.
    func yaml<T: Decodable>(_ type: T.Type,
                            from url: URL,
                            limits: YAMLHTTPLimits = .default,
                            decoder: YAMLDecoder = YAMLDecoder()) async throws -> T {
        try await yaml(type, for: URLRequest(yaml: url), limits: limits, decoder: decoder)
    }

    /// Sends a value as YAML and decodes the YAML that comes back. Pass the body, the url, the
    /// method, the response type, and whether to compress what is sent.
    func sendYAML<Body: Encodable, T: Decodable>(_ body: Body,
                                                 to url: URL,
                                                 method: String = "POST",
                                                 expecting type: T.Type,
                                                 compressBody: Bool = false,
                                                 limits: YAMLHTTPLimits = .default,
                                                 encoder: YAMLEncoder = YAMLEncoder(),
                                                 decoder: YAMLDecoder = YAMLDecoder()) async throws -> T {
        let request = try URLRequest(yaml: url, method: method, body: body,
                                     compressed: compressBody, encoder: encoder)
        return try await yaml(type, for: request, limits: limits, decoder: decoder)
    }

    /// Sends a value as YAML and ignores the response body, checking only that the status and the
    /// encoding were acceptable. Throws the same errors as the decoding form.
    func sendYAML<Body: Encodable>(_ body: Body,
                                   to url: URL,
                                   method: String = "POST",
                                   compressBody: Bool = false,
                                   limits: YAMLHTTPLimits = .default,
                                   encoder: YAMLEncoder = YAMLEncoder()) async throws {
        let request = try URLRequest(yaml: url, method: method, body: body,
                                     compressed: compressBody, encoder: encoder)
        let response = try await URLSessionTransport(session: self)
            .send(request.asTransportRequest(), maxResponseBytes: limits.maxResponseBytes)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw YAMLHTTPError.status(code: response.statusCode, body: response.body)
        }
    }

    /// Fetches a url whose body is a top-level YAML sequence and decodes its elements one at a time.
    ///
    /// Pass the element type and the url. Returns every element. The body is inflated and parsed
    /// incrementally, so the inflated text and the element array are built as the body arrives
    /// rather than after it, and the gzip bound stops a bomb while it is still inflating.
    func yamlSequence<Element: Decodable>(_ type: Element.Type,
                                          from url: URL,
                                          limits: YAMLHTTPLimits = .default) async throws -> [Element] {
        let response = try await URLSessionTransport(session: self)
            .send(URLRequest(yaml: url).asTransportRequest(), maxResponseBytes: limits.maxResponseBytes)
        guard response.body.count <= limits.maxResponseBytes else {
            throw YAMLHTTPError.responseTooLarge(limit: limits.maxResponseBytes)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw YAMLHTTPError.status(code: response.statusCode, body: response.body)
        }
        guard YAMLMediaType.isYAML(response.header("Content-Type")) else {
            throw YAMLHTTPError.unexpectedContentType(response.header("Content-Type"))
        }

        let encoding = response.header("Content-Encoding")?.lowercased()
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard ["", "identity", "gzip", "x-gzip"].contains(encoding) else {
            throw YAMLHTTPError.unsupportedContentEncoding(encoding)
        }
        let compressed = (encoding == "gzip" || encoding == "x-gzip") && Gzip.hasGzipMagic(response.body)

        if compressed {
            let reader = GzipYAMLSequenceReader<Element>(gzipLimits: limits.gzip, yamlLimits: limits.yaml)
            var out: [Element] = []
            var offset = 0
            let chunk = 64 * 1024
            while offset < response.body.count {
                let end = Swift.min(offset + chunk, response.body.count)
                out += try reader.push(response.body.subdata(in: offset ..< end))
                offset = end
            }
            out += try reader.finish()
            return out
        }

        let reader = YAMLByteSequenceReader<Element>(limits: limits.yaml)
        var out = try reader.push(response.body)
        out += try reader.finish()
        return out
    }
}

private extension URLRequest {
    /// Keeps the complete native request so caller timeouts, cache, cookie and body-stream
    /// settings survive the transport bridge.
    func asTransportRequest() throws -> YAMLTransportRequest {
        var headers: [String: String] = [:]
        allHTTPHeaderFields?.forEach { headers[$0.key] = $0.value }
        guard let url = url else { throw URLError(.badURL) }
        var request = YAMLTransportRequest(url: url, method: httpMethod ?? "GET", headers: headers, body: httpBody)
        request.originalRequest = self
        return request
    }
}
