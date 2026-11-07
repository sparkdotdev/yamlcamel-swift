import Foundation
import YAMLCamel
import YAMLCamelGzip

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension URLRequest {

    /// Creates a request that sends and accepts YAML. Pass the url, the method, and whether the
    /// response may come back gzipped.
    ///
    /// `Accept-Encoding` is set explicitly when gzip is allowed, which keeps the inflation here
    /// where the size bound can be applied rather than in the networking stack where it cannot.
    init(yaml url: URL, method: String = "GET", acceptsGzip: Bool = true) {
        self.init(url: url)
        httpMethod = method
        setValue(YAMLMediaType.canonical, forHTTPHeaderField: "Accept")
        setValue(acceptsGzip ? "gzip" : "identity", forHTTPHeaderField: "Accept-Encoding")
    }

    /// Encodes a value as YAML and makes it the request body. Pass the value, whether to compress
    /// it, and optionally your own encoder. Sets `Content-Type`, and `Content-Encoding` when
    /// compressed. Throws whatever the value's own `encode(to:)` throws, or `GzipError`.
    mutating func setYAMLBody<T: Encodable>(_ value: T,
                                            compressed: Bool = false,
                                            encoder: YAMLEncoder = YAMLEncoder()) throws {
        let text = try encoder.encode(value)
        setValue(YAMLMediaType.canonical, forHTTPHeaderField: "Content-Type")
        if compressed {
            httpBody = try Gzip.compress(Data(text.utf8))
            setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        } else {
            httpBody = Data(text.utf8)
            setValue(nil, forHTTPHeaderField: "Content-Encoding")
        }
    }

    /// Creates a request carrying a YAML body. Pass the url, the method, the value to send, and
    /// whether to compress it. Throws whatever the value's own `encode(to:)` throws, or `GzipError`.
    init<T: Encodable>(yaml url: URL,
                       method: String,
                       body: T,
                       compressed: Bool = false,
                       acceptsGzip: Bool = true,
                       encoder: YAMLEncoder = YAMLEncoder()) throws {
        self.init(yaml: url, method: method, acceptsGzip: acceptsGzip)
        try setYAMLBody(body, compressed: compressed, encoder: encoder)
    }
}
