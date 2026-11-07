import Foundation
import Testing
@testable import YAMLCamel

/// The bounds the emitter applies, and the asymmetry that made them necessary.
///
/// An alias is cheap for the parser, which shares what it names, and expensive for the emitter,
/// which has to write every copy out. These pin the point where the two come apart.
@Suite("Emit bounds")
struct EmitLimitTests {

    /// The shape libFuzzer timed out on: a chain of anchors each referring several times to the one
    /// before, small enough that the parser is right to accept it.
    private func aliasChain(levels: Int, width: Int) -> String {
        var text = "a: &a [" + Array(repeating: "xx", count: width).joined(separator: ",") + "]\n"
        var previous = "a"
        for name in "bcdefghijklm".prefix(levels) {
            let members = Array(repeating: "*\(previous)", count: width).joined(separator: ",")
            text += "\(name): &\(name) [\(members)]\n"
            previous = String(name)
        }
        return text
    }

    @Test("a document the parser accepts can be refused by the emitter")
    func aliasedDocumentIsRefused() throws {
        let text = aliasChain(levels: 5, width: 10)
        #expect(text.utf8.count < 300, "the input is small on purpose")

        // The parser is right to take it: well inside its own node budget.
        let value = try YAMLParser.parse(text)
        #expect(value.shape.nodes < YAMLLimits.default.maxNodes)

        var error: YAMLEmitError?
        do { _ = try YAML.emit(value) } catch let caught as YAMLEmitError { error = caught }
        #expect(error?.kind == .outputTooLarge || error?.kind == .tooManyNodes)
    }

    @Test("the same value writes out when the bound is lifted, and reads back")
    func permissiveStillWrites() throws {
        // A smaller chain, because the point is that lifting the bound works rather than how long
        // writing sixteen megabytes takes.
        let value = try YAMLParser.parse(aliasChain(levels: 4, width: 8))
        let tight = YAMLEmitLimits(maxOutputBytes: 64 << 10)

        var error: YAMLEmitError?
        do { _ = try YAML.emit(value, limits: tight) } catch let caught as YAMLEmitError { error = caught }
        #expect(error?.kind == .outputTooLarge)

        let emitted = try YAML.emit(value, limits: .permissive)
        #expect(emitted.utf8.count > tight.maxOutputBytes)
        #expect(try YAMLParser.parse(emitted, limits: .permissive) == value)
    }

    @Test("the byte bound stops the write rather than reporting after it")
    func byteBoundStopsEarly() throws {
        let value = try YAMLParser.parse(aliasChain(levels: 5, width: 10))
        let limits = YAMLEmitLimits(maxOutputBytes: 4096, maxNodes: .max)

        let started = Date()
        var error: YAMLEmitError?
        do { _ = try YAML.emit(value, limits: limits) } catch let caught as YAMLEmitError { error = caught }
        let elapsed = Date().timeIntervalSince(started)

        #expect(error?.kind == .outputTooLarge)
        // Writing this value in full takes seconds, so stopping at four kilobytes has to be quick.
        #expect(elapsed < 1)
    }

    @Test("the node bound is applied as nodes are written")
    func nodeBound() throws {
        let value = try YAMLParser.parse(aliasChain(levels: 4, width: 8))
        let limits = YAMLEmitLimits(maxOutputBytes: .max, maxNodes: 1_000)
        var error: YAMLEmitError?
        do { _ = try YAML.emit(value, limits: limits) } catch let caught as YAMLEmitError { error = caught }
        #expect(error?.kind == .tooManyNodes)
    }

    @Test("a hand-built value deeper than the ceiling is refused rather than overflowing the stack")
    func depthBound() throws {
        var value = YAMLValue.string("bottom")
        for _ in 0 ..< 400 { value = .array([value]) }

        var error: YAMLEmitError?
        do { _ = try YAML.emit(value, limits: .permissive) } catch let caught as YAMLEmitError { error = caught }
        #expect(error?.kind == .depthExceeded)
    }

    @Test("an ordinary document is nowhere near the bounds")
    func ordinaryDocumentIsFine() throws {
        let text = (0 ..< 500).map { "- name: row \($0)\n  value: \($0)\n" }.joined()
        let value = try YAMLParser.parse(text)
        let emitted = try YAML.emit(value)
        #expect(try YAMLParser.parse(emitted) == value)
    }

    @Test("the encoder carries the same bounds")
    func encoderHonoursBounds() throws {
        struct Row: Codable { var values: [String] }
        let row = Row(values: (0 ..< 5_000).map { "value \($0)" })

        let encoder = YAMLEncoder(limits: YAMLEmitLimits(maxOutputBytes: 1_000))
        var error: YAMLEmitError?
        do { _ = try encoder.encode(row) } catch let caught as YAMLEmitError { error = caught }
        #expect(error?.kind == .outputTooLarge)

        // The default bounds leave an ordinary value alone.
        #expect(try YAMLEncoder().encode(row).utf8.count > 1_000)
    }

    @Test("the untyped dump carries the same bounds")
    func dumpHonoursBounds() throws {
        let dictionary = ["k": (0 ..< 5_000).map { "value \($0)" }]
        var error: YAMLEmitError?
        do {
            _ = try YAML.dump(object: dictionary, limits: YAMLEmitLimits(maxOutputBytes: 500))
        } catch let caught as YAMLEmitError {
            error = caught
        }
        #expect(error?.kind == .outputTooLarge)
    }

    @Test("the emit byte bound matches the parse byte bound, so output reads back")
    func defaultsLineUp() throws {
        #expect(YAMLEmitLimits.default.maxOutputBytes == YAMLLimits.default.maxInputBytes)
    }

    @Test("shape still lets a caller look before it leaps")
    func shapeIsAvailable() throws {
        let value = try YAMLParser.parse(aliasChain(levels: 5, width: 10))
        #expect(value.shape.nodes > 100_000)
        #expect(value.shape.depth == 8)
    }
}
