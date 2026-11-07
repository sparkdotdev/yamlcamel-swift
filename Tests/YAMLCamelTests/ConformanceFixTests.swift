import Testing
@testable import YAMLCamel

/// One test per real parser bug the yaml-test-suite harness turned up. Each case cites
/// the yaml-test-suite id it came from so a regression here points straight back to the fixture.
@Suite("Conformance fixes")
struct ConformanceFixTests {

    private func parse(_ text: String) throws -> YAMLValue {
        try YAMLParser.parse(text)
    }

    // 8.1.3: a blank line more indented than the block scalar's content keeps the spaces past that
    // content indentation as literal text; only a genuinely empty line folds to a bare line break.
    // yaml-test-suite DWX9 / L24T-0 / 6FWR.
    @Test("an over-indented blank line in a block scalar keeps its extra spaces")
    func blockScalarOverIndentedBlankLine() throws {
        let v = try parse("|\n \n  \n  literal\n   \n  \n  text\n\n # Comment\n")
        #expect(v == .string("\n\nliteral\n \n\ntext\n"))
    }

    // 7.3.3: line folding in a quoted scalar strips only the line's own trailing white space; a
    // space or tab that came from an escape (`\t`, `\ `) is real content, not indentation to strip,
    // even though it lands at the same spot. yaml-test-suite DE56.
    @Test("an escaped tab at the end of a quoted scalar's line survives folding")
    func quotedScalarEscapedTrailingTabSurvives() throws {
        // The escaped tab survives; two real trailing spaces after it do not, since those are the
        // line's own trailing white space rather than part of the escape.
        #expect(try parse("\"1 trailing\\t\n    tab\"") == .string("1 trailing\t tab"))
        #expect(try parse("\"2 trailing\\t  \n    tab\"") == .string("2 trailing\t tab"))
    }

    // 9.1.4: a '...' only ends a document that a '---' actually opened. A bare '...' with nothing
    // open is just a leftover separator and starts nothing, so a stream of only end markers (and
    // comments) holds zero documents rather than one null document per marker.
    // yaml-test-suite HWV9 / QT73 / M7A3.
    @Test("a bare document-end marker with nothing open starts no document")
    func bareDocumentEndMarkerStartsNothing() throws {
        #expect(try YAMLParser.parseStream("...\n") == [])
        #expect(try YAMLParser.parseStream("# comment\n...\n") == [])
        let docs = try YAMLParser.parseStream("Bare\ndocument\n...\n# No document\n...\n|\n%!PS-Adobe-2.0 # Not the first line\n")
        #expect(docs == [.string("Bare document"), .string("%!PS-Adobe-2.0 # Not the first line\n")])
    }

    // 8.2.2: a block mapping entry may omit its key entirely, spelled as a bare ':' with nothing
    // before it. yaml-test-suite UKK6-0 / NHX8 / M2N8-0(partial).
    @Test("a bare ':' with no key opens a mapping entry with a null key")
    func bareColonIsAnEmptyKeyEntry() throws {
        let v = try parse("- :\n")
        #expect(v.arrayElements?[0]["null"] == .null)
    }

    // c-ns-properties: an anchor and a tag may each sit on their own line, in either order, ahead of
    // the node they both belong to. yaml-test-suite BU8L.
    @Test("an anchor and a tag on separate lines both attach to the same node")
    func anchorAndTagOnSeparateLinesAttachToSameNode() throws {
        let v = try parse("key: &anchor\n !!map\n  a: b\n")
        #expect(v["key"]?["a"] == .string("b"))
    }

    // A plain scalar's continuation line only reads '-' or '?' as an indicator at the enclosing
    // block's own indentation; once a line is already more indented than that (which folding
    // requires anyway), a dash there is just more scalar text. yaml-test-suite AB8U.
    @Test("a more-indented dash inside a plain scalar is text, not a new sequence item")
    func moreIndentedDashInPlainScalarIsText() throws {
        let v = try parse("- single multiline\n - sequence entry\n")
        #expect(v == .array([.string("single multiline - sequence entry")]))
    }

    // 7.4.2: a flow mapping's implicit key uses the ordinary flow node grammar, the same as any flow
    // value, so it folds across lines exactly like one. Only a block-context implicit key is held to
    // a single line. yaml-test-suite NJ66.
    @Test("a flow mapping key folds across lines the same as a value does")
    func flowMappingKeyFoldsAcrossLines() throws {
        let v = try parse("{ multi\n  line: value}")
        #expect(v["multi line"] == .string("value"))
    }

