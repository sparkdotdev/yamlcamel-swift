import Foundation
import Testing
@testable import YAMLCamel

@Suite("Streaming document-end suffixes")
struct DocumentEndSuffixTests {
    private func stringValues(_ yaml: String) throws -> [String] {
        let reader = try YAMLDecoder().sequenceReader(String.self, from: yaml)
        var values: [String] = []
        while let value = try reader.next() { values.append(value) }
        return values
    }

    private func byteValues(_ yaml: String, chunkSize: Int,
                            limits: YAMLLimits = .default) throws -> [String] {
        let reader = YAMLByteSequenceReader<String>(limits: limits)
        let bytes = Array(yaml.utf8)
        var values: [String] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            values += try reader.push(Array(bytes[offset..<end]))
            offset = end
        }
        values += try reader.finish()
        return values
    }

    @Test("semantic text on the document-end line is rejected before stopping")
    func sameLineSemanticContentIsRejected() throws {
        for suffix in [" bad", "\tbad", " \t[bad]", " 'bad'", " !!str bad"] {
            for lineBreak in ["\n", "\r\n", "\r"] {
                for finalBreak in ["", lineBreak] {
                    let yaml = "- a\(lineBreak)...\(suffix)\(finalBreak)"
                    #expect(throws: YAMLParseError.self) {
                        try YAMLDecoder().decode([String].self, from: yaml)
                    }
                    #expect(throws: YAMLParseError.self) { try stringValues(yaml) }
                    for chunkSize in [1, 2, 7, 64] {
                        #expect(throws: YAMLParseError.self) {
                            try byteValues(yaml, chunkSize: chunkSize)
                        }
                    }
                }
            }
        }
    }

    @Test("document-end suffixes accept only blanks or a comment")
    func whitespaceAndCommentSuffixesAreAccepted() throws {
        for suffix in ["", " \t ", " # comment", "\t# ... bad [ ' 🐪"] {
            for lineBreak in ["\n", "\r\n", "\r"] {
                for finalBreak in ["", lineBreak] {
                    let yaml = "- a\(lineBreak)...\(suffix)\(finalBreak)"
                    #expect(try YAMLDecoder().decode([String].self, from: yaml) == ["a"])
                    #expect(try stringValues(yaml) == ["a"])
                    for chunkSize in [1, 2, 7, 64] {
                        #expect(try byteValues(yaml, chunkSize: chunkSize) == ["a"])
                    }
                }
            }
        }
    }

    @Test("a valid document end still stops before a separate later document")
    func separateLaterDocumentRemainsOutsideTheReader() throws {
        for lineBreak in ["\n", "\r\n", "\r"] {
            let yaml = "- a\n... # done\n---\n- ignored\n... bad\n"
                .replacingOccurrences(of: "\n", with: lineBreak)
            #expect(throws: YAMLParseError.self) {
                try YAMLDecoder().decode([String].self, from: yaml)
            }
            #expect(try stringValues(yaml) == ["a"])
            for chunkSize in [1, 2, 7, 64] {
                #expect(try byteValues(yaml, chunkSize: chunkSize) == ["a"])
            }
        }
    }

    @Test("marker-shaped scalar data is not validated as a document end")
    func markerTextInScalarsIsPreserved() throws {
        let cases: [(String, [String])] = [
            ("- a\n  ... bad\n- b\n", ["a ... bad", "b"]),
            ("- '... bad'\n- b\n", ["... bad", "b"]),
            ("- \"... bad\"\n- b\n", ["... bad", "b"]),
            ("- 'a\n  ... bad'\n- b\n", ["a ... bad", "b"]),
            ("- \"a\n  ... bad\"\n- b\n", ["a ... bad", "b"]),
            ("- |\n  ... bad\n- b\n", ["... bad\n", "b"]),
            ("- ...suffix\n- b\n", ["...suffix", "b"]),
            ("- ...#suffix\n- b\n", ["...#suffix", "b"])
        ]
        for (document, expected) in cases {
            for lineBreak in ["\n", "\r\n", "\r"] {
                let yaml = document.replacingOccurrences(of: "\n", with: lineBreak)
                #expect(try YAMLDecoder().decode([String].self, from: yaml) == expected)
                #expect(try stringValues(yaml) == expected)
                for chunkSize in [1, 2, 7, 64] {
                    #expect(try byteValues(yaml, chunkSize: chunkSize) == expected)
                }
            }
        }
    }

    @Test("glued text at column zero cannot silently stop the reader")
    func gluedMarkerTextDoesNotStopTheReader() throws {
        for marker in ["...suffix", "...#suffix"] {
            let yaml = "- a\n\(marker)\n- b\n"
            #expect(throws: YAMLParseError.self) {
                try YAMLDecoder().decode([String].self, from: yaml)
            }
            #expect(throws: YAMLParseError.self) { try stringValues(yaml) }
            for chunkSize in [1, 2, 7, 64] {
                #expect(throws: YAMLParseError.self) {
                    try byteValues(yaml, chunkSize: chunkSize)
                }
            }
        }
    }

    @Test("a long document-end comment still obeys the stream's input byte bound")
    func documentEndSuffixRetainsInputByteLimit() throws {
        let yaml = "- a\n... #" + String(repeating: "x", count: 128)
        let limits = YAMLLimits(maxInputBytes: 64)
        let stringError = #expect(throws: YAMLParseError.self) {
            try YAMLDecoder(limits: limits).sequenceReader(String.self, from: yaml)
        }
        #expect(stringError?.kind == .inputTooLarge)
        for chunkSize in [1, 7, 64] {
            let byteError = #expect(throws: YAMLParseError.self) {
                try byteValues(yaml, chunkSize: chunkSize, limits: limits)
            }
            #expect(byteError?.kind == .inputTooLarge)
        }
    }
}
