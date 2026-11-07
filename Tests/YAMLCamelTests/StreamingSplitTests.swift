import Foundation
import Testing
@testable import YAMLCamel

private struct Row: Codable, Equatable {
    var name: String
    var body: String?
    var tags: [String]?
}

/// Every construct that can carry a line looking like a sequence entry without being one.
///
/// The rule each case checks is the same: streaming has to agree with whole decode. Anywhere it
/// does not, an item has been cut in half.
@Suite("Streaming item boundaries")
struct StreamingSplitTests {

    private func whole(_ yaml: String) throws -> [Row] {
        try YAMLDecoder().decode([Row].self, from: yaml)
    }

    private func viaStringReader(_ yaml: String) throws -> [Row] {
        let reader = try YAMLDecoder().sequenceReader(Row.self, from: yaml)
        var out: [Row] = []
        while let row = try reader.next() { out.append(row) }
        return out
    }

    private func viaByteReader(_ yaml: String, chunk: Int) throws -> [Row] {
        let reader = YAMLByteSequenceReader<Row>()
        let bytes = [UInt8](Data(yaml.utf8))
        var out: [Row] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunk, bytes.count)
            out += try reader.push(Array(bytes[offset ..< end]))
            offset = end
        }
        out += try reader.finish()
        return out
    }

    private func expectAllPathsAgree(_ yaml: String, _ expected: [Row], _ label: String) throws {
        let whole = try whole(yaml)
        #expect(whole == expected, "\(label): whole decode")
        #expect(try viaStringReader(yaml) == expected, "\(label): string reader")
        for chunk in [1, 7, 64, 4096] {
            #expect(try viaByteReader(yaml, chunk: chunk) == expected, "\(label): byte reader, chunk \(chunk)")
        }
    }

    @Test("a document start marker does not turn indented sequence entries into continuations")
    func documentStartBeforeIndentedSequence() throws {
        for marker in ["---", "--- # document", "---\t# document"] {
            for lineBreak in ["\n", "\r\n", "\r"] {
                let yaml = "# leading comment\n\(marker)\n  - name: a\n    body: first\n  - name: b\n"
                    .replacingOccurrences(of: "\n", with: lineBreak)
                try expectAllPathsAgree(yaml,
                    [Row(name: "a", body: "first", tags: nil), Row(name: "b", body: nil, tags: nil)],
                    "document marker, \(lineBreak.debugDescription)")
            }
        }
    }

    @Test("the recorded indented mapping sequence agrees with whole decode")
    func recordedDocumentStartSequence() throws {
        let recorded = "#! A sequence alternating with a mapping costs t'''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''   a: 1\n---\n         - a:\n                                              #!                                                           - a:\n            A    \n"
        for yaml in [recorded, String(recorded.dropLast())] {
            let expected = try YAMLDecoder().decode([[String: String]].self, from: yaml)
            #expect(expected == [["a": "A"]])
            let reader = try YAMLDecoder().sequenceReader([String: String].self, from: yaml)
            var actual: [[String: String]] = []
            while let item = try reader.next() { actual.append(item) }
            #expect(actual == expected)
            for chunk in [1, 7, 64, 4096] {
                let bytes = Array(yaml.utf8)
                let byteReader = YAMLByteSequenceReader<[String: String]>()
                var streamed: [[String: String]] = []
                var offset = 0
                while offset < bytes.count {
                    let end = min(offset + chunk, bytes.count)
                    streamed += try byteReader.push(Array(bytes[offset..<end]))
                    offset = end
                }
                streamed += try byteReader.finish()
                #expect(streamed == expected)
            }
        }
    }

    @Test("a byte order mark before a document marker preserves indented entries")
    func leadingBOMBeforeDocumentMarker() throws {
        let yaml = "\u{FEFF}---\n  - name: a\n  - name: b\n"
        try expectAllPathsAgree(yaml,
            [Row(name: "a", body: nil, tags: nil), Row(name: "b", body: nil, tags: nil)],
            "document marker with entry BOM")
    }

    @Test("inline document scalar content cannot be mistaken for sequence entries")
    func documentMarkerScalarRootsAreRejected() throws {
        let documents = [
            "--- |\n  - a\n  - b\n",
            "--- >\n  - a\n  - b\n",
            "--- plain\n  - a\n  - b\n",
            "--- 'quoted\n  - a\n  - b'\n",
            "--- \"quoted\n  - a\n  - b\"\n",
            "--- &root |\n  - a\n  - b\n",
            "--- !!str plain\n  - a\n  - b\n"
        ]
        for document in documents {
            for lineBreak in ["\n", "\r\n", "\r"] {
                let yaml = document.replacingOccurrences(of: "\n", with: lineBreak)
                guard case .string = try YAMLParser.parse(yaml) else {
                    Issue.record("expected a scalar document: \(yaml.debugDescription)")
                    continue
                }
                #expect(throws: YAMLParseError.self) {
                    let reader = try YAMLDecoder().sequenceReader(String.self, from: yaml)
                    while try reader.next() != nil {}
                }
                for chunk in [1, 7, 64, 4096] {
                    #expect(throws: YAMLParseError.self) {
                        let reader = YAMLByteSequenceReader<String>()
                        let bytes = Array(yaml.utf8)
                        var offset = 0
                        while offset < bytes.count {
                            let end = min(offset + chunk, bytes.count)
                            _ = try reader.push(Array(bytes[offset..<end]))
                            offset = end
                        }
                        _ = try reader.finish()
                    }
                }
            }
        }
    }

    @Test("document root tags and anchors preserve a following block sequence")
    func documentMarkerSequenceProperties() throws {
        for properties in ["!!seq", "&root", "!!seq &root", "&root !!seq", "!", "!custom",
                           "!<tag:yaml.org,2002:seq>"] {
            let yaml = "--- \(properties) # root properties\n  - name: a\n  - name: b\n"
            try expectAllPathsAgree(yaml,
                [Row(name: "a", body: nil, tags: nil), Row(name: "b", body: nil, tags: nil)],
                "document properties \(properties)")
        }
    }

    @Test("document root properties retain tag validation and tag length bounds")
    func documentMarkerInvalidPropertiesAreRejected() throws {
        for properties in ["!!str", "!!map", "&", "!<unfinished", "!!seq !!seq", "&a &b"] {
            let yaml = "--- \(properties)\n  - name: a\n  - name: b\n"
            #expect(throws: YAMLParseError.self) { try whole(yaml) }
            #expect(throws: YAMLParseError.self) { try viaStringReader(yaml) }
            for chunk in [1, 7, 64, 4096] {
                #expect(throws: YAMLParseError.self) { try viaByteReader(yaml, chunk: chunk) }
            }
        }
        let yaml = "--- !<tag:example.com,2026:sequence>\n  - name: a\n"
        let limits = YAMLLimits(maxTagLength: 8)
        let wholeError = #expect(throws: YAMLParseError.self) {
            try YAMLDecoder(limits: limits).decode([Row].self, from: yaml)
        }
        #expect(wholeError?.kind == .tagTooLong)
        let stringError = #expect(throws: YAMLParseError.self) {
            try YAMLDecoder(limits: limits).sequenceReader(Row.self, from: yaml)
        }
        #expect(stringError?.kind == .tagTooLong)
        let byteError = #expect(throws: YAMLParseError.self) {
            try YAMLByteSequenceReader<Row>(limits: limits).push(Array(yaml.utf8))
        }
        #expect(byteError?.kind == .tagTooLong)
    }

    private func expectScalarReadersRefuse(_ yaml: String, beforeFirstItem: Bool) throws {
        if beforeFirstItem {
            #expect(throws: DecodingError.self) { try YAMLDecoder().decode([String].self, from: yaml) }
        } else {
            #expect(throws: YAMLParseError.self) { try YAMLDecoder().decode([String].self, from: yaml) }
        }
        #expect(throws: YAMLParseError.self) {
            let reader = try YAMLDecoder().sequenceReader(String.self, from: yaml)
            while try reader.next() != nil {}
        }
        for chunk in [1, 2, 3, 7, 64, 4096] {
            var received: [String] = []
            #expect(throws: YAMLParseError.self) {
                let reader = YAMLByteSequenceReader<String>()
                let bytes = Array(yaml.utf8)
                var offset = 0
                while offset < bytes.count {
                    let end = min(offset + chunk, bytes.count)
                    received += try reader.push(Array(bytes[offset..<end]))
                    offset = end
                }
                received += try reader.finish()
            }
            if beforeFirstItem { #expect(received.isEmpty) }
        }
    }

    @Test("a BOM after indentation is content and cannot open a streamed root")
    func indentedBOMBeforeRootIsRejected() throws {
        for indent in [1, 2, 9] {
            let spaces = String(repeating: " ", count: indent)
            for lineBreak in ["\n", "\r\n", "\r"] {
                for trailingBreak in ["", "\n"] {
                    let yaml = "---\n\(spaces)\u{FEFF}- a\n\(spaces)- b\(trailingBreak)"
                        .replacingOccurrences(of: "\n", with: lineBreak)
                    try expectScalarReadersRefuse(yaml, beforeFirstItem: true)
                }
            }
        }
    }

    @Test("a column-zero BOM before an indented entry preserves its indentation")
    func leadingBOMBeforeIndentedEntries() throws {
        for marker in ["", "---\n", "\u{FEFF}---\n"] {
            for entries in ["\u{FEFF}  - name: a\n  - name: b\n",
                            "  - name: a\n\u{FEFF}  - name: b\n"] {
                for lineBreak in ["\n", "\r\n", "\r"] {
                    try expectAllPathsAgree((marker + entries).replacingOccurrences(of: "\n", with: lineBreak),
                        [Row(name: "a", body: nil, tags: nil), Row(name: "b", body: nil, tags: nil)],
                        "column-zero BOM before indented entry")
                }
            }
        }
    }

    @Test("a BOM keeps its original position when an item is parsed")
    func BOMBeforeIndentedContinuationIsNotErased() throws {
        for yaml in ["---\n- a\n\u{FEFF}  continuation\n- b\n",
                     "---\n- |\n  body\n\u{FEFF}  continuation\n- b\n",
                     "---\n  - a\n  \u{FEFF}- b\n"] {
            try expectScalarReadersRefuse(yaml, beforeFirstItem: false)
        }
    }

    @Test("a double-quoted scalar carrying a dash line is one item")
    func doubleQuotedSpanningLines() throws {
        try expectAllPathsAgree("""
        - name: "a
            - b"
        - name: c
        """,
        [Row(name: "a - b", body: nil, tags: nil), Row(name: "c", body: nil, tags: nil)],
        "double quoted")
    }

    @Test("a single-quoted scalar carrying a dash line is one item")
    func singleQuotedSpanningLines() throws {
        try expectAllPathsAgree("""
        - name: 'a
            - b'
        - name: c
        """,
        [Row(name: "a - b", body: nil, tags: nil), Row(name: "c", body: nil, tags: nil)],
        "single quoted")
    }

    @Test("a quoted scalar carrying several dash lines is still one item")
    func quotedSpanningManyLines() throws {
        try expectAllPathsAgree("""
        - name: "a
            - b
            - c
            - d"
        - name: e
        """,
        [Row(name: "a - b - c - d", body: nil, tags: nil), Row(name: "e", body: nil, tags: nil)],
        "many lines")
    }

    @Test("an escaped quote inside a spanning scalar does not close it early")
    func escapedQuoteInsideSpanningScalar() throws {
        try expectAllPathsAgree("""
        - name: "a \\" still open
            - b"
        - name: c
        """,
        [Row(name: "a \" still open - b", body: nil, tags: nil), Row(name: "c", body: nil, tags: nil)],
        "escaped quote")
    }

    @Test("a doubled quote inside a single-quoted scalar does not close it early")
    func doubledQuoteInsideSpanningScalar() throws {
        try expectAllPathsAgree("""
        - name: 'a '' still open
            - b'
        - name: c
        """,
        [Row(name: "a ' still open - b", body: nil, tags: nil), Row(name: "c", body: nil, tags: nil)],
        "doubled quote")
    }

    /// A flow collection cannot legally dedent to the base indentation, so it cannot fake a boundary
    /// on its own. It is tracked anyway, because a quote opened inside one still spans lines.
    @Test("a flow sequence spanning lines is one item, and its quotes are tracked")
    func flowCollectionSpanningLines() throws {
        try expectAllPathsAgree("""
        - name: a
          tags: [x,
                 "y # not a comment",
                 z]
        - name: b
        """,
        [Row(name: "a", body: nil, tags: ["x", "y # not a comment", "z"]),
         Row(name: "b", body: nil, tags: nil)],
        "flow sequence")
    }

    @Test("a block scalar whose content holds an unbalanced quote does not confuse the split")
    func blockScalarWithUnbalancedQuote() throws {
        try expectAllPathsAgree("""
        - name: a
          body: |
            he said "hello
            and left
        - name: b
        """,
        [Row(name: "a", body: "he said \"hello\nand left\n", tags: nil),
         Row(name: "b", body: nil, tags: nil)],
        "block scalar with a quote")
    }

    @Test("a block scalar whose content holds an unbalanced bracket does not confuse the split")
    func blockScalarWithUnbalancedBracket() throws {
        try expectAllPathsAgree("""
        - name: a
          body: >-
            an open [ bracket
            and a { brace
        - name: b
        """,
        [Row(name: "a", body: "an open [ bracket and a { brace", tags: nil),
         Row(name: "b", body: nil, tags: nil)],
        "block scalar with a bracket")
    }

    @Test("a block scalar header in a compact sequence entry does not hide the quote a sibling key opens")
    func blockScalarHeaderInCompactEntryDoesNotHideSiblingQuote() throws {
        // "body: |" here sits right after the dash, so its own column is 2, not the line's 0. The
        // next line is indented 2, level with "body" rather than past it, so it is not block
        // content: it is "name" opening this same mapping's other key, whose quote has to stay
        // visible to the splitter, closing only once "- y\"" is reached.
        try expectAllPathsAgree("""
        - body: |
          name: "x
            - y"
        - name: c
        """,
        [Row(name: "x - y", body: "", tags: nil), Row(name: "c", body: nil, tags: nil)],
        "block scalar header hiding a sibling key's quote")
    }

    @Test("a block scalar with a chomping and indentation indicator is still recognised")
    func blockScalarWithIndicators() throws {
        try expectAllPathsAgree("""
        - name: a
          body: |2-
             indented "unbalanced
        - name: b
        """,
        [Row(name: "a", body: " indented \"unbalanced", tags: nil),
         Row(name: "b", body: nil, tags: nil)],
        "block scalar indicators")
    }

    @Test("an apostrophe inside a plain scalar does not open a quoted one")
    func apostropheInsidePlainScalar() throws {
        try expectAllPathsAgree("""
        - name: don't
        - name: b
        """,
        [Row(name: "don't", body: nil, tags: nil), Row(name: "b", body: nil, tags: nil)],
        "apostrophe in a plain scalar")
    }

    @Test("a quote inside a plain key does not cancel the one that opens the value")
    func quoteInPlainKeyBeforeSpanningScalar() throws {
        try expectAllPathsAgree("""
        - body: don't
          name: 'a
            - b'
        - name: c
        """,
        [Row(name: "a - b", body: "don't", tags: nil), Row(name: "c", body: nil, tags: nil)],
        "quote in a plain key")
    }

    @Test("a bracket inside a plain scalar does not open a flow collection")
    func bracketInsidePlainScalar() throws {
        try expectAllPathsAgree("""
        - name: a[1
        - name: b
        """,
        [Row(name: "a[1", body: nil, tags: nil), Row(name: "b", body: nil, tags: nil)],
        "bracket in a plain scalar")
    }

    @Test("a dash inside a plain scalar does not reopen the position a quote could start at")
    func dashInsidePlainScalar() throws {
        try expectAllPathsAgree("""
        - name: a- "b
        - name: c
        """,
        [Row(name: "a- \"b", body: nil, tags: nil), Row(name: "c", body: nil, tags: nil)],
        "dash in a plain scalar")
    }

    @Test("a tag before a spanning scalar leaves its quote recognised")
    func tagBeforeSpanningScalar() throws {
        try expectAllPathsAgree("""
        - name: !!str 'a
            - b'
        - name: c
        """,
        [Row(name: "a - b", body: nil, tags: nil), Row(name: "c", body: nil, tags: nil)],
        "tag before a spanning scalar")
    }

    @Test("a comment holding an unbalanced quote does not confuse the split")
    func commentWithUnbalancedQuote() throws {
        try expectAllPathsAgree("""
        - name: a # it's fine
        - name: b # so is "this
        - name: c
        """,
        [Row(name: "a", body: nil, tags: nil),
         Row(name: "b", body: nil, tags: nil),
         Row(name: "c", body: nil, tags: nil)],
        "comment")
    }

    @Test("a hash inside a quoted scalar is not a comment")
    func hashInsideQuotes() throws {
        try expectAllPathsAgree("""
        - name: "a # not a comment
            - b"
        - name: c
        """,
        [Row(name: "a # not a comment - b", body: nil, tags: nil),
         Row(name: "c", body: nil, tags: nil)],
        "hash in quotes")
    }

    @Test("a byte order mark at the start of the stream is stripped like a whole decode strips it")
    func leadingBOMIsStripped() throws {
        try expectAllPathsAgree("\u{FEFF}- name: a\n- name: b\n",
        [Row(name: "a", body: nil, tags: nil), Row(name: "b", body: nil, tags: nil)],
        "leading BOM")
    }

    @Test("a byte order mark opening a later item is stripped too, not only the stream's first")
    func laterLineBOMIsStripped() throws {
        // A whole decode strips a byte order mark wherever a new top-level entry may start, since
        // the spec allows one there and this is never valid bare content anywhere else. A reader
        // that only stripped the stream's own first one would read the mark as the second item's
        // content and disagree with a whole decode on what that item is.
        try expectAllPathsAgree("- name: a\n\u{FEFF}- name: b\n",
        [Row(name: "a", body: nil, tags: nil), Row(name: "b", body: nil, tags: nil)],
        "later-line BOM")
    }

    @Test("a byte order mark that continues a quoted scalar across lines is content, not stripped")
    func continuationLineBOMSurvives() throws {
        // Stripping a mark wherever a line happens to start with one, rather than only where a new
        // top-level entry may start, would fold this into "a b" and silently drop it: this line
        // continues the quoted scalar the previous one opened, so the mark is data here.
        try expectAllPathsAgree("- name: \"a\n    \u{FEFF}b\"\n- name: c\n",
        [Row(name: "a \u{FEFF}b", body: nil, tags: nil), Row(name: "c", body: nil, tags: nil)],
        "continuation-line BOM")
    }

    @Test("ordinary sequences still split where they always did")
    func ordinarySequencesStillSplit() throws {
        try expectAllPathsAgree("""
        - name: a
          tags:
          - x
          - y
        - name: b
          body: |
            text
        - name: c
        """,
        [Row(name: "a", body: nil, tags: ["x", "y"]),
         Row(name: "b", body: "text\n", tags: nil),
         Row(name: "c", body: nil, tags: nil)],
        "ordinary")
    }

    // Four gaps an earlier pass into the readers' line splitting left alone. Each of these agreed
    // with whole decode on none of the readers, or only some of them, before its fix.

    @Test("a lone CR ends a line the same as LF does")
    func loneCarriageReturnEndsALine() throws {
        try expectAllPathsAgree("- name: a\r- name: b\r\n",
                                [Row(name: "a", body: nil, tags: nil), Row(name: "b", body: nil, tags: nil)],
                                "lone CR")
    }

    @Test("CRLF line endings split the same as LF alone")
    func crlfLineEndingsSplit() throws {
        try expectAllPathsAgree("- name: a\r\n- name: b\r\n- name: c\r\n",
                                [Row(name: "a", body: nil, tags: nil),
                                 Row(name: "b", body: nil, tags: nil),
                                 Row(name: "c", body: nil, tags: nil)],
                                "CRLF")
    }

    @Test("a plain scalar continuing onto a line that starts with a quote is not cut short")
    func plainScalarContinuationStartingWithQuote() throws {
        try expectAllPathsAgree("""
        - name: a[1, 2,
           'b]
        - name: c
        """,
        [Row(name: "a[1, 2, 'b]", body: nil, tags: nil), Row(name: "c", body: nil, tags: nil)],
        "plain scalar continuation opening with a quote")
    }

    @Test("tabs cannot replace indentation spaces in any decoding path")
    func tabInsideIndentationIsRejected() throws {
        let yaml = "  - name: a\n \t- name: b\n"
        #expect(throws: YAMLParseError.self) { try whole(yaml) }
        #expect(throws: YAMLParseError.self) { try viaStringReader(yaml) }
        for chunk in [1, 7, 64] {
            #expect(throws: YAMLParseError.self) { try viaByteReader(yaml, chunk: chunk) }
        }
    }

    @Test("an indented '...' is not a document end, and does not stop the scan")
    func indentedDocumentEndMarkerIsNotOne() throws {
        // Column zero is what makes '...' a document end marker; indented, it is exactly as much
        // content as anything else on a continuation line, here folding into the previous item.
        try expectAllPathsAgree("- name: a\n- name: b\n   ...\n- name: c\n",
                                [Row(name: "a", body: nil, tags: nil),
                                 Row(name: "b ...", body: nil, tags: nil),
                                 Row(name: "c", body: nil, tags: nil)],
                                "indented document end marker")
    }

    @Test("a real '...' at column zero stops the scan without a trailing empty item")
    func realDocumentEndMarkerStopsTheScan() throws {
        let yaml = "- name: a\n- name: b\n...\n- name: c\n"
        // The reader only ever decodes one top-level sequence; content after a real document end is
        // a second document, which is out of scope for it, the same as it would be for whole decode.
        #expect(try viaStringReader(yaml) == [Row(name: "a", body: nil, tags: nil), Row(name: "b", body: nil, tags: nil)])
        #expect(try viaByteReader(yaml, chunk: 3) == [Row(name: "a", body: nil, tags: nil), Row(name: "b", body: nil, tags: nil)])
    }

    @Test("the reader's item count matches the number of items decoded")
    func countMatchesDecoded() throws {
        let yaml = """
        - name: "a
            - b"
        - name: c
        - name: "d
            - e"
        """
        let reader = try YAMLDecoder().sequenceReader(Row.self, from: yaml)
        #expect(reader.count == 3)
        var decoded = 0
        while try reader.next() != nil { decoded += 1 }
        #expect(decoded == 3)
    }

    @Test("skipping still lands on the right item when a scalar spans lines")
    func skipWithSpanningScalars() throws {
        let yaml = """
        - name: "a
            - b"
        - name: c
        - name: d
        """
        let reader = try YAMLDecoder().sequenceReader(Row.self, from: yaml)
        reader.skip(2)
        #expect(try reader.next()?.name == "d")

        let byteReader = YAMLByteSequenceReader<Row>()
        byteReader.skip(2)
        var out = try byteReader.push(Data(yaml.utf8))
        out += try byteReader.finish()
        #expect(out.map(\.name) == ["d"])
        #expect(byteReader.emitted == 3)
    }

    @Test("generated documents split the same way through every path")
    func generatedDocumentsAgree() throws {
        // The generator leans on the constructs that span lines, since those are what a
        // line-at-a-time splitter gets wrong.
        for index in 0 ..< 3_000 {
            var gen = Generator(seed: 0x5717 &+ UInt64(index))
            var yaml = ""
            var expected: [Row] = []
            for item in 0 ..< gen.int(1 ..< 5) {
                switch gen.int(0 ..< 6) {
                case 0:
                    yaml += "- name: \"line \(item)\n    - still \(item)\"\n"
                    expected.append(Row(name: "line \(item) - still \(item)", body: nil, tags: nil))
                case 1:
                    yaml += "- name: 'line \(item)\n    - still \(item)'\n"
                    expected.append(Row(name: "line \(item) - still \(item)", body: nil, tags: nil))
                case 2:
                    yaml += "- name: n\(item)\n  body: |\n    a \"quote and a [ bracket\n    - looks like an item\n"
                    expected.append(Row(name: "n\(item)",
                                        body: "a \"quote and a [ bracket\n- looks like an item\n",
                                        tags: nil))
                case 3:
                    yaml += "- name: n\(item)\n  tags: [p,\n   \"q # here\"]\n"
                    expected.append(Row(name: "n\(item)", body: nil, tags: ["p", "q # here"]))
                case 4:
                    // A plain scalar carrying on over a line that opens with a quote: the quote is
                    // text, not a scalar of its own.
                    yaml += "- name: n\(item)[1,\n   'x]\n"
                    expected.append(Row(name: "n\(item)[1, 'x]", body: nil, tags: nil))
                default:
                    yaml += "- name: n\(item)\n"
                    expected.append(Row(name: "n\(item)", body: nil, tags: nil))
                }
            }
            // Every line break in the same document is CRLF half the time; `\r\n` is one Swift
            // `Character`, which is exactly what tripped up a split that worked in `\n`.
            if gen.int(0 ..< 2) == 0 {
                yaml = yaml.replacingOccurrences(of: "\n", with: "\r\n")
            }
            let seed = 0x5717 &+ UInt64(index)
            #expect(try whole(yaml) == expected, "whole decode, seed \(seed)")
            #expect(try viaStringReader(yaml) == expected, "string reader, seed \(seed)")
            #expect(try viaByteReader(yaml, chunk: 3) == expected, "byte reader, seed \(seed)")
        }
    }
}
