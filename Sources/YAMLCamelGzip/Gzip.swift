import Foundation
import CZlib

/// Gzip compression and decompression over the system zlib.
///
/// The one-shot calls here run the same streaming machinery underneath, so a bound that applies
/// while inflating applies to both.
public enum Gzip {

    /// How hard the compressor works.
    public enum Level: Sendable, Equatable {
        case none, fastest, `default`, best
        case custom(Int32)

        var zlibValue: Int32 {
            switch self {
            case .none: return 0
            case .fastest: return 1
            case .default: return -1
            case .best: return 9
            case .custom(let v): return max(-1, min(9, v))
            }
        }
    }

    /// Compresses data into a gzip stream. Pass the bytes and optionally a level. Returns the gzip
    /// bytes, header and trailer included. Throws `GzipError`.
    public static func compress(_ data: Data, level: Level = .default) throws -> Data {
        let compressor = try GzipCompressor(level: level)
        var out = try compressor.push(data)
        out.append(try compressor.finish())
        return out
    }

    /// Decompresses a gzip stream. Pass the bytes and optionally your own limits. Returns the
    /// decompressed bytes. Throws `GzipError`, including kind `outputTooLarge` as soon as the output
    /// crosses the bound, and kind `truncated` when the stream ends early.
    public static func decompress(_ data: Data, limits: GzipLimits = .default) throws -> Data {
        let decompressor = GzipDecompressor(limits: limits)
        var out = try decompressor.push(data)
        out.append(try decompressor.finish())
        return out
    }

    /// True when the bytes begin with the gzip magic number.
    ///
    /// This reads two bytes and proves nothing about the rest, so treat it as a hint rather than as
    /// validation.
    public static func hasGzipMagic(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let first = data[data.startIndex]
        let second = data[data.index(after: data.startIndex)]
        return first == 0x1F && second == 0x8B
    }
}
