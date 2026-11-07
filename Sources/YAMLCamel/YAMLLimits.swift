import Foundation

/// Bounds the parser applies while reading, so hostile input is refused rather than absorbed.
///
/// Every bound is checked during parsing rather than after it, because a limit that only applies to
/// a finished value cannot stop the work that produced it.
public struct YAMLLimits: Sendable, Equatable {

    /// Largest input accepted, in UTF-8 bytes. Checked before any scanning starts.
    public var maxInputBytes: Int

    /// Deepest nesting of collections accepted, counting both block and flow. Clamped to
    /// `maxSupportedDepth`.
    public var maxDepth: Int

    /// Largest number of nodes one input may produce, counting nodes an alias expands into.
    ///
    /// The total runs across the whole input rather than restarting at each `---` marker or at each
    /// item a streaming reader hands over, because an alias bomb that fits inside one document or
    /// one item would otherwise cost this much again for every one of them.
    public var maxNodes: Int

    /// Largest single scalar accepted, in unicode scalars.
    public var maxScalarLength: Int

    /// Largest number of aliases one input may dereference, counted the same way `maxNodes` is.
    public var maxAliasExpansions: Int

    /// Largest number of documents accepted from one stream.
    public var maxDocuments: Int

    /// Largest resolved tag accepted, in UTF-8 bytes, counting the `%TAG` prefix and the shorthand
    /// suffix together. Checked before the two are joined.
    ///
    /// A `%TAG` directive's prefix is declared once but a document can invoke its handle as many
    /// times as it has bytes to spare for a two-character shorthand, and every invocation rebuilds
    /// the full tag by concatenating the prefix onto the suffix. A short document can therefore
    /// demand the concatenation cost of a directive-length prefix once per invocation, which a bound
    /// on the document's own byte count does nothing to stop. Real tags, shorthand or verbatim, are
    /// short, so this stays well under `maxScalarLength`.
    public var maxTagLength: Int

    /// How a mapping with a repeated key is handled.
    public var duplicateKeys: DuplicateKeyPolicy

    /// What to do when the same key appears twice in one mapping.
    public enum DuplicateKeyPolicy: Sendable, Equatable {
        /// Refuse the document, which is what YAML 1.2.2 calls for.
        case reject
        /// Keep the first occurrence and ignore later ones.
        case firstWins
        /// Keep the last occurrence.
        case lastWins
    }

    /// Creates a limit set. Every argument defaults to the value `YAMLLimits.default` uses.
    public init(
        maxInputBytes: Int = 16 << 20,
        maxDepth: Int = maxSupportedDepth,
        maxNodes: Int = 2_000_000,
        maxScalarLength: Int = 4 << 20,
        maxAliasExpansions: Int = 10_000,
        maxDocuments: Int = 1024,
        maxTagLength: Int = 1024,
        duplicateKeys: DuplicateKeyPolicy = .reject
    ) {
        self.maxInputBytes = maxInputBytes
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.maxScalarLength = maxScalarLength
        self.maxAliasExpansions = maxAliasExpansions
        self.maxDocuments = maxDocuments
        self.maxTagLength = maxTagLength
        self.duplicateKeys = duplicateKeys
    }

    /// The deepest nesting the parser will ever attempt, whatever a caller asks for.
    ///
    /// Parsing is recursive, and on the 512 KB stack the cooperative pool gives you an unoptimised
    /// build runs out near 100 levels. This sits at roughly half of that.
    public static let maxSupportedDepth = 48

    /// The limits every entry point uses when the caller does not pass its own.
    public static let `default` = YAMLLimits()

    /// Limits with no ceiling worth speaking of, for input you produced yourself. Nesting stays
    /// bounded, because the alternative is a stack overflow no caller can catch.
    public static let permissive = YAMLLimits(
        maxInputBytes: Int.max,
        maxDepth: maxSupportedDepth,
        maxNodes: Int.max,
        maxScalarLength: Int.max,
        maxAliasExpansions: Int.max,
        maxDocuments: Int.max,
        maxTagLength: Int.max,
        duplicateKeys: .lastWins
    )
}
