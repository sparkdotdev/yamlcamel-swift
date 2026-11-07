import XCTest
@testable import YAMLCamel

final class FlowTests: XCTestCase {

    func testFlowSequenceOfScalars() throws {
        XCTAssertEqual(try YAMLParser.parse("k: [1, 2, 3]")["k"],
                       .array([.int(1), .int(2), .int(3)]))
    }

    func testFlowSequenceWithQuotedCommaMembers() throws {
        // Quoted members contain commas that must not split items.
        let v = try YAMLParser.parse("row: [em, \"o, a, os, as\", \"no, na, nos, nas\"]")["row"]
        XCTAssertEqual(v, .array([.string("em"), .string("o, a, os, as"), .string("no, na, nos, nas")]))
    }

    func testNestedFlow() throws {
        let v = try YAMLParser.parse("m: [[a, b], [c, d]]")["m"]
        XCTAssertEqual(v, .array([.array([.string("a"), .string("b")]),
                                  .array([.string("c"), .string("d")])]))
    }

    func testFlowMapping() throws {
        let v = try YAMLParser.parse("obj: {suffix: -unk, count: 2}")["obj"]
        XCTAssertEqual(v?["suffix"], .string("-unk"))
        XCTAssertEqual(v?["count"], .int(2))
    }

    func testSequenceItemIsFlowSequence() throws {
        let y = """
        table:
        - [em, "o, a", "no, na"]
        - [de, "o", "do"]
        """
        let rows = try YAMLParser.parse(y)["table"]?.arrayElements
        XCTAssertEqual(rows?.count, 2)
        XCTAssertEqual(rows?[0], .array([.string("em"), .string("o, a"), .string("no, na")]))
    }

    func testEmptyFlowCollections() throws {
        XCTAssertEqual(try YAMLParser.parse("a: []")["a"], .array([]))
        XCTAssertEqual(try YAMLParser.parse("a: {}")["a"], .object([]))
    }

    func testUnterminatedFlowThrows() {
        XCTAssertThrowsError(try YAMLParser.parse("a: [1, 2"))
    }
}

final class BlockScalarTests: XCTestCase {

    func testLiteralBlockScalar() throws {
        let y = """
        text: |
          line one
          line two
        next: x
        """
        XCTAssertEqual(try YAMLParser.parse(y)["text"], .string("line one\nline two\n"))
        XCTAssertEqual(try YAMLParser.parse(y)["next"], .string("x"))
    }

    func testLiteralStripChomping() throws {
        let y = """
        text: |-
          only line
        """
        XCTAssertEqual(try YAMLParser.parse(y)["text"], .string("only line"))
    }

    func testFoldedBlockScalar() throws {
        let y = """
        intro: >
          these words
          become one line
        """ + "\n"
        XCTAssertEqual(try YAMLParser.parse(y)["intro"], .string("these words become one line\n"))
    }

    func testFoldedStripChomping() throws {
        // A folded scalar with strip chomping, followed by a sibling key.
        let y = """
        intro: >-
          Question words travel
          in families here.
        after: y
        """
        XCTAssertEqual(try YAMLParser.parse(y)["intro"], .string("Question words travel in families here."))
        XCTAssertEqual(try YAMLParser.parse(y)["after"], .string("y"))
    }

    func testFoldedParagraphs() throws {
        let y = """
        p: >
          para one line one
          para one line two

          para two
        """ + "\n"
        XCTAssertEqual(try YAMLParser.parse(y)["p"], .string("para one line one para one line two\npara two\n"))
    }
}
