import Foundation

/// Decodes `Decodable` values from YAML text in a single parsing pass.
///
/// The text is scanned once into a `YAMLValue` tree that the decoder reads directly, with no
/// intermediate JSON anywhere.
public final class YAMLDecoder {

    /// Bounds applied while parsing. Lower them for input you did not produce.
    public var limits: YAMLLimits

    /// Creates a decoder. Pass your own limits to tighten or loosen what the parser accepts.
    public init(limits: YAMLLimits = .default) {
        self.limits = limits
    }

    /// Decode `type` from a YAML string.
    ///
    /// Text that is not valid YAML, or that crosses a limit, throws `YAMLParseError` unwrapped, so a
    /// caller can tell a refusal on size apart from a document of the wrong shape. A document that
    /// parses but does not match the type throws `DecodingError` as usual.
    public func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        let root = try YAMLParser.parse(string, limits: limits)
        return try T(from: _YAMLDecoder(root))
    }

    /// Decode `type` from UTF-8 YAML data.
    ///
    /// The byte count is checked before the data is turned into a `String`, not after: that
    /// conversion walks and copies the whole thing, so a bound only enforced once it is a `String`
    /// has already paid for the data it was meant to refuse. This is the same shape as data read
    /// from a file or a gzipped body, both of which reach this overload too.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= limits.maxInputBytes else {
            throw YAMLParseError("Input is \(data.count) bytes, over the \(limits.maxInputBytes) byte limit.",
                                 kind: .inputTooLarge)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw YAMLParseError("Input is not valid UTF-8.", kind: .syntax)
        }
        return try decode(type, from: text)
    }

    /// Decode a `Decodable` from an already-parsed node. The streaming readers use this one item at
    /// a time.
    static func decodeValue<T: Decodable>(_ type: T.Type, from value: YAMLValue) throws -> T {
        try T(from: _YAMLDecoder(value))
    }
}

// MARK: - CodingKey used for unkeyed indices

struct YAMLCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    init(index: Int) { self.stringValue = "Index \(index)"; self.intValue = index }
    static let `super` = YAMLCodingKey(stringValue: "super")!
}

// MARK: - Decoder

final class _YAMLDecoder: Decoder {
    let value: YAMLValue
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any]

    init(_ value: YAMLValue, codingPath: [CodingKey] = [], userInfo: [CodingUserInfoKey: Any] = [:]) {
        self.value = value
        self.codingPath = codingPath
        self.userInfo = userInfo
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let members) = value else {
            throw DecodingError.typeMismatch([String: Any].self, expectation(members: true))
        }
        return KeyedDecodingContainer(YAMLKeyedDecodingContainer<Key>(decoder: self, members: members))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case .array(let elements) = value else {
            throw DecodingError.typeMismatch([Any].self, expectation(members: false))
        }
        return YAMLUnkeyedDecodingContainer(decoder: self, elements: elements)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        YAMLSingleValueDecodingContainer(decoder: self, value: value)
    }

    private func expectation(members: Bool) -> DecodingError.Context {
        DecodingError.Context(codingPath: codingPath,
                              debugDescription: "Expected a \(members ? "mapping" : "sequence") but found \(value.debugTypeName).")
    }
}

// MARK: - Scalar unboxing (shared by every container)

extension _YAMLDecoder {
    static func unboxBool(_ value: YAMLValue, path: [CodingKey]) throws -> Bool {
        guard case .bool(let b) = value else { throw mismatch(Bool.self, value, path) }
        return b
    }

    static func unboxString(_ value: YAMLValue, path: [CodingKey]) throws -> String {
        guard case .string(let s) = value else { throw mismatch(String.self, value, path) }
        return s
    }

    static func unboxInteger<T: FixedWidthInteger>(_ value: YAMLValue, as type: T.Type, path: [CodingKey]) throws -> T {
        switch value {
        case .int(let i):
            guard let r = T(exactly: i) else { throw numberOverflow(type, value, path) }
            return r
        case .uint(let u):
            guard let r = T(exactly: u) else { throw numberOverflow(type, value, path) }
            return r
        case .double(let d):
            guard d.rounded() == d, let r = T(exactly: d) else { throw numberOverflow(type, value, path) }
            return r
        default:
            throw mismatch(type, value, path)
        }
    }

    static func unboxFloat<T: BinaryFloatingPoint>(_ value: YAMLValue, as type: T.Type, path: [CodingKey]) throws -> T {
        switch value {
        case .double(let d): return T(d)
        case .int(let i): return T(i)
        case .uint(let u): return T(u)
        default: throw mismatch(type, value, path)
        }
    }

    static func mismatch(_ type: Any.Type, _ value: YAMLValue, _ path: [CodingKey]) -> DecodingError {
        DecodingError.typeMismatch(type, DecodingError.Context(
            codingPath: path, debugDescription: "Expected \(type) but found \(value.debugTypeName)."))
    }

