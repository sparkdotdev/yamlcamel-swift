import Foundation
import XCTest
@testable import YAMLCamel

final class AuditRegressionTests: XCTestCase {
    func testUntypedUnsignedIntegersRoundTripExactly() throws {
        for value in [UInt64(Int.max) + 1, UInt64.max] {
            let text = try YAML.dump(object: ["id": value])
            XCTAssertEqual(try YAMLDecoder().decode([String: UInt64].self, from: text)["id"], value)
        }
    }

    func testMalformedBytesAndRawControlsAreRefused() throws {
        XCTAssertThrowsError(try YAMLDecoder().decode(String.self, from: Data([0x22, 0xFF, 0x22])))
        XCTAssertThrowsError(try YAMLParser.parse("key: a\u{0}b"))
        XCTAssertEqual(try YAMLParser.parse("\"a\\0b\""), .string("a\u{0}b"))
        let reader = YAMLByteSequenceReader<String>()
        XCTAssertThrowsError(try reader.push([0x2D, 0x20, 0x22, 0xFF, 0x22, 0x0A]) + reader.finish())
    }

    func testQuotedContinuationsRejectDocumentMarkers() throws {
        for text in ["key: \"one\n---\ntwo\"", "\"one\n...\ntwo\""] {
            XCTAssertThrowsError(try YAMLParser.parse(text))
        }
        XCTAssertEqual(try YAMLParser.parse("key: \"one\n  two\""), .object([.init(key: "key", value: .string("one two"))]))
        XCTAssertEqual(try YAMLParser.parse("\"one\ntwo\""), .string("one two"))
    }

    func testEmitterEscapesEveryForbiddenUnicodeRange() throws {
        for value in ["\u{80}", "\u{9F}", "\u{FFFE}", "\u{FFFF}"] {
            let text = try YAML.emit(.string(value))
            XCTAssertTrue(text.hasPrefix("\"\\u"))
            XCTAssertEqual(try YAMLParser.parse(text), .string(value))
        }
    }

    func testDuplicateObjectMembersCannotEmitAmbiguousYAML() {
        let duplicate: YAMLValue = .object([.init(key: "a", value: .int(1)), .init(key: "a", value: .int(2))])
        XCTAssertThrowsError(try YAML.emit(duplicate)) { error in
            XCTAssertEqual((error as? YAMLEmitError)?.kind, .duplicateKey)
        }
        XCTAssertThrowsError(try YAML.emit(.array([duplicate])))
    }
    func testEmptyRootsCountTowardsNodeLimit() {
        for value: YAMLValue in [.array([]), .object([])] {
            XCTAssertThrowsError(try YAML.emit(value, limits: YAMLEmitLimits(maxNodes: 0)))
        }
    }

