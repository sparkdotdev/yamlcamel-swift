import Foundation
import Testing
@testable import YAMLCamel

/// A deterministic 64-bit generator, so a failing case is reproducible from its seed alone.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Builds YAML values and byte soup from a seeded generator.
struct Generator {
    var rng: SplitMix64

    init(seed: UInt64) { rng = SplitMix64(seed: seed) }

    mutating func int(_ range: Range<Int>) -> Int { Int.random(in: range, using: &rng) }
    mutating func bool() -> Bool { Bool.random(using: &rng) }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(0 ..< xs.count)] }

    /// Characters chosen to land on the parts of the grammar that decide quoting.
    private static let alphabet: [Character] = Array(
        "abcXYZ019 \t\n\r:#-?,[]{}&*!|>'\"%@`\\/.~_\u{00A0}\u{0085}\u{2028}éßж漢🐫"
    )

    mutating func text(maxLength: Int = 12) -> String {
        let n = int(0 ..< (maxLength + 1))
        var s = ""
        for _ in 0 ..< n { s.append(Generator.alphabet[int(0 ..< Generator.alphabet.count)]) }
        return s
    }

    /// A word that is likely to collide with core schema resolution.
    mutating func loadedText() -> String {
        pick(["true", "False", "NULL", "~", "null", "", " ", "  x  ", "0", "-1", "0x1F", "0o17",
              "1.5", ".inf", ".nan", "-.INF", "1e3", "2.4.1", "on", "yes", "no", "off",
              "---", "...", "- x", "? x", ": x", "#c", "a: b", "a #c", "*a", "&a", "!t",
              "9223372036854775807", "-9223372036854775808", "99999999999999999999",
              "20:03:20", "2002-12-14", "C#", "-ban/-ben", "a\nb", "a\tb", "\u{85}x"])
    }

    mutating func scalar() -> YAMLValue {
        switch int(0 ..< 9) {
        case 0: return .null
        case 1: return .bool(bool())
        case 2: return .int(int(-1_000_000 ..< 1_000_000))
        case 3: return .int(pick([Int.min, Int.max, 0, -1, 1]))
        case 4: return .double(Double(int(-10_000 ..< 10_000)) / 8.0)
        case 5: return .double(pick([0.0, -0.0, 0.5, -2.5, 1e16, -1e-8, .infinity, -.infinity]))
        case 6: return .string(loadedText())
        // Anything at or below Int64.max reads back as .int, so only genuinely oversized values here.
        case 7: return .uint(pick([UInt64.max, UInt64.max - 1, UInt64(Int64.max) + 1, UInt64(Int64.max) + 2]))
        default: return .string(text())
        }
    }

    /// A value tree with unique keys per mapping, since YAML 1.2.2 makes a repeated key an error.
    mutating func value(depth: Int = 0) -> YAMLValue {
        if depth >= 3 || int(0 ..< 10) < 5 { return scalar() }
        if bool() {
            let n = int(0 ..< 4)
            return .array((0 ..< n).map { _ in value(depth: depth + 1) })
        }
        let n = int(0 ..< 4)
        var members: [YAMLValue.Member] = []
        var used = Set<String>()
        for _ in 0 ..< n {
            var key = bool() ? loadedText() : text()
            var suffix = 0
            while used.contains(key) { suffix += 1; key = "\(key)~\(suffix)" }
            used.insert(key)
            members.append(.init(key: key, value: value(depth: depth + 1)))
        }
        return .object(members)
    }

    mutating func bytes(maxLength: Int = 200) -> [UInt8] {
        let n = int(0 ..< (maxLength + 1))
        return (0 ..< n).map { _ in UInt8(int(0 ..< 256)) }
    }

    /// Byte soup biased toward YAML punctuation, which reaches the grammar rather than bouncing off it.
    mutating func yamlSoup(maxLength: Int = 200) -> String {
        let pieces = ["- ", "? ", ": ", "[", "]", "{", "}", ",", "#", "|", ">", "&a", "*a", "!!str",
                      "---", "...", "\n", "  ", "\t", "'", "\"", "\\", "%YAML 1.2", "%TAG ! x",
                      "a", "1", "\u{0}", "\u{FEFF}", "é", "\u{2028}"]
        let n = int(0 ..< (maxLength + 1))
        var s = ""
        for _ in 0 ..< n { s += pick(pieces) }
        return s
    }
}

@Suite("Generated properties")
struct PropertyTests {