    static func numberOverflow(_ type: Any.Type, _ value: YAMLValue, _ path: [CodingKey]) -> DecodingError {
        DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: path, debugDescription: "Parsed number does not fit in \(type)."))
    }
}

extension YAMLValue {
    var debugTypeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "a boolean"
        case .int: return "an integer"
        case .uint: return "an integer"
        case .double: return "a double"
        case .string: return "a string"
        case .array: return "a sequence"
        case .object: return "a mapping"
        }
    }
}

// MARK: - Keyed container

private struct YAMLKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: _YAMLDecoder
    let lookup: [String: YAMLValue]
    let orderedKeys: [String]

    init(decoder: _YAMLDecoder, members: [YAMLValue.Member]) {
        self.decoder = decoder
        var lookup = [String: YAMLValue](minimumCapacity: members.count)
        var order: [String] = []
        for m in members {
            if lookup[m.key] == nil { order.append(m.key) }
            lookup[m.key] = m.value          // last value wins for duplicate keys
        }
        self.lookup = lookup
        self.orderedKeys = order
    }

    var codingPath: [CodingKey] { decoder.codingPath }
    var allKeys: [Key] { orderedKeys.compactMap { Key(stringValue: $0) } }

    func contains(_ key: Key) -> Bool { lookup[key.stringValue] != nil }

    private func value(forKey key: Key) throws -> YAMLValue {
        guard let v = lookup[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "No value associated with key \(key.stringValue)."))
        }
        return v
    }

    private var path: [CodingKey] { decoder.codingPath }

    func decodeNil(forKey key: Key) throws -> Bool {
        guard let v = lookup[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "No value associated with key \(key.stringValue)."))
        }
        if case .null = v { return true }
        return false
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try _YAMLDecoder.unboxBool(value(forKey: key), path: path + [key]) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try _YAMLDecoder.unboxString(value(forKey: key), path: path + [key]) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try _YAMLDecoder.unboxFloat(value(forKey: key), as: Double.self, path: path + [key]) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try _YAMLDecoder.unboxFloat(value(forKey: key), as: Float.self, path: path + [key]) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try _YAMLDecoder.unboxInteger(value(forKey: key), as: Int.self, path: path + [key]) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try _YAMLDecoder.unboxInteger(value(forKey: key), as: Int8.self, path: path + [key]) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try _YAMLDecoder.unboxInteger(value(forKey: key), as: Int16.self, path: path + [key]) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try _YAMLDecoder.unboxInteger(value(forKey: key), as: Int32.self, path: path + [key]) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try _YAMLDecoder.unboxInteger(value(forKey: key), as: Int64.self, path: path + [key]) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try _YAMLDecoder.unboxInteger(value(forKey: key), as: UInt.self, path: path + [key]) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try _YAMLDecoder.unboxInteger(value(forKey: key), as: UInt8.self, path: path + [key]) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try _YAMLDecoder.unboxInteger(value(forKey: key), as: UInt16.self, path: path + [key]) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try _YAMLDecoder.unboxInteger(value(forKey: key), as: UInt32.self, path: path + [key]) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try _YAMLDecoder.unboxInteger(value(forKey: key), as: UInt64.self, path: path + [key]) }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let child = _YAMLDecoder(try value(forKey: key), codingPath: path + [key], userInfo: decoder.userInfo)
        return try T(from: child)
    }

    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        let child = _YAMLDecoder(try value(forKey: key), codingPath: path + [key], userInfo: decoder.userInfo)
        return try child.container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        let child = _YAMLDecoder(try value(forKey: key), codingPath: path + [key], userInfo: decoder.userInfo)
        return try child.unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        _YAMLDecoder(lookup[YAMLCodingKey.super.stringValue] ?? .null,
                     codingPath: path + [YAMLCodingKey.super], userInfo: decoder.userInfo)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        _YAMLDecoder(lookup[key.stringValue] ?? .null, codingPath: path + [key], userInfo: decoder.userInfo)
    }
}

// MARK: - Unkeyed container

