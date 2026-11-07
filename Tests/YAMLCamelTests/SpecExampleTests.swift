import Testing
@testable import YAMLCamel

/// Cases taken from the examples in the YAML 1.2.2 spec, with the section each one comes from.
/// Nothing here is invented: an expectation that disagrees with the spec is a bug in this library.
@Suite("YAML 1.2.2 spec examples")
struct SpecExampleTests {

    private func parse(_ text: String) throws -> YAMLValue {
        // Spec examples depict complete source lines; Swift multiline literals omit
        // their closing newline unless it is represented explicitly.
        try YAMLParser.parse(text.hasSuffix("\n") ? text : text + "\n")
    }

    private func stream(_ text: String) throws -> [YAMLValue] {
        try YAMLParser.parseStream(text.hasSuffix("\n") ? text : text + "\n")
    }

    // MARK: - 2.1 Collections

    @Test("2.1 sequence of scalars")
    func sequenceOfScalars() throws {
        let v = try parse("""
        - Mark McGwire
        - Sammy Sosa
        - Ken Griffey
        """)
        #expect(v == .array([.string("Mark McGwire"), .string("Sammy Sosa"), .string("Ken Griffey")]))
    }

    @Test("2.2 mapping scalars to scalars")
    func mappingScalarsToScalars() throws {
        let v = try parse("""
        hr:  65    # Home runs
        avg: 0.278 # Batting average
        rbi: 147   # Runs Batted In
        """)
        #expect(v["hr"] == .int(65))
        #expect(v["avg"] == .double(0.278))
        #expect(v["rbi"] == .int(147))
    }

    @Test("2.3 mapping scalars to sequences")
    func mappingScalarsToSequences() throws {
        let v = try parse("""
        american:
          - Boston Red Sox
          - Detroit Tigers
          - New York Yankees
        national:
          - New York Mets
          - Chicago Cubs
          - Atlanta Braves
        """)
        #expect(v["american"]?.arrayElements?.count == 3)
        #expect(v["national"]?.arrayElements?.first == .string("New York Mets"))
    }

    @Test("2.4 sequence of mappings")
    func sequenceOfMappings() throws {
        let v = try parse("""
        -
          name: Mark McGwire
          hr:   65
          avg:  0.278
        -
          name: Sammy Sosa
          hr:   63
          avg:  0.288
        """)
        #expect(v.arrayElements?.count == 2)
        #expect(v.arrayElements?[1]["hr"] == .int(63))
    }

    @Test("2.5 sequence of sequences")
    func sequenceOfSequences() throws {
        let v = try parse("""
        - [name        , hr, avg  ]
        - [Mark McGwire, 65, 0.278]
        - [Sammy Sosa  , 63, 0.288]
        """)
        #expect(v.arrayElements?[0] == .array([.string("name"), .string("hr"), .string("avg")]))
        #expect(v.arrayElements?[1] == .array([.string("Mark McGwire"), .int(65), .double(0.278)]))
    }

    @Test("2.6 mapping of mappings")
    func mappingOfMappings() throws {
        let v = try parse("""
        Mark McGwire: {hr: 65, avg: 0.278}
        Sammy Sosa: {
            hr: 63,
            avg: 0.288
          }
        """)
        #expect(v["Mark McGwire"]?["hr"] == .int(65))
        #expect(v["Sammy Sosa"]?["avg"] == .double(0.288))
    }

    // MARK: - 2.2 Structures

    @Test("2.7 two documents in a stream")
    func twoDocuments() throws {
        let docs = try stream("""
        # Ranking of 1998 home runs
        ---
        - Mark McGwire
        - Sammy Sosa
        - Ken Griffey

        # Team ranking
        ---
        - Chicago Cubs
        - St Louis Cardinals
        """)
        #expect(docs.count == 2)
        #expect(docs[0].arrayElements?.count == 3)
        #expect(docs[1] == .array([.string("Chicago Cubs"), .string("St Louis Cardinals")]))
    }

