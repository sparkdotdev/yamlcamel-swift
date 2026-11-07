import Foundation
import YAMLCamel
import YAMLCamelGzip

public extension YAMLTransportRequest {

    /// Creates a request that sends and accepts YAML. Pass the url, the method, and whether the
    /// response may come back gzipped.
    ///
    /// `Accept-Encoding` is set explicitly when gzip is allowed, which keeps the inflation here
    /// where the size bound can be applied rather than in the networking stack where it cannot.
    init(yaml url: URL, method: String = "GET", acceptsGzip: Bool = true) {
        self.init(url: url, method: method)
        headers["Accept"] = YAMLMediaType.canonical
        headers["Accept-Encoding"] = acceptsGzip ? "gzip" : "identity"
    }

    /// Creates a request carrying a YAML body. Pass the url, the method, the value to send, and
    /// whether to compress it. Throws whatever the value's own `encode(to:)` throws, or whatever
    /// `compression.compress` throws.
    init<T: Encodable>(yaml url: URL,
                       method: String,
                       body: T,
                       compressed: Bool = false,
                       acceptsGzip: Bool = true,
                       encoder: YAMLEncoder = YAMLEncoder(),
                       compression: YAMLCompression = GzipCompression()) throws {
        self.init(yaml: url, method: method, acceptsGzip: acceptsGzip)
        let text = try encoder.encode(body)
        headers["Content-Type"] = YAMLMediaType.canonical
        if compressed {
            self.body = try compression.compress(Data(text.utf8), level: .default)
            headers["Content-Encoding"] = "gzip"
        } else {
            self.body = Data(text.utf8)
        }
    }
}
