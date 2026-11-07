import XCTest
@testable import YAMLCamel

/// Mirror of a real per-entry dictionary shape. The optional fields prove an absent key decodes to
/// nil.
private struct SenseTagged: Codable, Equatable { var w: String; var s: String? }
private struct SampleSentence: Codable, Equatable { var t: String; var s: String?; var v: Bool? }
private struct DictEntrySeed: Codable, Equatable {
    var w: String
    var pos: String?
    var g: [String]?
    var ex: [String]?
    var dv: [String]?
    var rl: [String]?
    var syn: [SenseTagged]?
    var ant: [SenseTagged]?
    var sx: [SampleSentence]?
}

/// Excerpts taken from real shipped YAML data, covering the exact constructs those files use.
final class RealDataSnippetTests: XCTestCase {

    /// Covers a folded intro, a double-quoted title with escaped quotes and an inner colon, and flow
    /// sequences whose quoted members contain commas.
    func testPortugueseGrammarContrastExcerpt() throws {
        let yaml = """
        # grammar/ep-vs-english-contrasts.yaml excerpt
        intro: >-
          A few European Portuguese constructs have no direct English equivalent.
          Start here before the other grammar topics.
        entries:
          - id: ser-vs-estar
            title: "ser vs. estar: two \\"to be\\" verbs, no clean English analogue"
            gloss: permanent identity against temporary state, where English just has "to be"
            level: A1
            table:
              columns: [Preposition, "Article / Demonstrative", "Combined Form"]
              rows:
                - [em, "o, a, os, as", "no, na, nos, nas"]
                - [de, "o, a, os, as", "do, da, dos, das"]
        """
        let root = try YAMLParser.parse(yaml)

        XCTAssertEqual(root["intro"],
            .string("A few European Portuguese constructs have no direct English equivalent. Start here before the other grammar topics."))

        let entries = root["entries"]?.arrayElements
        XCTAssertEqual(entries?.count, 1)
        let e = entries![0]
        XCTAssertEqual(e["id"], .string("ser-vs-estar"))
        XCTAssertEqual(e["title"], .string("ser vs. estar: two \"to be\" verbs, no clean English analogue"))
        XCTAssertEqual(e["gloss"], .string("permanent identity against temporary state, where English just has \"to be\""))
        XCTAssertEqual(e["level"], .string("A1"))

        XCTAssertEqual(e["table"]?["columns"],
            .array([.string("Preposition"), .string("Article / Demonstrative"), .string("Combined Form")]))
        let rows = e["table"]?["rows"]?.arrayElements
        XCTAssertEqual(rows?[0], .array([.string("em"), .string("o, a, os, as"), .string("no, na, nos, nas")]))
        XCTAssertEqual(rows?[1], .array([.string("de"), .string("o, a, os, as"), .string("do, da, dos, das")]))
    }

    /// Covers a sequence of mappings indented under its key, with blank lines between items and
    /// single-quoted scalars whose text starts with a dash.
    func testHungarianDrillDataExcerpt() throws {
        let yaml = """
        case_drill:
          - stem: ház
            form: házban
            suffix: '-ban/-ben'
            caseName: Inessive
            meaning: 'in (inside)'

          - stem: ház
            form: házba
            suffix: '-ba/-be'
            caseName: Illative
            meaning: into
        """
        let root = try YAMLParser.parse(yaml)
        let drills = root["case_drill"]?.arrayElements
        XCTAssertEqual(drills?.count, 2)
        XCTAssertEqual(drills?[0]["form"], .string("házban"))
        XCTAssertEqual(drills?[0]["suffix"], .string("-ban/-ben"))
        XCTAssertEqual(drills?[0]["meaning"], .string("in (inside)"))
        XCTAssertEqual(drills?[1]["meaning"], .string("into"))
    }

    /// Covers the nested block-sequence-of-mappings shape a real dictionary file uses: string lists,
    /// sense-tagged maps, and per-sense sample sentences with optional flags.
    func testDictionaryFamilyAndExampleSchemaDecodes() throws {
        let yaml = """
        - w: "ver"
          pos: "verb"
          g: ["to see", "to witness"]
          dv: ["visão", "vista"]
          rl: ["olhar", "avistar"]
          syn:
            - w: "observar"
              s: "to witness"
            - w: "testemunhar"
              s: "to witness"
            - w: "avistar"
          ant:
            - w: "ignorar"
          sx:
            - t: "Vi o filme ontem à noite."
              s: "to see"
            - t: "A testemunha viu tudo o que aconteceu."
              s: "to witness"
              v: false
        - w: "caralho"
          pos: "noun"
          g: []
          sx:
            - t: "<a vulgar usage sentence>"
              s: "prick"
              v: true
        """
        let entries = try YAMLDecoder().decode([DictEntrySeed].self, from: yaml)
        XCTAssertEqual(entries.count, 2)

        let ver = entries[0]
        XCTAssertEqual(ver.w, "ver")
        XCTAssertEqual(ver.g, ["to see", "to witness"])
        // Derived and related decode as plain string lists.
        XCTAssertEqual(ver.dv, ["visão", "vista"])
        XCTAssertEqual(ver.rl, ["olhar", "avistar"])
        // Sense-tagged maps, with a trailing member whose optional tag is absent.
        XCTAssertEqual(ver.syn, [SenseTagged(w: "observar", s: "to witness"),
                                 SenseTagged(w: "testemunhar", s: "to witness"),
                                 SenseTagged(w: "avistar", s: nil)])
        XCTAssertEqual(ver.ant, [SenseTagged(w: "ignorar", s: nil)])
        // An absent optional flag decodes to nil and an explicit false stays false.
        XCTAssertEqual(ver.sx?.count, 2)
        XCTAssertEqual(ver.sx?[0], SampleSentence(t: "Vi o filme ontem à noite.", s: "to see", v: nil))
        XCTAssertEqual(ver.sx?[1], SampleSentence(t: "A testemunha viu tudo o que aconteceu.", s: "to witness", v: false))

        let vulgar = entries[1]
        XCTAssertEqual(vulgar.g, [])
        XCTAssertEqual(vulgar.sx, [SampleSentence(t: "<a vulgar usage sentence>", s: "prick", v: true)])
        // An explicit true survives the round trip.
        XCTAssertEqual(vulgar.sx?.first?.v, true)
    }

    /// Covers a double-quoted scalar containing a `*`, which has to stay literal rather than reading
    /// as an alias.
    func testVerbMetadataNotesExcerpt() throws {
        let yaml = """
        seguir:
          pattern: e-i-raise
          notes: "Also gu→g before a/o/u (spec §2d), co-occurring with the e→i raise: eu sigo, not *siguo."
        """
        let root = try YAMLParser.parse(yaml)
        XCTAssertEqual(root["seguir"]?["pattern"], .string("e-i-raise"))
        XCTAssertEqual(root["seguir"]?["notes"],
            .string("Also gu→g before a/o/u (spec §2d), co-occurring with the e→i raise: eu sigo, not *siguo."))
    }
}