private struct YAMLUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    let decoder: _YAMLDecoder
    let elements: [YAMLValue]
    var currentIndex: Int = 0

    var codingPath: [CodingKey] { decoder.codingPath }
    var count: Int? { elements.count }
    var isAtEnd: Bool { currentIndex >= elements.count }

    private var indexKey: CodingKey { YAMLCodingKey(index: currentIndex) }
    private var path: [CodingKey] { decoder.codingPath + [indexKey] }

    private mutating func next(_ typeForError: Any.Type) throws -> YAMLValue {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(typeForError, DecodingError.Context(
                codingPath: path, debugDescription: "Unkeyed container is at end."))
        }
        let v = elements[currentIndex]
        currentIndex += 1
        return v
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(Any?.self, DecodingError.Context(
                codingPath: path, debugDescription: "Unkeyed container is at end."))
        }
        if case .null = elements[currentIndex] {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { let p = path; return try _YAMLDecoder.unboxBool(next(type), path: p) }
    mutating func decode(_ type: String.Type) throws -> String { let p = path; return try _YAMLDecoder.unboxString(next(type), path: p) }
    mutating func decode(_ type: Double.Type) throws -> Double { let p = path; return try _YAMLDecoder.unboxFloat(next(type), as: Double.self, path: p) }
    mutating func decode(_ type: Float.Type) throws -> Float { let p = path; return try _YAMLDecoder.unboxFloat(next(type), as: Float.self, path: p) }
    mutating func decode(_ type: Int.Type) throws -> Int { let p = path; return try _YAMLDecoder.unboxInteger(next(type), as: Int.self, path: p) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { let p = path; return try _YAMLDecoder.unboxInteger(next(type), as: Int8.self, path: p) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { let p = path; return try _YAMLDecoder.unboxInteger(next(type), as: Int16.self, path: p) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { let p = path; return try _YAMLDecoder.unboxInteger(next(type), as: Int32.self, path: p) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { let p = path; return try _YAMLDecoder.unboxInteger(next(type), as: Int64.self, path: p) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { let p = path; return try _YAMLDecoder.unboxInteger(next(type), as: UInt.self, path: p) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { let p = path; return try _YAMLDecoder.unboxInteger(next(type), as: UInt8.self, path: p) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { let p = path; return try _YAMLDecoder.unboxInteger(next(type), as: UInt16.self, path: p) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { let p = path; return try _YAMLDecoder.unboxInteger(next(type), as: UInt32.self, path: p) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { let p = path; return try _YAMLDecoder.unboxInteger(next(type), as: UInt64.self, path: p) }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let p = path
        let child = _YAMLDecoder(try next(type), codingPath: p, userInfo: decoder.userInfo)
        return try T(from: child)
    }

    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        let p = path
        let child = _YAMLDecoder(try next([String: Any].self), codingPath: p, userInfo: decoder.userInfo)
        return try child.container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let p = path
        let child = _YAMLDecoder(try next([Any].self), codingPath: p, userInfo: decoder.userInfo)
        return try child.unkeyedContainer()
    }

    mutating func superDecoder() throws -> Decoder {
        let p = path
        return _YAMLDecoder(try next(Decoder.self), codingPath: p, userInfo: decoder.userInfo)
    }
}

// MARK: - Single value container

private struct YAMLSingleValueDecodingContainer: SingleValueDecodingContainer {
    let decoder: _YAMLDecoder
    let value: YAMLValue
    var codingPath: [CodingKey] { decoder.codingPath }

    func decodeNil() -> Bool { if case .null = value { return true }; return false }

    func decode(_ type: Bool.Type) throws -> Bool { try _YAMLDecoder.unboxBool(value, path: codingPath) }
    func decode(_ type: String.Type) throws -> String { try _YAMLDecoder.unboxString(value, path: codingPath) }
    func decode(_ type: Double.Type) throws -> Double { try _YAMLDecoder.unboxFloat(value, as: Double.self, path: codingPath) }
    func decode(_ type: Float.Type) throws -> Float { try _YAMLDecoder.unboxFloat(value, as: Float.self, path: codingPath) }
    func decode(_ type: Int.Type) throws -> Int { try _YAMLDecoder.unboxInteger(value, as: Int.self, path: codingPath) }
    func decode(_ type: Int8.Type) throws -> Int8 { try _YAMLDecoder.unboxInteger(value, as: Int8.self, path: codingPath) }
    func decode(_ type: Int16.Type) throws -> Int16 { try _YAMLDecoder.unboxInteger(value, as: Int16.self, path: codingPath) }
    func decode(_ type: Int32.Type) throws -> Int32 { try _YAMLDecoder.unboxInteger(value, as: Int32.self, path: codingPath) }
    func decode(_ type: Int64.Type) throws -> Int64 { try _YAMLDecoder.unboxInteger(value, as: Int64.self, path: codingPath) }
    func decode(_ type: UInt.Type) throws -> UInt { try _YAMLDecoder.unboxInteger(value, as: UInt.self, path: codingPath) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try _YAMLDecoder.unboxInteger(value, as: UInt8.self, path: codingPath) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try _YAMLDecoder.unboxInteger(value, as: UInt16.self, path: codingPath) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try _YAMLDecoder.unboxInteger(value, as: UInt32.self, path: codingPath) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try _YAMLDecoder.unboxInteger(value, as: UInt64.self, path: codingPath) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try T(from: _YAMLDecoder(value, codingPath: codingPath, userInfo: decoder.userInfo))
    }
}