    @Test("2.8 play by play feed, with end markers")
    func playByPlay() throws {
        let docs = try stream("""
        ---
        time: 20:03:20
        player: Sammy Sosa
        action: strike (miss)
        ...
        ---
        time: 20:03:47
        player: Sammy Sosa
        action: grand slam
        ...
        """)
        #expect(docs.count == 2)
        // The 1.2 core schema has no sexagesimal type, so a clock time stays a string.
        #expect(docs[0]["time"] == .string("20:03:20"))
        #expect(docs[1]["action"] == .string("grand slam"))
    }

    @Test("2.9 single document with two comments")
    func documentWithComments() throws {
        let v = try parse("""
        ---
        hr: # 1998 hr ranking
          - Mark McGwire
          - Sammy Sosa
        # 1998 rbi ranking
        rbi:
          - Sammy Sosa
          - Ken Griffey
        """)
        #expect(v["hr"]?.arrayElements?.count == 2)
        #expect(v["rbi"]?.arrayElements?[1] == .string("Ken Griffey"))
    }

    @Test("2.10 a node appears twice through an alias")
    func anchorAndAlias() throws {
        let v = try parse("""
        ---
        hr:
          - Mark McGwire
          # Following node labeled SS
          - &SS Sammy Sosa
        rbi:
          - *SS
          - Ken Griffey
        """)
        #expect(v["hr"]?.arrayElements?[1] == .string("Sammy Sosa"))
        #expect(v["rbi"]?.arrayElements?[0] == .string("Sammy Sosa"))
    }

