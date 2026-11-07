import Foundation
import YAMLCamel

public extension YAMLDecoder {

    /// Decodes a value from gzipped YAML. Pass the type, the gzip bytes, and optionally your own
    /// gzip limits. Returns the decoded value. Throws `GzipError` when the body is malformed or
    /// larger than the bound, and the usual decoding errors after that.
    ///
    /// The body is inflated before parsing, so both bounds apply: the gzip output bound while
    /// inflating, and the parser's own bounds on what comes out.
    func decode<T: Decodable>(_ type: T.Type,
                              fromGzipped data: Data,
                              gzipLimits: GzipLimits = .default) throws -> T {
        let inflated = try Gzip.decompress(data, limits: gzipLimits)
        return try decode(type, from: inflated)
    }
}

public extension YAMLEncoder {

    /// Encodes a value to YAML and compresses it. Pass the value and optionally a level. Returns the
    /// gzip bytes. Throws whatever the value's own `encode(to:)` throws, or `GzipError`.
    func encodeGzipped<T: Encodable>(_ value: T, level: Gzip.Level = .default) throws -> Data {
        let text = try encode(value)
        return try Gzip.compress(Data(text.utf8), level: level)
    }
}

/// Decodes a top-level YAML block sequence out of a gzipped body, one element at a time.
///
/// Compressed bytes go in as they arrive and decoded elements come out as each item completes, so
/// neither the compressed body, the inflated text, nor the full element array is ever held. This is
/// the shape to use for an HTTP response, where all three of those are attacker controlled.
public final class GzipYAMLSequenceReader<Element: Decodable> {
    private let decompressor: GzipDecompressor
    private let reader: YAMLByteSequenceReader<Element>

    /// Number of items emitted so far. Skipped items count as emitted.
    public var emitted: Int { reader.emitted }

    /// Total decompressed bytes seen so far.
    public var inflatedBytes: Int { decompressor.outputBytes }

    /// Creates a reader. Pass gzip limits for the inflated size and YAML limits for what the parser
    /// will accept out of it.
    public init(gzipLimits: GzipLimits = .default, yamlLimits: YAMLLimits = .default) {
        decompressor = GzipDecompressor(limits: gzipLimits)
        reader = YAMLByteSequenceReader<Element>(limits: yamlLimits)
    }

    /// Skips the next `n` items without decoding them, for resuming an interrupted ingest.
    public func skip(_ n: Int) { reader.skip(n) }

    /// Inflates a chunk of compressed bytes and returns any elements it completed. Throws
    /// `GzipError` or `YAMLParseError`.
    public func push(_ data: Data) throws -> [Element] {
        let inflated = try decompressor.push(data)
        guard !inflated.isEmpty else { return [] }
        return try reader.push(inflated)
    }

    /// Signals end of input and returns the last elements. Throws `GzipError` with kind `truncated`
    /// when the gzip stream never reached its trailer.
    public func finish() throws -> [Element] {
        _ = try decompressor.finish()
        return try reader.finish()
    }
}
