import Foundation

/// Applies YAML tags and the 1.2.2 core schema to a scalar or a collection.
///
/// A tag the core schema does not define is carried no further than resolution: the value keeps the
/// type the core schema would have given it, so an unknown tag annotates rather than fails.
enum YAMLTag {

    static let null = "tag:yaml.org,2002:null"
    static let bool = "tag:yaml.org,2002:bool"
    static let int = "tag:yaml.org,2002:int"
    static let float = "tag:yaml.org,2002:float"
    static let str = "tag:yaml.org,2002:str"
    static let seq = "tag:yaml.org,2002:seq"
    static let map = "tag:yaml.org,2002:map"

    /// Resolves a scalar. Pass the text, whether it was written plain, and the tag if the document
    /// carried one. Throws when an explicit tag does not fit the text.
    static func resolveScalar(text: String, plain: Bool, tag: String?, line: Int) throws -> YAMLValue {
        guard let tag = tag else {
            return plain ? YAMLScalar.resolve(text) : .string(text)
        }
        switch tag {
        case "!", str:
            return .string(text)
        case null:
            guard case .null = YAMLScalar.resolve(text) else {
                throw YAMLParseError("Value '\(text)' is tagged null but does not read as null.", line: line)
            }
            return .null
        case bool:
            guard case .bool(let b) = YAMLScalar.resolve(text) else {
                throw YAMLParseError("Value '\(text)' is tagged bool but does not read as one.", line: line)
            }
            return .bool(b)
        case int:
            if let i = YAMLScalar.parseInteger(text) { return .int(i) }
            if let u = YAMLScalar.parseUnsignedInteger(text) { return .uint(u) }
            throw YAMLParseError("Value '\(text)' is tagged int but does not read as one.", line: line)
        case float:
            if let d = YAMLScalar.parseFloat(text) { return .double(d) }
            if case .double(let d) = YAMLScalar.resolve(text) { return .double(d) }
            if let i = YAMLScalar.parseInteger(text) { return .double(Double(i)) }
            if let u = YAMLScalar.parseUnsignedInteger(text) { return .double(Double(u)) }
            throw YAMLParseError("Value '\(text)' is tagged float but does not read as one.", line: line)
        case seq, map:
            throw YAMLParseError("A scalar cannot carry the tag \(tag).", line: line)
        default:
            return plain ? YAMLScalar.resolve(text) : .string(text)
        }
    }

    /// Resolves a collection. Pass the built value and the tag if the document carried one. Throws
    /// when the tag names the other kind of collection or a scalar type.
    static func resolveCollection(_ value: YAMLValue, tag: String?, line: Int) throws -> YAMLValue {
        guard let tag = tag else { return value }
        switch tag {
        case "!":
            return value
        case seq:
            guard case .array = value else {
                throw YAMLParseError("A mapping cannot carry the tag \(tag).", line: line)
            }
            return value
        case map:
            guard case .object = value else {
                throw YAMLParseError("A sequence cannot carry the tag \(tag).", line: line)
            }
            return value
        case str, int, float, bool, null:
            throw YAMLParseError("A collection cannot carry the tag \(tag).", line: line)
        default:
            return value
        }
    }
}
