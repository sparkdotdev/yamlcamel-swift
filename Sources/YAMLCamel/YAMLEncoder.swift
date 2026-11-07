import Foundation

/// Encodes `Encodable` values to block-style YAML text.
///
/// A `YAMLValue` tree is built from the value and then rendered by `YAMLEmitter`. Scalar types are
/// preserved along the way, so an `Int` emits as `1` rather than `1.0`.
public final class YAMLEncoder {
    public struct Options {
        /// Emit mapping keys in sorted order, for output that does not depend on insertion order.
        public var sortKeys: Bool = false
        public init() {}
    }

    public var options = Options()

    /// Bounds applied while writing. Throws `YAMLEmitError` when the value crosses them.
    public var limits: YAMLEmitLimits

    /// Creates an encoder. Pass your own limits to bound what it will write.
    public init(limits: YAMLEmitLimits = .default) {
        self.limits = limits
    }

    public func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = _YAMLEncoder()
        try value.encode(to: encoder)
        let root = encoder.storage.popLast()?.finalized ?? .object([])
        return try YAMLEmitter(sortKeys: options.sortKeys, limits: limits).emit(root)
    }
}

// MARK: - Reference-typed build storage

/// A node still under construction. Arrays and objects are reference types so a container can keep
/// mutating the same node its parent already holds.
enum YAMLBuildNode {
    case value(YAMLValue)
    case array(YAMLRefArray)
    case object(YAMLRefObject)
    case encoder(_YAMLEncoder)

    var finalized: YAMLValue {
        switch self {
        case .value(let v): return v
        case .array(let a): return .array(a.items.map { $0.finalized })
        case .object(let o): return .object(o.order.map { YAMLValue.Member(key: $0, value: o.map[$0]!.finalized) })
        case .encoder(let encoder): return encoder.storage.last?.finalized ?? .object([])
        }
    }
}

final class YAMLRefArray {
    var items: [YAMLBuildNode] = []
    func append(_ node: YAMLBuildNode) { items.append(node) }
}

final class YAMLRefObject {
    var order: [String] = []
    var map: [String: YAMLBuildNode] = [:]
    func set(_ key: String, _ node: YAMLBuildNode) {
        if map[key] == nil { order.append(key) }
        map[key] = node
    }
}

// MARK: - Encoder