    @Test("2.11 a sequence used as a key is refused")
    func sequenceAsKey() throws {
        // Mappings here are keyed by String, so a collection key has no representation and the
        // parser says so rather than inventing one.
        #expect(throws: YAMLParseError.self) {
            try parse("""
            ? - Detroit Tigers
              - Chicago cubs
            : - 2001-07-23
            """)
        }
    }

    @Test("2.12 compact nested mapping")
    func compactNestedMapping() throws {
        let v = try parse("""
        ---
        # Products purchased
        - item    : Super Hoop
          quantity: 1
        - item    : Basketball
          quantity: 4
        - item    : Big Shoes
          quantity: 1
        """)
        #expect(v.arrayElements?.count == 3)
        #expect(v.arrayElements?[0]["item"] == .string("Super Hoop"))
        #expect(v.arrayElements?[2]["quantity"] == .int(1))
    }

    // MARK: - 2.3 Scalars

    @Test("2.13 a literal scalar keeps newlines")
    func literalKeepsNewlines() throws {
        let v = try parse("""
        # ASCII Art
        --- |
          \\//||\\/||
          // ||  ||__
        """)
        #expect(v == .string("\\//||\\/||\n// ||  ||__\n"))
    }

    @Test("2.14 a folded scalar turns newlines into spaces")
    func foldedTurnsNewlinesIntoSpaces() throws {
        let v = try parse("""
        --- >
          Mark McGwire's
          year was crippled
          by a knee injury.
        """)
        #expect(v == .string("Mark McGwire's year was crippled by a knee injury.\n"))
    }

    @Test("2.15 folded newlines are kept for more indented and blank lines")
    func foldedKeepsMoreIndentedBreaks() throws {
        let v = try parse("""
        >
         Sammy Sosa completed another
         fine season with great stats.

           63 Home Runs
           0.288 Batting Average

         What a year!
        """)
        #expect(v == .string("""
        Sammy Sosa completed another fine season with great stats.

          63 Home Runs
          0.288 Batting Average

        What a year!

        """))
    }

    @Test("2.16 indentation determines scope")
    func indentationDeterminesScope() throws {
        let v = try parse("""
        name: Mark McGwire
        accomplishment: >
          Mark set a major league
          home run record in 1998.
        stats: |
          65 Home Runs
          0.278 Batting Average
        """)
        #expect(v["name"] == .string("Mark McGwire"))
        #expect(v["accomplishment"] == .string("Mark set a major league home run record in 1998.\n"))
        #expect(v["stats"] == .string("65 Home Runs\n0.278 Batting Average\n"))
    }

    @Test("2.17 quoted scalars")
    func quotedScalars() throws {
        let v = try parse("""
        unicode: "Sosa did fine.\\u263A"
        control: "\\b1998\\t1999\\t2000\\n"
        hex esc: "\\x0d\\x0a is \\r\\n"

        single: '"Howdy!" he cried.'
        quoted: ' # Not a ''comment''.'
        tie-fighter: '|\\-*-/|'
        """)
        #expect(v["unicode"] == .string("Sosa did fine.\u{263A}"))
        #expect(v["control"] == .string("\u{08}1998\t1999\t2000\n"))
        #expect(v["hex esc"] == .string("\r\n is \r\n"))
        #expect(v["single"] == .string("\"Howdy!\" he cried."))
        #expect(v["quoted"] == .string(" # Not a 'comment'."))
        #expect(v["tie-fighter"] == .string("|\\-*-/|"))
    }

    @Test("2.18 multi-line flow scalars")
    func multiLineFlowScalars() throws {
        let v = try parse("""
        plain:
          This unquoted scalar
          spans many lines.

        quoted: "So does this
          quoted scalar.\\n"
        """)
        #expect(v["plain"] == .string("This unquoted scalar spans many lines."))
        #expect(v["quoted"] == .string("So does this quoted scalar.\n"))
    }

    // MARK: - 2.4 Tags, and 10.3 the core schema

    @Test("2.19 integers")
    func integers() throws {
        let v = try parse("""
        canonical: 12345
        decimal: +12345
        octal: 0o14
        hexadecimal: 0xC
        """)
        #expect(v["canonical"] == .int(12345))
        #expect(v["decimal"] == .int(12345))
        #expect(v["octal"] == .int(12))
        #expect(v["hexadecimal"] == .int(12))
    }

    @Test("2.20 floating point")
    func floatingPoint() throws {
        let v = try parse("""
        canonical: 1.23015e+3
        exponential: 12.3015e+02
        fixed: 1230.15
        negative infinity: -.inf
        not a number: .nan
        """)
        #expect(v["canonical"] == .double(1230.15))
        #expect(v["exponential"] == .double(1230.15))
        #expect(v["fixed"] == .double(1230.15))
        #expect(v["negative infinity"] == .double(-.infinity))
        if case .double(let d)? = v["not a number"] { #expect(d.isNaN) } else { Issue.record("not a double") }
    }

    @Test("2.21 miscellaneous")
    func miscellaneous() throws {
        let v = try parse("""
        null:
        booleans: [ true, false ]
        string: '012345'
        """)
        #expect(v["null"] == .null)
        #expect(v["booleans"] == .array([.bool(true), .bool(false)]))
        #expect(v["string"] == .string("012345"))
    }

    @Test("2.22 timestamps stay strings under the core schema")
    func timestampsAreStrings() throws {
        // The timestamp type belongs to YAML 1.1, so 1.2's core schema reads these as strings.
        let v = try parse("""
        canonical: 2001-12-15T02:59:43.1Z
        date: 2002-12-14
        """)
        #expect(v["canonical"] == .string("2001-12-15T02:59:43.1Z"))
        #expect(v["date"] == .string("2002-12-14"))
    }

    @Test("2.23 explicit tags")
    func explicitTags() throws {
        let v = try parse("""
        not-date: !!str 2002-04-28
        picture: !!str |
          R0lGODlhDAAMAIQAAP
        application specific tag: !something |
          The semantics of the tag
          above may be different
        """)
        #expect(v["not-date"] == .string("2002-04-28"))
        #expect(v["picture"] == .string("R0lGODlhDAAMAIQAAP\n"))
        #expect(v["application specific tag"] == .string("The semantics of the tag\nabove may be different\n"))
    }

    @Test("2.24 global tags")
    func globalTags() throws {
        let v = try parse("""
        %TAG ! tag:clarkevans.com,2002:
        --- !shape
          # Use the ! handle for presenting
          # tag:clarkevans.com,2002:circle
        - !circle
          center: &ORIGIN {x: 73, y: 129}
          radius: 7
        - !line
          start: *ORIGIN
          finish: { x: 89, y: 102 }
        """)
        #expect(v.arrayElements?.count == 2)
        #expect(v.arrayElements?[0]["radius"] == .int(7))
        #expect(v.arrayElements?[1]["start"] == .object([.init(key: "x", value: .int(73)),
                                                         .init(key: "y", value: .int(129))]))
    }

    @Test("2.27 invoice")
    func invoice() throws {
        let v = try parse("""
        --- !<tag:clarkevans.com,2002:invoice>
        invoice: 34843
        date   : 2001-01-23
        bill-to: &id001
            given  : Chris
            family : Dumars
            address:
                lines: |
                    458 Walkman Dr.
                    Suite #292
                city    : Royal Oak
                state   : MI
                postal  : 48046
        ship-to: *id001
        product:
            - sku         : BL394D
              quantity    : 4
              description : Basketball
              price       : 450.00
            - sku         : BL4438H
              quantity    : 1
              description : Super Hoop
              price       : 2392.00
        tax  : 251.42
        total: 4443.52
        comments:
            Late afternoon is best.
            Backup contact is Nancy
            Billsmer @ 338-4338.
        """)
        #expect(v["invoice"] == .int(34843))
        #expect(v["bill-to"]?["given"] == .string("Chris"))
        #expect(v["ship-to"]?["family"] == .string("Dumars"))
        #expect(v["bill-to"]?["address"]?["lines"] == .string("458 Walkman Dr.\nSuite #292\n"))
        #expect(v["product"]?.arrayElements?.count == 2)
        #expect(v["product"]?.arrayElements?[1]["price"] == .double(2392.00))
        #expect(v["total"] == .double(4443.52))
        #expect(v["comments"] == .string("Late afternoon is best. Backup contact is Nancy Billsmer @ 338-4338."))
    }

    // MARK: - 5 Characters

    @Test("5.3 block structure indicators")
    func blockStructureIndicators() throws {
        let v = try parse("""
        sequence:
        - one
        - two
        mapping:
          ? sky
          : blue
          sea : green
        """)
        #expect(v["sequence"] == .array([.string("one"), .string("two")]))
        #expect(v["mapping"]?["sky"] == .string("blue"))
        #expect(v["mapping"]?["sea"] == .string("green"))
    }

    @Test("5.4 flow structure indicators")
    func flowStructureIndicators() throws {
        let v = try parse("""
        sequence: [ one, two, ]
        mapping: { sky: blue, sea: green }
        """)
        #expect(v["sequence"] == .array([.string("one"), .string("two")]))
        #expect(v["mapping"]?["sea"] == .string("green"))
    }

    @Test("5.5 a comment indicator")
    func commentIndicator() throws {
        #expect(try parse("# Comment only.") == .null)
    }

    // MARK: - 6 Basic structures

    @Test("6.1 indentation spaces")
    func indentationSpaces() throws {
        let v = try parse("""
          # Leading comment line spaces are
           # neither content nor indentation.

        Not indented:
         By one space: |
            By four
              spaces
         Flow style: [    # Leading spaces
           By two,        # in flow style
          Also by two,    # are neither
           Still by two   # content nor
            ]             # indentation.
        """)
        #expect(v["Not indented"]?["By one space"] == .string("By four\n  spaces\n"))
        #expect(v["Not indented"]?["Flow style"]
                == .array([.string("By two"), .string("Also by two"), .string("Still by two")]))
    }

    @Test("6.2 indentation indicators")
    func indentationIndicators() throws {
        let v = try parse("""
        ? a
        : -\tb
          -  -\tc
             - d
        """)
        #expect(v["a"]?.arrayElements?[0] == .string("b"))
        #expect(v["a"]?.arrayElements?[1] == .array([.string("c"), .string("d")]))
    }

    @Test("6.5 empty lines")
    func emptyLines() throws {
        let v = try parse("""
        Folding:
          "Empty line

          as a line feed"
        Chomping: |
          Clipped empty lines
        \u{20}
        """)
        #expect(v["Folding"] == .string("Empty line\nas a line feed"))
        #expect(v["Chomping"] == .string("Clipped empty lines\n"))
    }

    @Test("6.6 line folding")
    func lineFolding() throws {
        let v = try parse("""
        >-
          trimmed
        \u{20}
        \u{20}

          as
          space
        """)
        #expect(v == .string("trimmed\n\n\nas space"))
    }

    @Test("6.7 block folding")
    func blockFolding() throws {
        let v = try parse("""
        >
          foo\u{20}
        \u{20}
          \t bar

          baz
        """)
        #expect(v == .string("foo \n\n\t bar\n\nbaz\n"))
    }

    @Test("6.8 flow folding")
    func flowFolding() throws {
        let v = try parse("""
        "
          foo\u{20}
        \u{20}
          \t bar

          baz
        "
        """)
        #expect(v == .string(" foo\nbar\nbaz "))
    }

    @Test("6.9 separated comment")
    func separatedComment() throws {
        let v = try parse("""
        key:    # Comment
          value
        """)
        #expect(v["key"] == .string("value"))
    }

    @Test("6.10 comment lines")
    func commentLines() throws {
        #expect(try parse("  # Comment\n   \n\n") == .null)
    }

    @Test("6.11 multi-line comments")
    func multiLineComments() throws {
        let v = try parse("""
        key:    # Comment
                # lines
          value

        """)
        #expect(v["key"] == .string("value"))
    }

    @Test("6.14 the YAML directive")
    func yamlDirective() throws {
        let v = try parse("""
        %YAML 1.3 # Attempt parsing
                  # with a warning
        ---
        "foo"
        """)
        #expect(v == .string("foo"))
    }

    @Test("6.16 the TAG directive")
    func tagDirective() throws {
        let v = try parse("""
        %TAG !yaml! tag:yaml.org,2002:
        ---
        !yaml!str "foo"
        """)
        #expect(v == .string("foo"))
    }

    @Test("6.24 verbatim tags")
    func verbatimTags() throws {
        let v = try parse("""
        !<tag:yaml.org,2002:str> foo :
          !<!bar> baz
        """)
        #expect(v["foo"] == .string("baz"))
    }

    @Test("6.28 non-specific tags")
    func nonSpecificTags() throws {
        let v = try parse("""
        # Assuming conventional resolution:
        - "12"
        - 12
        - ! 12
        """)
        #expect(v == .array([.string("12"), .int(12), .string("12")]))
    }

    // MARK: - 7 Flow styles

    @Test("7.1 alias nodes")
    func aliasNodes() throws {
        let v = try parse("""
        First occurrence: &anchor Foo
        Second occurrence: *anchor
        Override anchor: &anchor Bar
        Reuse anchor: *anchor
        """)
        #expect(v["First occurrence"] == .string("Foo"))
        #expect(v["Second occurrence"] == .string("Foo"))
        #expect(v["Reuse anchor"] == .string("Bar"))
    }

    @Test("7.2 empty content")
    func emptyContent() throws {
        let v = try parse("""
        {
          foo : !!str,
          !!str : bar,
        }
        """)
        #expect(v["foo"] == .string(""))
        #expect(v[""] == .string("bar"))
    }

    @Test("7.3 completely empty flow nodes")
    func completelyEmptyFlowNodes() throws {
        let v = try parse("""
        {
          ? foo :,
          : bar,
        }
        """)
        #expect(v["foo"] == .null)
        #expect(v["null"] == .string("bar"))
    }

    @Test("7.6 double quoted lines")
    func doubleQuotedLines() throws {
        let v = try parse("""
        " 1st non-empty

         2nd non-empty\u{20}
        \t3rd non-empty "
        """)
        #expect(v == .string(" 1st non-empty\n2nd non-empty 3rd non-empty "))
    }

    @Test("7.7 single quoted characters")
    func singleQuotedCharacters() throws {
        #expect(try parse("'here''s to \"quotes\"'") == .string("here's to \"quotes\""))
    }

    @Test("7.9 single quoted lines")
    func singleQuotedLines() throws {
        let v = try parse("""
        ' 1st non-empty

         2nd non-empty\u{20}
        \t3rd non-empty '
        """)
        #expect(v == .string(" 1st non-empty\n2nd non-empty 3rd non-empty "))
    }

    @Test("7.12 plain lines")
    func plainLines() throws {
        let v = try parse("""
        1st non-empty

         2nd non-empty\u{20}
        \t3rd non-empty
        """)
        #expect(v == .string("1st non-empty\n2nd non-empty 3rd non-empty"))
    }

    @Test("7.13 flow sequence")
    func flowSequence() throws {
        let v = try parse("""
        - [ one, two, ]
        - [three ,four]
        """)
        #expect(v.arrayElements?[0] == .array([.string("one"), .string("two")]))
        #expect(v.arrayElements?[1] == .array([.string("three"), .string("four")]))
    }

    @Test("7.14 flow sequence entries")
    func flowSequenceEntries() throws {
        let v = try parse("""
        [
        "double
         quoted", 'single
                   quoted',
        plain
         text, [ nested ],
        single: pair,
        ]
        """)
        #expect(v.arrayElements?[0] == .string("double quoted"))
        #expect(v.arrayElements?[1] == .string("single quoted"))
        #expect(v.arrayElements?[2] == .string("plain text"))
        #expect(v.arrayElements?[3] == .array([.string("nested")]))
        #expect(v.arrayElements?[4] == .object([.init(key: "single", value: .string("pair"))]))
    }

    @Test("7.15 flow mappings")
    func flowMappings() throws {
        let v = try parse("""
        - { one : two , three: four , }
        - {five: six,seven : eight}
        """)
        #expect(v.arrayElements?[0]["three"] == .string("four"))
        #expect(v.arrayElements?[1]["seven"] == .string("eight"))
    }

    @Test("7.16 flow mapping entries")
    func flowMappingEntries() throws {
        let v = try parse("""
        {
        ? explicit: entry,
        implicit: entry,
        ?
        }
        """)
        #expect(v["explicit"] == .string("entry"))
        #expect(v["implicit"] == .string("entry"))
        #expect(v["null"] == .null)
    }

    @Test("7.18 flow mapping adjacent values")
    func flowMappingAdjacentValues() throws {
        let v = try parse("""
        {
        "adjacent":value,
        "readable": value,
        "empty":
        }
        """)
        #expect(v["adjacent"] == .string("value"))
        #expect(v["readable"] == .string("value"))
        #expect(v["empty"] == .null)
    }

    @Test("7.19 single pair flow mappings")
    func singlePairFlowMappings() throws {
        let v = try parse("[ foo: bar ]")
        #expect(v == .array([.object([.init(key: "foo", value: .string("bar"))])]))
    }

    // MARK: - 8 Block styles

    @Test("8.1 block scalar headers")
    func blockScalarHeaders() throws {
        let v = try parse("""
        - | # Empty header
         literal
        - >1 # Indentation indicator
          folded
        - |+ # Chomping indicator
         keep

        - >1- # Both indicators
          strip
        """)
        #expect(v.arrayElements?[0] == .string("literal\n"))
        #expect(v.arrayElements?[1] == .string(" folded\n"))
        #expect(v.arrayElements?[2] == .string("keep\n\n"))
        #expect(v.arrayElements?[3] == .string(" strip"))
    }

    @Test("8.2 block indentation indicator")
    func blockIndentationIndicator() throws {
        let v = try parse("""
        - |
         detected
        - >
        \u{20}
        \u{20}\u{20}
          # detected
        - |1
          explicit
        """)
        #expect(v.arrayElements?[0] == .string("detected\n"))
        #expect(v.arrayElements?[1] == .string("\n\n# detected\n"))
        #expect(v.arrayElements?[2] == .string(" explicit\n"))
    }

    @Test("8.4 chomping the final line break")
    func chompingFinalLineBreak() throws {
        let v = try parse("""
        strip: |-
          text
        clip: |
          text
        keep: |+
          text
        """)
        #expect(v["strip"] == .string("text"))
        #expect(v["clip"] == .string("text\n"))
        #expect(v["keep"] == .string("text\n"))
    }

    @Test("8.5 chomping trailing lines")
    func chompingTrailingLines() throws {
        let v = try parse("""
         # Strip
          # Comments:
        strip: |-
          # text

         # Clip
          # comments:

        clip: |
          # text

         # Keep
          # comments:

        keep: |+
          # text

         # Trail
          # comments.
        """)
        #expect(v["strip"] == .string("# text"))
        #expect(v["clip"] == .string("# text\n"))
        // Keep holds the trailing empty line as well, which is what separates this example from 8.4.
        #expect(v["keep"] == .string("# text\n\n"))
    }

    @Test("8.6 empty scalar chomping")
    func emptyScalarChomping() throws {
        // The trailing newline matters: the kept scalar's content is the one empty line after it.
        let v = try parse("""
        strip: >-

        clip: >

        keep: |+

        """ + "\n")
        #expect(v["strip"] == .string(""))
        #expect(v["clip"] == .string(""))
        #expect(v["keep"] == .string("\n"))
    }

    @Test("8.7 literal scalar")
    func literalScalar() throws {
        let v = try parse("""
        |
         literal
         \ttext

        """)
        #expect(v == .string("literal\n\ttext\n"))
    }

    @Test("8.9 folded scalar")
    func foldedScalar() throws {
        let v = try parse("""
        >
         folded
         text

        """)
        #expect(v == .string("folded text\n"))
    }

    @Test("8.14 block sequence")
    func blockSequence() throws {
        let v = try parse("""
        block sequence:
          - one
          - two : three
        """)
        #expect(v["block sequence"]?.arrayElements?[0] == .string("one"))
        #expect(v["block sequence"]?.arrayElements?[1]["two"] == .string("three"))
    }

    @Test("8.15 block sequence entry types")
    func blockSequenceEntryTypes() throws {
        let v = try parse("""
        - # Empty
        - |
         block node
        - - one # Compact
          - two # sequence
        - one: two # Compact mapping
        """)
        #expect(v.arrayElements?[0] == .null)
        #expect(v.arrayElements?[1] == .string("block node\n"))
        #expect(v.arrayElements?[2] == .array([.string("one"), .string("two")]))
        #expect(v.arrayElements?[3] == .object([.init(key: "one", value: .string("two"))]))
    }

    @Test("8.16 block mappings")
    func blockMappings() throws {
        let v = try parse("""
        block mapping:
         key: value
        """)
        #expect(v["block mapping"]?["key"] == .string("value"))
    }

    @Test("8.17 explicit block mapping entries")
    func explicitBlockMappingEntries() throws {
        let v = try parse("""
        ? explicit key # Empty value
        ? |
          block key
        : - one # Explicit compact
          - two # block value
        """)
        #expect(v["explicit key"] == .null)
        #expect(v["block key\n"] == .array([.string("one"), .string("two")]))
    }

    @Test("8.20 block node types")
    func blockNodeTypes() throws {
        let v = try parse("""
        -
          "flow in block"
        - >
         Block scalar
        - !!map # Block collection
          foo : bar
        """)
        #expect(v.arrayElements?[0] == .string("flow in block"))
        #expect(v.arrayElements?[1] == .string("Block scalar\n"))
        #expect(v.arrayElements?[2]["foo"] == .string("bar"))
    }

    @Test("8.22 block collection nodes")
    func blockCollectionNodes() throws {
        let v = try parse("""
        sequence: !!seq
        - entry
        - !!seq
         - nested
        mapping: !!map
         foo: bar
        """)
        #expect(v["sequence"]?.arrayElements?[0] == .string("entry"))
        #expect(v["sequence"]?.arrayElements?[1] == .array([.string("nested")]))
        #expect(v["mapping"]?["foo"] == .string("bar"))
    }

    // MARK: - 9 Document stream

    @Test("9.2 document markers")
    func documentMarkers() throws {
        let docs = try stream("""
        %YAML 1.2
        ---
        Document
        ... # Suffix
        """)
        #expect(docs == [.string("Document")])
    }

    @Test("9.3 bare documents")
    func bareDocuments() throws {
        let docs = try stream("""
        Bare
        document
        ...
        # No document
        ...
        |
        %!PS-Adobe-2.0 # Not the first line
        """)
        // A '...' with no '---' of its own does not start a document, so the "# No document" line
        // between the two end markers never produces one: this stream holds two documents, not three.
        #expect(docs.count == 2)
        #expect(docs[0] == .string("Bare document"))
        #expect(docs[1] == .string("%!PS-Adobe-2.0 # Not the first line\n"))
    }

    @Test("9.5 directives documents")
    func directivesDocuments() throws {
        let docs = try stream("""
        %YAML 1.2
        --- |
        %!PS-Adobe-2.0
        ...
        %YAML 1.2
        ---
        # Empty
        ...
        """)
        #expect(docs.count == 2)
        #expect(docs[0] == .string("%!PS-Adobe-2.0\n"))
        #expect(docs[1] == .null)
    }

    @Test("10.2 the core schema resolves the JSON types")
    func coreSchemaResolution() throws {
        let v = try parse("""
        A null: null
        Also a null: ~
        Not a null: ""
        Booleans: [ true, True, TRUE, false, False, FALSE ]
        Integers: [ 0, 0o7, 0x3A, -19 ]
        Floats: [ 0., -0.0, .5, +12e03, -2E+05 ]
        Also floats: [ .inf, -.Inf, +.INF, .NAN ]
        """)
        #expect(v["A null"] == .null)
        #expect(v["Also a null"] == .null)
        #expect(v["Not a null"] == .string(""))
        #expect(v["Booleans"] == .array([.bool(true), .bool(true), .bool(true),
                                         .bool(false), .bool(false), .bool(false)]))
        #expect(v["Integers"] == .array([.int(0), .int(7), .int(58), .int(-19)]))
        #expect(v["Floats"] == .array([.double(0), .double(-0.0), .double(0.5),
                                       .double(12000), .double(-200000)]))
        let special = v["Also floats"]?.arrayElements
        #expect(special?[0] == .double(.infinity))
        #expect(special?[1] == .double(-.infinity))
        #expect(special?[2] == .double(.infinity))
        if case .double(let d)? = special?[3] { #expect(d.isNaN) } else { Issue.record("not a double") }
    }

    @Test("10.2 the core schema leaves the YAML 1.1 booleans as strings")
    func coreSchemaLeaves11BooleansAsStrings() throws {
        let v = try parse("[ yes, no, on, off, y, n, Yes, Off ]")
        #expect(v == .array([.string("yes"), .string("no"), .string("on"), .string("off"),
                             .string("y"), .string("n"), .string("Yes"), .string("Off")]))
    }
}
