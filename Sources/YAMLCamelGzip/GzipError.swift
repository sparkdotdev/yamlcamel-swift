import Foundation

/// A failure while compressing or decompressing a gzip stream.
///
/// Every failure this module can produce is one of these. Nothing traps, so a caller handed a
/// hostile body can always catch and recover.
public struct GzipError: Error, Equatable, CustomStringConvertible {

    /// What went wrong, so a caller can tell a malformed body from one that was simply too big.
    public enum Kind: Sendable, Equatable {
        /// The bytes are not a gzip stream, or the trailer disagrees with the data.
        case corrupt
        /// The stream ended before the compressor said it was done.
        case truncated
        /// Output crossed `GzipLimits.maxOutputBytes` while inflating.
        case outputTooLarge
        /// Input crossed `GzipLimits.maxInputBytes`.
        case inputTooLarge
        /// zlib could not allocate what it needed.
        case outOfMemory
        /// zlib reported something this module does not expect.
        case internalFailure
    }

    public let kind: Kind
    public let message: String

    /// Creates a gzip error. Pass the kind and a message naming what happened.
    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    /// True when the input was refused for size rather than for being malformed.
    public var isLimit: Bool { kind == .outputTooLarge || kind == .inputTooLarge }

    public var description: String { "Gzip error: \(message)" }
}

/// Bounds applied while inflating.
///
/// A few kilobytes on the wire can expand to gigabytes, so the output bound is checked after every
/// block zlib produces rather than once at the end. Inflating fully and then measuring is the bug
/// this exists to avoid.
public struct GzipLimits: Sendable, Equatable {

    /// Largest decompressed body accepted. Checked while inflating, and inflation stops the moment
    /// it is crossed.
    public var maxOutputBytes: Int

    /// Largest compressed body accepted.
    public var maxInputBytes: Int

    /// Creates a limit set. Every argument defaults to the value `GzipLimits.default` uses.
    public init(maxOutputBytes: Int = 64 << 20, maxInputBytes: Int = 16 << 20) {
        self.maxOutputBytes = maxOutputBytes
        self.maxInputBytes = maxInputBytes
    }

    /// The limits every entry point uses when the caller does not pass its own.
    public static let `default` = GzipLimits()

    /// Limits with no ceiling worth speaking of, for bodies you produced yourself.
    public static let permissive = GzipLimits(maxOutputBytes: Int.max, maxInputBytes: Int.max)
}