    // 8.2.2 note: a block sequence may sit at the same indentation as the mapping value, explicit
    // key or explicit value it belongs to, not just more indented. yaml-test-suite SKE5 / 6PBE.
    @Test("a zero-indented sequence is a mapping value, not a stray sibling")
    func zeroIndentedSequenceIsAMappingValue() throws {
        let v = try parse("seq:\n &anchor\n- a\n- b\n")
        #expect(v["seq"] == .array([.string("a"), .string("b")]))
    }

    // s-l+block-node vs s-l+block-indented: a mapping or a sequence may start compactly on the same
    // line only right after a sequence entry's '-' or an explicit key/value's '?'/':'. A plain
    // mapping value and the document root both reach a node through s-l+block-node instead, where a
    // mapping has to start on its own line. yaml-test-suite CXX2 / 9KBC.
    @Test("a mapping cannot start compactly at the document root")
    func mappingCannotStartCompactlyAtDocumentRoot() throws {
        #expect(throws: YAMLParseError.self) { try parse("--- &anchor a: b\n") }
        #expect(throws: YAMLParseError.self) { try parse("--- key1: value1\n    key2: value2\n") }
    }

    // s-l+block-indented: a compact mapping's later entries are indented from the column right after
    // the sequence entry's '-', regardless of how far a leading anchor or tag on the first key pushed
    // that key's own text to the right. Measuring from the key's text instead made every later entry
    // look like it was indented past the sequence.
    @Test("an anchor before a compact sequence entry's key does not shift where later keys align")
    func anchorBeforeCompactKeyDoesNotShiftLaterKeys() throws {
        let v = try parse("- &default name: foo\n  value: bar\n")
        #expect(v == .array([.object([.init(key: "name", value: .string("foo")),
                                      .init(key: "value", value: .string("bar"))])]))
    }

    // Same baseline mistake, reached through a tag instead of an anchor.
    @Test("a tag before a compact sequence entry's key does not shift where later keys align")
    func tagBeforeCompactKeyDoesNotShiftLaterKeys() throws {
        let v = try parse("- !!str name: foo\n  value: bar\n")
        #expect(v == .array([.object([.init(key: "name", value: .string("foo")),
                                      .init(key: "value", value: .string("bar"))])]))
    }

    // The block scalar consumes its own header and content lines, so the baseline mistake only shows
    // once control returns to the compact mapping for its next key, and again once the mapping ends
    // and control returns to the sequence for its next sibling entry.
    @Test("a compact key's block scalar value still allows a sibling entry after it")
    func anchorBeforeCompactKeyWithBlockScalarAllowsSiblingEntry() throws {
        let v = try parse("- &default name: |\n    foo\n  value: bar\n- other: baz\n")
        #expect(v == .array([.object([.init(key: "name", value: .string("foo\n")),
                                      .init(key: "value", value: .string("bar"))]),
                             .object([.init(key: "other", value: .string("baz"))])]))
    }

    // A flow sequence or mapping entry always needs content of its own; a leading or a doubled comma
    // has none, so it is refused rather than read as an empty entry. An entry that carries an anchor
    // or a tag but no content is still a deliberately empty node, and stays allowed.
    // yaml-test-suite 9MAG / CTN5.
    @Test("a leading or doubled comma in a flow sequence is refused")
    func strayCommaInFlowSequenceIsRefused() throws {
        #expect(throws: YAMLParseError.self) { try parse("[ , a, b, c ]\n") }
        #expect(throws: YAMLParseError.self) { try parse("[ a, b, c, , ]\n") }
        #expect(try parse("[ foo : !!str, ]") == .array([.object([.init(key: "foo", value: .string(""))])]))
    }

    // A comment needs a space, a tab or a line break before it, in flow context the same as
    // anywhere else; one glued directly onto a comma, a bracket or a scalar is not a comment.
    // yaml-test-suite CVW2 / 9JBA / SU5Z.
    @Test("a comment glued onto the token before it is refused")
    func commentWithNoPrecedingSpaceIsRefused() throws {
        #expect(throws: YAMLParseError.self) { try parse("[ a, b, c,#invalid\n]\n") }
        #expect(throws: YAMLParseError.self) { try parse("key: \"value\"# invalid comment\n") }
    }

    // A document has at most one %YAML directive, and it takes exactly one version argument.
    // yaml-test-suite SF5V / H7TQ.
    @Test("a duplicate or malformed %YAML directive is refused")
    func malformedYAMLDirectiveIsRefused() throws {
        #expect(throws: YAMLParseError.self) { try parse("%YAML 1.2\n%YAML 1.2\n---\n") }
        #expect(throws: YAMLParseError.self) { try parse("%YAML 1.2 foo\n---\n") }
    }
}