final class _YAMLEncoder: Encoder {
    var codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any]
    var storage: [YAMLBuildNode] = []

    init(codingPath: [CodingKey] = [], userInfo: [CodingUserInfoKey: Any] = [:]) {
        self.codingPath = codingPath
        self.userInfo = userInfo
    }

    /// True while this encoder has not yet produced its single root node. Keying off emptiness
    /// matters because `box(_:)` seeds a sub-encoder with the parent's coding path but no storage.
    private var canEncodeNewValue: Bool { storage.isEmpty }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        let ref: YAMLRefObject
        if canEncodeNewValue {
            ref = YAMLRefObject()
            storage.append(.object(ref))
        } else if case .object(let existing)? = storage.last {
            ref = existing
        } else {
            preconditionFailure("Requested a keyed container after a value was already encoded here.")
        }
        return KeyedEncodingContainer(YAMLKeyedEncodingContainer(encoder: self, ref: ref, codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        let ref: YAMLRefArray
        if canEncodeNewValue {
            ref = YAMLRefArray()
            storage.append(.array(ref))
        } else if case .array(let existing)? = storage.last {
            ref = existing
        } else {
            preconditionFailure("Requested an unkeyed container after a value was already encoded here.")
        }
        return YAMLUnkeyedEncodingContainer(encoder: self, ref: ref, codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer { self }

    /// Encodes a nested value in its own sub-encoder and returns the single node it produced.
    func box<T: Encodable>(_ value: T) throws -> YAMLBuildNode {
        let sub = _YAMLEncoder(codingPath: codingPath, userInfo: userInfo)
        try value.encode(to: sub)
        return sub.storage.popLast() ?? .object(YAMLRefObject())
    }
}

// MARK: - Integer boxing

func yamlBox<T: BinaryInteger>(_ value: T) -> YAMLValue {
    if let i = Int(exactly: value) { return .int(i) }
    if let u = UInt64(exactly: value) { return .uint(u) }
    return .double(Double(value))
}

// MARK: - _YAMLEncoder as SingleValueEncodingContainer

extension _YAMLEncoder: SingleValueEncodingContainer {
    private func push(_ v: YAMLValue) { storage.append(.value(v)) }

    func encodeNil() throws { push(.null) }
    func encode(_ value: Bool) throws { push(.bool(value)) }
    func encode(_ value: String) throws { push(.string(value)) }
    func encode(_ value: Double) throws { push(.double(value)) }
    func encode(_ value: Float) throws { push(.double(Double(value))) }
    func encode(_ value: Int) throws { push(.int(value)) }
    func encode(_ value: Int8) throws { push(yamlBox(value)) }
    func encode(_ value: Int16) throws { push(yamlBox(value)) }
    func encode(_ value: Int32) throws { push(yamlBox(value)) }
    func encode(_ value: Int64) throws { push(yamlBox(value)) }
    func encode(_ value: UInt) throws { push(yamlBox(value)) }
    func encode(_ value: UInt8) throws { push(yamlBox(value)) }
    func encode(_ value: UInt16) throws { push(yamlBox(value)) }
    func encode(_ value: UInt32) throws { push(yamlBox(value)) }
    func encode(_ value: UInt64) throws { push(yamlBox(value)) }
    func encode<T: Encodable>(_ value: T) throws { storage.append(try box(value)) }
}

// MARK: - Keyed container

private struct YAMLKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: _YAMLEncoder
    let ref: YAMLRefObject
    var codingPath: [CodingKey]

    private func set(_ key: Key, _ v: YAMLValue) { ref.set(key.stringValue, .value(v)) }

    mutating func encodeNil(forKey key: Key) throws { set(key, .null) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { set(key, .bool(value)) }
    mutating func encode(_ value: String, forKey key: Key) throws { set(key, .string(value)) }
    mutating func encode(_ value: Double, forKey key: Key) throws { set(key, .double(value)) }
    mutating func encode(_ value: Float, forKey key: Key) throws { set(key, .double(Double(value))) }
    mutating func encode(_ value: Int, forKey key: Key) throws { set(key, .int(value)) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { set(key, yamlBox(value)) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { set(key, yamlBox(value)) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { set(key, yamlBox(value)) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { set(key, yamlBox(value)) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { set(key, yamlBox(value)) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { set(key, yamlBox(value)) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { set(key, yamlBox(value)) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { set(key, yamlBox(value)) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { set(key, yamlBox(value)) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        ref.set(key.stringValue, try encoder.box(value))
    }

    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        let child = YAMLRefObject()
        ref.set(key.stringValue, .object(child))
        return KeyedEncodingContainer(YAMLKeyedEncodingContainer<NestedKey>(encoder: encoder, ref: child, codingPath: codingPath + [key]))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let child = YAMLRefArray()
        ref.set(key.stringValue, .array(child))
        return YAMLUnkeyedEncodingContainer(encoder: encoder, ref: child, codingPath: codingPath + [key])
    }

    // Returns a fresh encoder rooted at the appropriate coding path.
    mutating func superEncoder() -> Encoder {
        let child = _YAMLEncoder(codingPath: codingPath + [YAMLCodingKey.super], userInfo: encoder.userInfo)
        ref.set(YAMLCodingKey.super.stringValue, .encoder(child))
        return child
    }
    mutating func superEncoder(forKey key: Key) -> Encoder {
        let child = _YAMLEncoder(codingPath: codingPath + [key], userInfo: encoder.userInfo)
        ref.set(key.stringValue, .encoder(child))
        return child
    }
}

// MARK: - Unkeyed container

private struct YAMLUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let encoder: _YAMLEncoder
    let ref: YAMLRefArray
    var codingPath: [CodingKey]
    var count: Int { ref.items.count }

    private func append(_ v: YAMLValue) { ref.append(.value(v)) }

    mutating func encodeNil() throws { append(.null) }
    mutating func encode(_ value: Bool) throws { append(.bool(value)) }
    mutating func encode(_ value: String) throws { append(.string(value)) }
    mutating func encode(_ value: Double) throws { append(.double(value)) }
    mutating func encode(_ value: Float) throws { append(.double(Double(value))) }
    mutating func encode(_ value: Int) throws { append(.int(value)) }
    mutating func encode(_ value: Int8) throws { append(yamlBox(value)) }
    mutating func encode(_ value: Int16) throws { append(yamlBox(value)) }
    mutating func encode(_ value: Int32) throws { append(yamlBox(value)) }
    mutating func encode(_ value: Int64) throws { append(yamlBox(value)) }
    mutating func encode(_ value: UInt) throws { append(yamlBox(value)) }
    mutating func encode(_ value: UInt8) throws { append(yamlBox(value)) }
    mutating func encode(_ value: UInt16) throws { append(yamlBox(value)) }
    mutating func encode(_ value: UInt32) throws { append(yamlBox(value)) }
    mutating func encode(_ value: UInt64) throws { append(yamlBox(value)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        encoder.codingPath.append(YAMLCodingKey(index: count))
        defer { encoder.codingPath.removeLast() }
        ref.append(try encoder.box(value))
    }

    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let child = YAMLRefObject()
        ref.append(.object(child))
        return KeyedEncodingContainer(YAMLKeyedEncodingContainer<NestedKey>(encoder: encoder, ref: child, codingPath: codingPath + [YAMLCodingKey(index: count)]))
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let child = YAMLRefArray()
        ref.append(.array(child))
        return YAMLUnkeyedEncodingContainer(encoder: encoder, ref: child, codingPath: codingPath + [YAMLCodingKey(index: count)])
    }

    // Returns a fresh encoder rooted at the appropriate coding path.
    mutating func superEncoder() -> Encoder {
        let child = _YAMLEncoder(codingPath: codingPath + [YAMLCodingKey(index: count)], userInfo: encoder.userInfo)
        ref.append(.encoder(child))
        return child
    }
}