    /// Changing this changes every generated case, so a run that failed can be reproduced by
    /// setting it back. Nothing here reads the clock or an unseeded source.
    static let baseSeed: UInt64 = 0x59414D_4C43414D

    private static func seed(_ property: UInt64, _ index: Int) -> UInt64 {
        baseSeed &+ (property &* 0x1000_0000) &+ UInt64(index)
    }

    // MARK: - Round tripping

    @Test("anything the emitter writes, the parser reads back to an equal value")
    func emitterOutputRoundTrips() throws {
        for index in 0 ..< 4_000 {
            let s = Self.seed(1, index)
            var gen = Generator(seed: s)
            let original = gen.value()
            let text = try YAML.emit(original)
            do {
                let reparsed = try YAMLParser.parse(text)
                if reparsed != original {
                    Issue.record("""
                    Round trip changed the value. Reproduce with seed \(s).
                    original: \(original)
                    emitted:
                    \(text)
                    reparsed: \(reparsed)
                    """)
                    return
                }
            } catch {
                Issue.record("""
                Emitted text did not parse. Reproduce with seed \(s).
                error: \(error)
                emitted:
                \(text)
                """)
                return
            }
        }
    }

    @Test("sorted output round trips too, and does not depend on member order")
    func sortedOutputRoundTrips() throws {
        for index in 0 ..< 2_000 {
            let s = Self.seed(2, index)
            var gen = Generator(seed: s)
            let original = gen.value()
            let text = try YAML.emit(original, sortKeys: true)
            do {
                let reparsed = try YAMLParser.parse(text)
                if try YAML.emit(reparsed, sortKeys: true) != text {
                    Issue.record("Sorted round trip is not stable. Reproduce with seed \(s).\n\(text)")
                    return
                }
            } catch {
                Issue.record("Sorted output did not parse. Reproduce with seed \(s).\n\(error)\n\(text)")
                return
            }
        }
    }

    /// Keys are generated separately because the asymmetry between keys and values is exactly what
    /// hid a quoting bug: 10,888 failures in 200,000 random keys against none for values.
    @Test("a mapping key survives the round trip whatever is in it")
    func keysRoundTrip() throws {
        for index in 0 ..< 20_000 {
            let s = Self.seed(3, index)
            var gen = Generator(seed: s)
            let key = gen.bool() ? gen.loadedText() : gen.text(maxLength: 8)
            let original = YAMLValue.object([.init(key: key, value: .int(1))])
            let text = try YAML.emit(original)
            do {
                let reparsed = try YAMLParser.parse(text)
                if reparsed != original {
                    Issue.record("""
                    Key did not survive. Reproduce with seed \(s).
                    key: \(String(reflecting: key))
                    emitted: \(String(reflecting: text))
                    reparsed: \(reparsed)
                    """)
                    return
                }
            } catch {
                Issue.record("""
                Emitted key did not parse. Reproduce with seed \(s).
                key: \(String(reflecting: key))
                emitted: \(String(reflecting: text))
                error: \(error)
                """)
                return
            }
        }
    }

    @Test("a Codable value survives an encode and decode")
    func codableRoundTrips() throws {
        struct Row: Codable, Equatable {
            var name: String
            var count: Int
            var big: UInt64
            var ratio: Double
            var flag: Bool
            var tags: [String]
            var note: String?
        }
        for index in 0 ..< 2_000 {
            let s = Self.seed(4, index)
            var gen = Generator(seed: s)
            // Full-range so roughly half the runs land above Int64.max, where .uint has to carry it.
            let big = gen.rng.next()
            let original = Row(name: gen.bool() ? gen.loadedText() : gen.text(),
                               count: gen.int(-100_000 ..< 100_000),
                               big: big,
                               ratio: Double(gen.int(-1000 ..< 1000)) / 4.0,
                               flag: gen.bool(),
                               tags: (0 ..< gen.int(0 ..< 4)).map { _ in gen.loadedText() },
                               note: gen.bool() ? nil : gen.text())
            do {
                let text = try YAMLEncoder().encode(original)
                let back = try YAMLDecoder().decode(Row.self, from: text)
                if back != original {
                    Issue.record("Codable round trip changed the value. Reproduce with seed \(s).\n\(text)")
                    return
                }
            } catch {
                Issue.record("Codable round trip threw. Reproduce with seed \(s).\n\(error)")
                return
            }
        }
    }

    // MARK: - Robustness

