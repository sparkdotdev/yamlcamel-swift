import Foundation
import YAMLCamel
import YAMLCamelGzip

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The media types and header names this module sends and accepts.
public enum YAMLMediaType {

    /// The type registered for YAML in RFC 9512, and the one this module sends.
    public static let canonical = "application/yaml"

    /// Types accepted on a response, since servers predating RFC 9512 use the older spellings.
    public static let accepted: Set<String> = [
        "application/yaml", "text/yaml", "application/x-yaml", "text/x-yaml",
    ]

    /// True when a Content-Type header names YAML. Parameters after a semicolon are ignored.
    public static func isYAML(_ contentType: String?) -> Bool {
        guard let contentType = contentType else { return false }
        let base = contentType.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard let base = base else { return false }
        return accepted.contains(base)
    }
}

/// Bounds applied to an HTTP exchange.
///
/// Every one applies while the body is being read rather than after, which is the point: a bound
/// checked on a body already in memory has not prevented anything.
public struct YAMLHTTPLimits: Sendable, Equatable {

    /// Largest response body accepted as it comes off the wire, before any decompression.
    public var maxResponseBytes: Int

    /// Bounds applied while inflating a gzipped response.
    public var gzip: GzipLimits

    /// Bounds applied while parsing whatever the body turns out to hold.
    public var yaml: YAMLLimits

    /// Creates a limit set. Every argument defaults to the value `YAMLHTTPLimits.default` uses.
    public init(maxResponseBytes: Int = 16 << 20,
                gzip: GzipLimits = .default,
                yaml: YAMLLimits = .default) {
        self.maxResponseBytes = maxResponseBytes
        self.gzip = gzip
        self.yaml = yaml
    }

    /// The limits every call uses when the caller does not pass its own.
    public static let `default` = YAMLHTTPLimits()
}

/// A failure in an HTTP exchange carrying YAML.
///
/// A failure from the parser or the decompressor arrives as `YAMLParseError` or `GzipError` rather
/// than being wrapped, so a caller matches on the error it actually cares about.
public enum YAMLHTTPError: Error, CustomStringConvertible {

    /// The response was not an HTTP response at all.
    case notHTTP

    /// The server answered with a status outside 200 to 299. Carries the status and the raw body,
    /// truncated to the response bound.
    case status(code: Int, body: Data)

    /// The server answered with a body that is not YAML. Carries the Content-Type it did send.
    case unexpectedContentType(String?)

    /// The body was larger than `YAMLHTTPLimits.maxResponseBytes`.
    case responseTooLarge(limit: Int)

    /// The server named a Content-Encoding this module does not handle.
    case unsupportedContentEncoding(String)

    public var description: String {
        switch self {
        case .notHTTP:
            return "The response was not an HTTP response."
        case .status(let code, _):
            return "The server answered with status \(code)."
        case .unexpectedContentType(let type):
            return "The server answered with Content-Type \(type ?? "none"), which is not YAML."
        case .responseTooLarge(let limit):
            return "The response body is over the \(limit) byte limit."
        case .unsupportedContentEncoding(let encoding):
            return "The server answered with Content-Encoding \(encoding), which is not handled."
        }
    }
}

/// Turns a body and a response into a decoded value.
///
/// This is separated from the transport so the rules that matter, which encoding was applied, which
/// content type came back and which bounds apply, are all testable without a network.
public enum YAMLHTTPResponse {

    /// Checks the status, the content type and the encoding, then decodes. Pass the received body,
    /// the response, and the limits. Returns the decoded value. Throws `YAMLHTTPError`, `GzipError`
    /// or a decoding error.
    public static func decode<T: Decodable>(_ type: T.Type,
                                            body: Data,
                                            response: YAMLTransportResponse,
                                            limits: YAMLHTTPLimits = .default,
                                            compression: YAMLCompression = GzipCompression(),
                                            decoder: YAMLDecoder = YAMLDecoder()) throws -> T {
        let text = try yamlText(body: body, response: response, limits: limits, compression: compression)
        // `YAMLDecoder` is a class, and a `decoder:` a caller passed in is not this call's to mutate:
        // setting `.limits` on it in place raced two concurrent calls sharing one decoder against
        // each other, so the loser could end up decoding under the winner's bound rather than its
        // own. `limits.yaml` is what governs this call regardless of what the decoder already held,
        // so a decoder scoped to this call carries it without touching what the caller is holding.
        let scoped = YAMLDecoder(limits: limits.yaml)
        return try scoped.decode(type, from: text)
    }

    /// Checks the status, the content type and the encoding, then returns the body as YAML text.
    ///
    /// A server that ignores `Accept-Encoding` and answers uncompressed is handled: the encoding
    /// header is believed only when the bytes actually start with the gzip magic number.
    public static func yamlText(body: Data,
                                response: YAMLTransportResponse,
                                limits: YAMLHTTPLimits = .default,
                                compression: YAMLCompression = GzipCompression()) throws -> String {
        guard body.count <= limits.maxResponseBytes else {
            throw YAMLHTTPError.responseTooLarge(limit: limits.maxResponseBytes)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw YAMLHTTPError.status(code: response.statusCode, body: body)
        }

        let encoding = response.header("Content-Encoding")?.lowercased()
            .trimmingCharacters(in: .whitespaces) ?? ""

        let decoded: Data
        switch encoding {
        case "", "identity":
            decoded = body
        case "gzip", "x-gzip":
            // A platform that already inflated this, or a server that lied about the encoding,
            // leaves bytes that are not gzip. Believing the header over the bytes would fail both.
            if Gzip.hasGzipMagic(body) {
                let inflated = try compression.decompress(body, limits: limits.gzip)
                // `compression` is a caller-supplied `YAMLCompression`, and this module's own default
                // already keeps to the bound while it inflates. A substituted one that does not honour
                // `limits.gzip` is checked here instead, before its result is turned into a `String`
                // and handed back: the point of the bound is what it stops, and a check made only
                // after the conversion has already paid for the size it was meant to refuse.
                guard inflated.count <= limits.gzip.maxOutputBytes else {
                    throw GzipError(.outputTooLarge,
                                    "Decompressed body is over the \(limits.gzip.maxOutputBytes) byte limit.")
                }
                decoded = inflated
            } else {
                decoded = body
            }
        default:
            throw YAMLHTTPError.unsupportedContentEncoding(encoding)
        }

        guard YAMLMediaType.isYAML(response.header("Content-Type")) else {
            throw YAMLHTTPError.unexpectedContentType(response.header("Content-Type"))
        }
        guard let text = String(data: decoded, encoding: .utf8) else {
            throw YAMLParseError("Input is not valid UTF-8.", kind: .syntax)
        }
        return text
    }
}
