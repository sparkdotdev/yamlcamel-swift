import Foundation
import YAMLCamel
import YAMLCamelGzip

/// Sends and receives YAML over HTTP through a swappable transport and compressor. A caller that
/// already routes networking through its own layer, a game engine among them, injects both here
/// instead of being pinned to `URLSession` and this module's zlib binding.
public struct YAMLHTTPClient {
    public var transport: YAMLTransport
    public var compression: YAMLCompression
    public var limits: YAMLHTTPLimits

    public init(transport: YAMLTransport = URLSessionTransport(),
               compression: YAMLCompression = GzipCompression(),
               limits: YAMLHTTPLimits = .default) {
        self.transport = transport
        self.compression = compression
        self.limits = limits
    }

    /// Fetches a url and decodes a YAML response. Pass the type to decode and the url.
    public func get<T: Decodable>(_ type: T.Type,
                                  from url: URL,
                                  acceptsGzip: Bool = true,
                                  decoder: YAMLDecoder = YAMLDecoder()) async throws -> T {
        try await get(type, for: YAMLTransportRequest(yaml: url, acceptsGzip: acceptsGzip), decoder: decoder)
    }

    /// Sends a request and decodes a YAML response. Pass the type to decode and the request.
    public func get<T: Decodable>(_ type: T.Type,
                                  for request: YAMLTransportRequest,
                                  decoder: YAMLDecoder = YAMLDecoder()) async throws -> T {
        let response = try await transport.send(request, maxResponseBytes: limits.maxResponseBytes)
        return try YAMLHTTPResponse.decode(type, body: response.body, response: response,
                                           limits: limits, compression: compression, decoder: decoder)
    }

    /// Sends a value as YAML and decodes the YAML that comes back. Pass the body, the url, the
    /// response type, and whether to compress what is sent.
    public func post<Body: Encodable, T: Decodable>(_ body: Body,
                                                     to url: URL,
                                                     expecting type: T.Type,
                                                     compressBody: Bool = false,
                                                     encoder: YAMLEncoder = YAMLEncoder(),
                                                     decoder: YAMLDecoder = YAMLDecoder()) async throws -> T {
        let request = try YAMLTransportRequest(yaml: url, method: "POST", body: body,
                                               compressed: compressBody, encoder: encoder,
                                               compression: compression)
        return try await get(type, for: request, decoder: decoder)
    }

    /// Sends a value as YAML and ignores the response body, checking only that the status was
    /// acceptable. Throws `YAMLHTTPError.status` on a failing status.
    public func post<Body: Encodable>(_ body: Body,
                                      to url: URL,
                                      compressBody: Bool = false,
                                      encoder: YAMLEncoder = YAMLEncoder()) async throws {
        let request = try YAMLTransportRequest(yaml: url, method: "POST", body: body,
                                               compressed: compressBody, encoder: encoder,
                                               compression: compression)
        let response = try await transport.send(request, maxResponseBytes: limits.maxResponseBytes)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw YAMLHTTPError.status(code: response.statusCode, body: response.body)
        }
    }

    /// Fetches a url whose body is a top-level YAML sequence and decodes its elements one at a time.
    public func getSequence<Element: Decodable>(_ type: Element.Type, from url: URL) async throws -> [Element] {
        let response = try await transport.send(YAMLTransportRequest(yaml: url), maxResponseBytes: limits.maxResponseBytes)
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
