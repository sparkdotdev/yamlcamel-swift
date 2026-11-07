import Foundation

/// Bounds the emitter applies while writing.
///
/// Parsing and emitting do not cost the same. An alias lets the parser accept a large tree cheaply,
/// because what the alias names is shared rather than copied, and the emitter has to write every
/// copy out in full. These bounds are what stops a document the parser was right to accept from
/// becoming an enormous amount of text.
public struct YAMLEmitLimits: Sendable, Equatable {

    /// Largest output accepted, in UTF-8 bytes. Checked as the text grows.
    public var maxOutputBytes: Int

    /// Largest number of nodes written, counting every copy an alias expanded into.
    public var maxNodes: Int

    /// Deepest nesting written. Clamped to `YAMLLimits.maxSupportedDepth`.
    public var maxDepth: Int

    /// Creates a limit set. Every argument defaults to the value `YAMLEmitLimits.default` uses.
    public init(maxOutputBytes: Int = 16 << 20,
                maxNodes: Int = 2_000_000,
                maxDepth: Int = YAMLLimits.maxSupportedDepth) {
        self.maxOutputBytes = maxOutputBytes
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
    }

    /// The limits every emit uses when the caller does not pass its own.
    ///
    /// The byte bound matches `YAMLLimits.maxInputBytes`, so text this writes can be read back on
    /// the matching default rather than being refused by it.
    public static let `default` = YAMLEmitLimits()

    /// Limits with no ceiling worth speaking of, for values you built yourself. Nesting stays
    /// bounded, because emitting recurses and the alternative is a stack overflow.
    public static let permissive = YAMLEmitLimits(maxOutputBytes: Int.max,
                                                  maxNodes: Int.max,
                                                  maxDepth: YAMLLimits.maxSupportedDepth)
}

/// A failure while emitting YAML text.
///
/// A value may cross a size bound or contain duplicate mapping members that would produce
/// ambiguous YAML.
public struct YAMLEmitError: Error, Equatable, CustomStringConvertible {

    /// Which bound the value crossed.
    public enum Kind: Sendable, Equatable {
        /// Output grew past `YAMLEmitLimits.maxOutputBytes`.
        case outputTooLarge
        /// The value holds more nodes than `YAMLEmitLimits.maxNodes`.
        case tooManyNodes
        /// The value nests deeper than `YAMLEmitLimits.maxDepth`.
        case depthExceeded
        /// A mapping contains the same key more than once.
        case duplicateKey
    }

    public let kind: Kind
    public let message: String

    /// Creates an emit error. Pass the kind and a message naming the bound that was crossed.
    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { "YAML emit error: \(message)" }
}

/// Carries the emitter's running totals, shared by reference so a nested buffer spends the same
/// budget as the one it will be folded into.
final class YAMLEmitBudget {
    private let limits: YAMLEmitLimits
    private var bytes = 0
    private var nodes = 0
    private var depth = 0
    private let depthCeiling: Int

    init(limits: YAMLEmitLimits) {
        self.limits = limits
        self.depthCeiling = Swift.min(limits.maxDepth, YAMLLimits.maxSupportedDepth)
    }

    /// Charges text that is about to be written.
    func spend(_ text: String) throws {
        bytes += text.utf8.count
        guard bytes <= limits.maxOutputBytes else {
            throw YAMLEmitError(.outputTooLarge,
                                "Output grew past the \(limits.maxOutputBytes) byte limit.")
        }
    }

    func countNode() throws {
        nodes += 1
        guard nodes <= limits.maxNodes else {
            throw YAMLEmitError(.tooManyNodes,
                                "Value holds more than \(limits.maxNodes) nodes.")
        }
    }

    func push() throws {
        depth += 1
        guard depth <= depthCeiling else {
            throw YAMLEmitError(.depthExceeded,
                                "Value nests deeper than the limit of \(depthCeiling).")
        }
    }

    func pop() { depth -= 1 }
}
