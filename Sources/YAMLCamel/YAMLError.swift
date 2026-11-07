import Foundation

/// A failure while parsing YAML text.
///
/// Every failure this library can produce is one of these, including a refusal on a limit. Nothing
/// traps, so a caller can always catch and recover.
public struct YAMLParseError: Error, Equatable, CustomStringConvertible {

    /// Why the parse failed, so a caller can tell malformed input from input that was simply too big.
    public enum Kind: Sendable, Equatable {
        /// The text is not valid YAML.
        case syntax
        /// The input is larger than `YAMLLimits.maxInputBytes`.
        case inputTooLarge
        /// Nesting went past `YAMLLimits.maxDepth`.
        case depthExceeded
        /// The document produced more nodes than `YAMLLimits.maxNodes`.
        case tooManyNodes
        /// A scalar was longer than `YAMLLimits.maxScalarLength`.
        case scalarTooLong
        /// A resolved tag was longer than `YAMLLimits.maxTagLength`.
        case tagTooLong
        /// More aliases were dereferenced than `YAMLLimits.maxAliasExpansions`.
        case tooManyAliases
        /// The stream held more documents than `YAMLLimits.maxDocuments`.
        case tooManyDocuments
        /// An alias named an anchor that has not been defined.
        case undefinedAlias
        /// A mapping repeated a key and the policy is `reject`.
        case duplicateKey
        /// A stream that should hold exactly one document held none or several.
        case documentCount
    }

    public let kind: Kind
    public let message: String
    public let line: Int

    /// Creates a parse error. Pass a 1-based line number when the position is known.
    public init(_ message: String, line: Int = 0, kind: Kind = .syntax) {
        self.kind = kind
        self.message = message
        self.line = line
    }

    /// True when the parser refused the input for exceeding a limit rather than for being malformed.
    public var isLimit: Bool {
        switch kind {
        case .inputTooLarge, .depthExceeded, .tooManyNodes,
             .scalarTooLong, .tagTooLong, .tooManyAliases, .tooManyDocuments:
            return true
        case .syntax, .undefinedAlias, .duplicateKey, .documentCount:
            return false
        }
    }

    public var description: String {
        line > 0 ? "YAML parse error at line \(line): \(message)" : "YAML parse error: \(message)"
    }
}
