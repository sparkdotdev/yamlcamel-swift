import Foundation

/// Untyped access to YAML text, for callers that want Foundation values rather than a `Decodable`.
///
/// These are namespaced because a module-scope `load` collides with `NSObject.load()` at any call
/// site that imports both, and the collision reports as a compiler failure rather than as an
/// ambiguity the caller can read.
public enum YAML {

    /// Parses YAML text into native Foundation values: `[String: Any]`, `[Any]`, `String`, `Int`,
    /// `Double`, `Bool` and `NSNull`. An empty or null document returns nil. Throws `YAMLParseError`
    /// when the text is not valid YAML.
    public static func load(yaml: String, limits: YAMLLimits = .default) throws -> Any? {
        let value = try YAMLParser.parse(yaml, limits: limits)
        if case .null = value { return nil }
        return value.foundationObject
    }

    /// Serializes a Foundation or Swift value to block-style YAML text. Pass sortKeys to emit mapping
    /// keys in sorted order, and limits to bound what may be written. Throws `YAMLEmitError` when the
    /// value writes out larger than the limits allow.
    public static func dump(object: Any?,
                            sortKeys: Bool = false,
                            limits: YAMLEmitLimits = .default) throws -> String {
        let value = object.map { YAMLValue(foundation: $0) } ?? .null
        return try YAMLEmitter(sortKeys: sortKeys, limits: limits).emit(value)
    }

    /// Renders a parsed value as block-style YAML text. Pass sortKeys to emit mapping keys in
    /// sorted order, and limits to bound what may be written. Returns the text.
    ///
    /// Throws `YAMLEmitError` when the value writes out larger, deeper or with more nodes than the
    /// limits allow. A value that came from parsing can cross those bounds while the document that
    /// produced it was well inside the parser's own, because an alias is cheap to read and expensive
    /// to write back out.
    public static func emit(_ value: YAMLValue,
                            sortKeys: Bool = false,
                            limits: YAMLEmitLimits = .default) throws -> String {
        try YAMLEmitter(sortKeys: sortKeys, limits: limits).emit(value)
    }

    // MARK: - base64 YAML convenience

    /// Decodes base64-encoded YAML into native values. Returns nil when the input is not valid
    /// base64, not valid UTF-8, or not valid YAML.
    public static func loadBase64(_ base64: String) -> Any? {
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8),
              let value = try? load(yaml: text) else { return nil }
        return value
    }

    /// Encodes a Foundation or Swift value as base64 YAML, the inverse of `loadBase64`. Pass sortKeys
    /// to emit mapping keys in sorted order.
    public static func dumpBase64(object: Any?,
                                  sortKeys: Bool = false,
                                  limits: YAMLEmitLimits = .default) throws -> String {
        let yaml = try dump(object: object, sortKeys: sortKeys, limits: limits)
        return Data(yaml.utf8).base64EncodedString()
    }
}
