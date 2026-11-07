import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

extension NSNumber {
    /// True when this number came from a `Bool` rather than from an integer.
    ///
    /// Every Swift number bridges to `NSNumber`, so telling `true` apart from `1` needs the boxed
    /// type. The CoreFoundation type id answers that exactly on Apple platforms, and the ObjC type
    /// encoding is the portable fallback.
    var isBooleanNumber: Bool {
        #if canImport(Darwin)
        return CFGetTypeID(self) == CFBooleanGetTypeID()
        #else
        return String(cString: objCType) == "c"
        #endif
    }
}

/// A parsed YAML value tree, shared by the parser, emitter, encoder and decoder.
///
/// The scalar cases stay distinct so encoding round-trips types faithfully, which is why an `Int`
/// field emits as `1` and never as `1.0`. Mappings hold an ordered `[Member]` so an unsorted encode
/// emits keys in the order the type declared them.
public enum YAMLValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    /// A positive integer literal too large for `Int`; anything that fits stays `.int`.
    case uint(UInt64)
    case double(Double)
    case string(String)
    indirect case array([YAMLValue])
    indirect case object([Member])

    /// One `key: value` pair inside an `object`, in insertion order.
    public struct Member: Sendable, Equatable {
        public var key: String
        public var value: YAMLValue

        /// Creates a mapping member. Pass the key text and the already-parsed value.
        public init(key: String, value: YAMLValue) {
            self.key = key
            self.value = value
        }
    }
}

public extension YAMLValue {
    /// The members of an `.object`, or nil for any other case.
    var objectMembers: [Member]? { if case .object(let m) = self { return m }; return nil }

    /// The elements of an `.array`, or nil for any other case.
    var arrayElements: [YAMLValue]? { if case .array(let a) = self { return a }; return nil }

    /// Looks up a key in an `.object`. Returns the first match, matching decode lookup order.
    subscript(_ key: String) -> YAMLValue? {
        guard case .object(let members) = self else { return nil }
        return members.first(where: { $0.key == key })?.value
    }
}

extension YAMLValue {
    /// How many nodes this subtree holds and how deep it nests, walked with an explicit stack.
    ///
    /// Worth reading before emitting a value that came from input you did not write, since aliases
    /// let a small document hold a very large tree.
    ///
    /// The parser charges an alias both numbers, which is what stops a small document from building
    /// an enormous or a very deep tree through repeated aliases. Recursion is avoided here on
    /// purpose, since the tree being measured may be deeper than the stack would survive.
    public var shape: (nodes: Int, depth: Int) {
        var nodes = 0
        var deepest = 0
        var stack: [(YAMLValue, Int)] = [(self, 1)]
        while let (value, level) = stack.popLast() {
            nodes += 1
            if level > deepest { deepest = level }
            switch value {
            case .array(let items):
                for item in items { stack.append((item, level + 1)) }
            case .object(let members):
                for m in members { stack.append((m.value, level + 1)) }
            default:
                break
            }
        }
        return (nodes, deepest)
    }
}

// MARK: - Textual form for a Double

extension YAMLValue {
    /// A stable, minimal textual form for a `Double`. Pass keepPointZero to force a trailing `.0` on
    /// integral values so they re-read as doubles.
    static func doubleText(_ d: Double, keepPointZero: Bool) -> String {
        if d.isNaN { return ".nan" }
        if d == .infinity { return ".inf" }
        if d == -.infinity { return "-.inf" }
        // Int64 has no negative zero, so routing -0.0 through it the way every other integral
        // value below is handled would silently flip its sign.
        if d == 0, d.sign == .minus { return keepPointZero ? "-0.0" : "-0" }
        if keepPointZero, d.rounded() == d, abs(d) < 1e16 {
            return String(Int64(d)) + ".0"
        }
        if d.rounded() == d, abs(d) < 1e16 {
            return String(Int64(d))
        }
        return String(d)
    }
}

// MARK: - Conversion to and from Foundation values

extension YAMLValue {
    /// The tree as native Foundation values: `[String: Any]`, `[Any]`, `String`, `Int`, `Double`,
    /// `Bool`, `NSNull`.
    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .uint(let u): return u
        case .double(let d): return d
        case .string(let s): return s
        case .array(let arr): return arr.map { $0.foundationObject }
        case .object(let members):
            var dict = [String: Any](minimumCapacity: members.count)
            for m in members where dict[m.key] == nil { dict[m.key] = m.value.foundationObject }
            return dict
        }
    }

    /// Builds a value from a Foundation or Swift `Any`. Anything unrecognised becomes its description.
    init(foundation object: Any) {
        switch object {
        case is NSNull:
            self = .null
        case let v as YAMLValue:
            self = v
        case let s as String:
            self = .string(s)
        case let arr as [Any]:
            self = .array(arr.map { YAMLValue(foundation: $0) })
        case let dict as [String: Any]:
            self = .object(dict.map { YAMLValue.Member(key: $0.key, value: YAMLValue(foundation: $0.value)) })
        case let n as NSNumber:
            self = YAMLValue(nsNumber: n)
        default:
            self = .string(String(describing: object))
        }
    }

    /// Swift `Bool`, `Int` and `Double` all bridge to `NSNumber`, so recognising a boolean first is
    /// what keeps `1` from decoding as `true`.
    private init(nsNumber n: NSNumber) {
        if n.isBooleanNumber {
            self = .bool(n.boolValue)
            return
        }
        // objCType says whether the boxed value is itself an integer, which is exact where the
        // magnitude check below is not: a Double only carries 53 bits of precision, so by the
        // time a huge value has been read out through doubleValue it may already have lost the
        // digits that would tell 10000000000000001 apart from 10000000000000000.
        switch String(cString: n.objCType) {
        case "c", "s", "i", "l", "q", "C", "S", "I":
            if let i = Int(exactly: n.int64Value) { self = .int(i); return }
        case "L", "Q":
            if let i = Int(exactly: n.uint64Value) { self = .int(i); return }
            self = .uint(n.uint64Value)
            return
        default:
            break
        }
        let d = n.doubleValue
        if d.rounded() == d, abs(d) < 1e16 {
            self = .int(n.intValue)
        } else {
            self = .double(d)
        }
    }
}