    func testSuperEncodersKeepSuperclassValuesWithoutASuperCodingKeyCase() throws {
        class Base: Encodable {
            enum Keys: String, CodingKey { case inherited }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: Keys.self)
                try container.encode(7, forKey: .inherited)
            }
        }
        final class Child: Base {
            enum Keys: String, CodingKey { case own, base }
            override func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: Keys.self)
                try container.encode(9, forKey: .own)
                try super.encode(to: container.superEncoder())
                try super.encode(to: container.superEncoder(forKey: .base))
            }
        }
        let value = try YAMLParser.parse(YAMLEncoder().encode(Child()))
        let inherited: YAMLValue = .object([.init(key: "inherited", value: .int(7))])
        XCTAssertEqual(value["super"], inherited)
        XCTAssertEqual(value["base"], inherited)
        XCTAssertEqual(value["own"], .int(9))
        struct List: Encodable {
            func encode(to encoder: Encoder) throws {
                var container = encoder.unkeyedContainer()
                try Base().encode(to: container.superEncoder())
                try container.encode("tail")
            }
        }
        XCTAssertEqual(try YAMLParser.parse(YAMLEncoder().encode(List())), .array([inherited, .string("tail")]))
    }

    func testFileReadersSkipBufferedValuesAndCloseOnAbandonmentOrError() throws {
        final class Handle: YAMLFileHandle {
            var reads = 0
            var closes = 0
            func read(_ count: Int) throws -> Data {
                reads += 1
                return reads == 1 ? Data([1]) : Data()
            }
            func close() { closes += 1 }
        }
        final class Inner: YAMLChunkReader {
            typealias Element = Int
            var fail = false
            func push(_ data: Data) throws -> [Int] {
                if fail { throw YAMLParseError("synthetic") }
                return [1,2,3]
            }
            func finish() throws -> [Int] { [] }
            func skip(_ n: Int) {}
        }
        let handle = Handle()
        var reader: YAMLFileSequenceReader<Inner>? = YAMLFileSequenceReader(handle: handle, chunkSize: 1, inner: Inner())
        XCTAssertEqual(try reader?.next(), 1)
        reader?.skip(1)
        XCTAssertEqual(try reader?.next(), 3)
        reader = nil
        XCTAssertEqual(handle.closes, 1)
        let failedHandle = Handle()
        let failing = Inner(); failing.fail = true
        let failedReader = YAMLFileSequenceReader(handle: failedHandle, chunkSize: 1, inner: failing)
        XCTAssertThrowsError(try failedReader.next())
        XCTAssertEqual(failedHandle.closes, 1)
    }

    func testRawCharacterContextsFollowPrintableAndQuotedJSONProductions() throws {
        for code: UInt32 in [0x7F, 0x80, 0x9F, 0xFFFE, 0xFFFF] {
            let raw = String(Unicode.Scalar(code)!)
            for input in [raw, "key: " + raw, "key: |\n  " + raw + "\n", "# " + raw, "&a" + raw + " value", "!tag" + raw + " value", "%TAG !t! tag:" + raw + "\n---\nvalue"] {
                XCTAssertThrowsError(try YAMLParser.parse(input), "context accepted \(code)")
            }
            XCTAssertEqual(try YAMLParser.parse("\"" + raw + "\""), .string(raw))
            XCTAssertEqual(try YAMLParser.parse("'" + raw + "'"), .string(raw))
            XCTAssertEqual(try YAMLParser.parse(String(format: "\"\\u%04X\"", code)), .string(raw))
        }
        XCTAssertEqual(try YAMLParser.parse("a\u{85}b"), .string("a\u{85}b"))
    }

    func testIndentationUsesSpacesWithoutConsumingQuotedOrBlockContentTabs() throws {
        for input in ["key: \"one\ntwo\"", "- name: \"a\n- b\"", "key: \"one\\\ntwo\"", "a:\n\tb: 1\n", "a:\n \tb: 1\n", "\t- one", "\u{FEFF} \t- one", "-\t- one", "a:\n\t\"value\""] {
            XCTAssertThrowsError(try YAMLParser.parse(input), input)
        }
        XCTAssertEqual(try YAMLParser.parse("  \"one\ntwo\""), .string("one two"))
        XCTAssertEqual(try YAMLParser.parse("key:\n   \"one\n \ttwo\"" )["key"], .string("one two"))
        XCTAssertEqual(try YAMLParser.parse("key: \"one\\\n \ttwo\"" )["key"], .string("onetwo"))
        XCTAssertEqual(try YAMLParser.parse("key: |2\n  \tcontent\n" )["key"], .string("\tcontent\n"))
        XCTAssertEqual(try YAMLParser.parse("key: |2+\n  \t\n" )["key"], .string("\t\n"))
    }

    func testBlockChompingPreservesActualEOFBreaksAndTrailingBlankLines() throws {
        for style in ["|", ">"] {
            for chomp in ["", "+", "-"] {
                let head = "key: " + style + chomp + "\n"
                XCTAssertEqual(try YAMLParser.parse(head + "  a")["key"], .string("a"))
                XCTAssertEqual(try YAMLParser.parse(head + "  a\n")["key"], .string(chomp == "-" ? "a" : "a\n"))
                XCTAssertEqual(try YAMLParser.parse(head + "  a\n\n")["key"], .string(chomp == "+" ? "a\n\n" : chomp == "-" ? "a" : "a\n"))
                XCTAssertEqual(try YAMLParser.parse(head + "  a\n\n  ")["key"], .string(chomp == "+" ? "a\n\n" : chomp == "-" ? "a" : "a\n"))
                XCTAssertEqual(try YAMLParser.parse(head + "  ")["key"], .string(""))
            }
        }
    }

    func testMalformedUTF8CommentAndSequenceCannotBeComparedWithRepairedText() throws {
        let bytes: [UInt8] = [0x23, 0x20, 0xFF, 0x0A, 0x2D, 0x20, 0xFF, 0x0A]
        let data = Data(bytes)
        XCTAssertNil(String(data: data, encoding: .utf8))
        let repaired = String(decoding: bytes, as: UTF8.self)
        XCTAssertEqual(try YAMLDecoder().decode([String].self, from: repaired), ["\u{FFFD}"])
        XCTAssertThrowsError(try YAMLDecoder().decode([String].self, from: data)) { error in
            XCTAssertEqual((error as? YAMLParseError)?.kind, .syntax)
        }
        for chunkSize in [1, 2, 3, bytes.count] {
            let reader = YAMLByteSequenceReader<String>()
            XCTAssertThrowsError(try {
                var offset = 0
                while offset < bytes.count {
                    let end = min(offset + chunkSize, bytes.count)
                    _ = try reader.push(Array(bytes[offset..<end]))
                    offset = end
                }
                _ = try reader.finish()
            }()) { error in
                XCTAssertEqual((error as? YAMLParseError)?.kind, .syntax)
            }
        }
        var limits = YAMLLimits.default
        limits.maxInputBytes = bytes.count - 1
        XCTAssertThrowsError(try YAMLDecoder(limits: limits).decode([String].self, from: data)) { error in
            XCTAssertEqual((error as? YAMLParseError)?.kind, .inputTooLarge)
        }
        let bounded = YAMLByteSequenceReader<String>(limits: limits)
        XCTAssertThrowsError(try bounded.push(bytes)) { error in
            XCTAssertEqual((error as? YAMLParseError)?.kind, .inputTooLarge)
        }
    }

    func testSequenceReadersPreserveBlockScalarEOFAtEveryByteBoundary() throws {
        let decoder = YAMLDecoder()
        for style in ["|", ">"] {
            for chomp in ["", "+", "-"] {
                for tail in ["", "\n", "\n\n", "\n  ", "\n  \n"] {
                    for ending in ["\n", "\r", "\r\n"] {
                        let input = ("# streamed EOF\n- first\n- " + style + chomp + "\n  héllo 😀" + tail)
                            .replacingOccurrences(of: "\n", with: ending)
                        let whole = try decoder.decode([String].self, from: input)
                        let fromText = try decoder.sequenceReader(String.self, from: input)
                        var pulled: [String] = []
                        while let value = try fromText.next() { pulled.append(value) }
                        XCTAssertEqual(pulled, whole)
                        let bytes = Array(input.utf8)
                        for split in 0...bytes.count {
                            let reader = YAMLByteSequenceReader<String>()
                            var streamed = try reader.push(Array(bytes[..<split]))
                            streamed += try reader.push(Array(bytes[split...]))
                            streamed += try reader.finish()
                            XCTAssertEqual(streamed, whole, "header=\(style)\(chomp), split=\(split), ending=\(String(reflecting: ending)), tail=\(String(reflecting: tail))")
                        }
                    }
                }
            }
        }
        let minimal = "- |\n  literal EOF"
        let reader = YAMLByteSequenceReader<String>()
        XCTAssertEqual(try reader.push(Data(minimal.utf8)) + reader.finish(), ["literal EOF"])
    }

}
