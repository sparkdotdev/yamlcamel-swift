import Foundation

/// Gzip compression a caller can substitute, so a consumer that already routes compression through
/// its own layer is not forced through this module's zlib binding directly.
public protocol YAMLCompression: Sendable {
    func compress(_ data: Data, level: Gzip.Level) throws -> Data
    func decompress(_ data: Data, limits: GzipLimits) throws -> Data
}

/// The default `YAMLCompression`, delegating to `Gzip`.
public struct GzipCompression: YAMLCompression {
    public init() {}

    public func compress(_ data: Data, level: Gzip.Level = .default) throws -> Data {
        try Gzip.compress(data, level: level)
    }

    public func decompress(_ data: Data, limits: GzipLimits = .default) throws -> Data {
        try Gzip.decompress(data, limits: limits)
    }
}