    @Test("arbitrary bytes produce a value or a parse error, and nothing else")
    func arbitraryBytesNeverCrash() throws {
        for index in 0 ..< 20_000 {
            let s = Self.seed(5, index)
            var gen = Generator(seed: s)
            let text = String(decoding: gen.bytes(), as: UTF8.self)
            do {
                _ = try YAMLParser.parseStream(text)
            } catch is YAMLParseError {
                continue
            } catch {
                Issue.record("Unexpected error type. Reproduce with seed \(s).\n\(error)")
                return
            }
        }
    }

    @Test("byte soup made of YAML punctuation produces a value or a parse error")
    func yamlSoupNeverCrashes() throws {
        for index in 0 ..< 20_000 {
            let s = Self.seed(6, index)
            var gen = Generator(seed: s)
            let text = gen.yamlSoup()
            do {
                _ = try YAMLParser.parseStream(text)
            } catch is YAMLParseError {
                continue
            } catch {
                Issue.record("Unexpected error type. Reproduce with seed \(s).\n\(error)")
                return
            }
        }
    }

    /// Emitting a value and parsing it again has to give the same value, whatever the value came
    /// from. This is what caught a byte order mark inside a scalar being eaten on re-read.
    @Test("anything that parses survives being emitted and parsed again")
    func parseEmitParseIsIdempotent() throws {
        for index in 0 ..< 20_000 {
            let s = Self.seed(10, index)
            var gen = Generator(seed: s)
            let text = gen.yamlSoup(maxLength: 40)
            guard let first = try? YAMLParser.parse(text) else { continue }
            let emitted = try YAML.emit(first)
            do {
                let second = try YAMLParser.parse(emitted)
                if second != first {
                    Issue.record("""
                    Emitting and parsing changed the value. Reproduce with seed \(s).
                    source: \(String(reflecting: text))
                    first: \(first)
                    emitted: \(String(reflecting: emitted))
                    second: \(second)
                    """)
                    return
                }
            } catch {
                Issue.record("""
                Emitted text did not parse. Reproduce with seed \(s).
                source: \(String(reflecting: text))
                emitted: \(String(reflecting: emitted))
                error: \(error)
                """)
                return
            }
        }
    }

    @Test("parsing the same input twice gives the same answer")
    func parsingIsDeterministic() throws {
        for index in 0 ..< 10_000 {
            let s = Self.seed(7, index)
            var gen = Generator(seed: s)
            let text = gen.bool() ? gen.yamlSoup(maxLength: 60) : try YAML.emit(gen.value())

            let first = Result { try YAMLParser.parseStream(text) }
            let second = Result { try YAMLParser.parseStream(text) }

            switch (first, second) {
            case (.success(let a), .success(let b)):
                if a != b { Issue.record("Two parses disagreed. Reproduce with seed \(s).\n\(text)"); return }
            case (.failure(let a as YAMLParseError), .failure(let b as YAMLParseError)):
                if a != b { Issue.record("Two parses failed differently. Reproduce with seed \(s).\n\(text)"); return }
            default:
                Issue.record("One parse succeeded and the other did not. Reproduce with seed \(s).\n\(text)")
                return
            }
        }
    }

    @Test("every truncation of a valid document is a value or a parse error")
    func truncationNeverCrashes() throws {
        for index in 0 ..< 3_000 {
            let s = Self.seed(8, index)
            var gen = Generator(seed: s)
            let text = try YAML.emit(gen.value())
            let scalars = Array(text.unicodeScalars)
            guard !scalars.isEmpty else { continue }
            let cut = gen.int(0 ..< scalars.count)
            var prefix = ""
            prefix.unicodeScalars.append(contentsOf: scalars[0 ..< cut])
            do {
                _ = try YAMLParser.parseStream(prefix)
            } catch is YAMLParseError {
                continue
            } catch {
                Issue.record("Unexpected error type on a truncation. Reproduce with seed \(s).\n\(error)")
                return
            }
        }
    }

    @Test("flipping one byte of a valid document never crashes the parser")
    func mutationNeverCrashes() throws {
        for index in 0 ..< 5_000 {
            let s = Self.seed(9, index)
            var gen = Generator(seed: s)
            var bytes = Array(try YAML.emit(gen.value()).utf8)
            guard !bytes.isEmpty else { continue }
            let at = gen.int(0 ..< bytes.count)
            bytes[at] = UInt8(gen.int(0 ..< 256))
            do {
                _ = try YAMLParser.parseStream(String(decoding: bytes, as: UTF8.self))
            } catch is YAMLParseError {
                continue
            } catch {
                Issue.record("Unexpected error type on a mutation. Reproduce with seed \(s).\n\(error)")
                return
            }
        }
    }
}
