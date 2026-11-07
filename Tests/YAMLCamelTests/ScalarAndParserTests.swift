import XCTest
@testable import YAMLCamel

final class ScalarResolutionTests: XCTestCase {

    private func loadScalar(_ s: String) throws -> YAMLValue {
        // Wrap as a mapping value so the scalar goes through the normal value path.
        let v = try YAMLParser.parse("k: \(s)")
        return v["k"] ?? .null
    }

    func testCoreSchemaNulls() throws {
        for s in ["null", "Null", "NULL", "~"] {
            XCTAssertEqual(try loadScalar(s), .null, "\(s)")
        }
        XCTAssertEqual(try YAMLParser.parse("k:")["k"], .null)
    }

    func testCoreSchemaBooleans() throws {
        for s in ["true", "True", "TRUE"] { XCTAssertEqual(try loadScalar(s), .bool(true), s) }
        for s in ["false", "False", "FALSE"] { XCTAssertEqual(try loadScalar(s), .bool(false), s) }
    }

    func testYAML12DoesNotTreatYesNoOnOffAsBool() throws {
        for s in ["yes", "no", "on", "off", "Yes", "On"] {
            XCTAssertEqual(try loadScalar(s), .string(s), "\(s) must stay a string in 1.2 core schema")
        }
    }

    func testIntegers() throws {
        XCTAssertEqual(try loadScalar("0"), .int(0))
        XCTAssertEqual(try loadScalar("42"), .int(42))
        XCTAssertEqual(try loadScalar("-7"), .int(-7))
        XCTAssertEqual(try loadScalar("+9"), .int(9))
        XCTAssertEqual(try loadScalar("0x1F"), .int(31))
        XCTAssertEqual(try loadScalar("0o17"), .int(15))
    }

    // 10.3.2: the core schema's int regexp is `0 | -?[1-9][0-9]* | 0o[0-7]+ | 0x[0-9a-fA-F]+`,
    // with no underscores and no leading-zero octal; a leading zero is just another decimal digit.
    func testLeadingZeroIsDecimalNotLegacyOctal() throws {
        XCTAssertEqual(try loadScalar("010"), .int(10))
        XCTAssertEqual(try loadScalar("0755"), .int(755))
    }

    // 1.1's core int/float types allowed `_` as a digit separator; 1.2's core schema regexps have
    // no such production, so an underscore anywhere in a number leaves it a plain string.
    func testUnderscoreSeparatorsStayStrings() throws {
        XCTAssertEqual(try loadScalar("1_000"), .string("1_000"))
        XCTAssertEqual(try loadScalar("1_000.5"), .string("1_000.5"))
    }

    // 1.1 had a `0b` binary int and a sexagesimal (base-60, `1:20:30`) int and float; the 1.2 core
    // schema dropped both, so they resolve as strings here same as any other unmatched plain scalar.
    func testBinaryAndSexagesimalStayStrings() throws {
        XCTAssertEqual(try loadScalar("0b1010"), .string("0b1010"))
        XCTAssertEqual(try loadScalar("1:20:30"), .string("1:20:30"))
    }

    func testFloats() throws {
        XCTAssertEqual(try loadScalar("2.4"), .double(2.4))
        XCTAssertEqual(try loadScalar("-0.5"), .double(-0.5))
        XCTAssertEqual(try loadScalar("1e3"), .double(1000))
        XCTAssertEqual(try loadScalar("6.022e23"), .double(6.022e23))
        if case .double(let d)? = try YAMLParser.parse("k: .inf")["k"] { XCTAssertEqual(d, .infinity) } else { XCTFail() }
        if case .double(let d)? = try YAMLParser.parse("k: .nan")["k"] { XCTAssertTrue(d.isNaN) } else { XCTFail() }
    }

    func testVersionLikeStringsStayStrings() throws {
        XCTAssertEqual(try loadScalar("2.4.1"), .string("2.4.1"))
        XCTAssertEqual(try loadScalar("1.0.0-beta"), .string("1.0.0-beta"))
        // Bare words that resemble special floats without the leading dot stay strings.
        XCTAssertEqual(try loadScalar("inf"), .string("inf"))
        XCTAssertEqual(try loadScalar("nan"), .string("nan"))
    }

    func testQuotedScalarsAreAlwaysStrings() throws {
        XCTAssertEqual(try loadScalar("\"true\""), .string("true"))
        XCTAssertEqual(try loadScalar("'123'"), .string("123"))
        XCTAssertEqual(try loadScalar("\"2.4\""), .string("2.4"))
    }

    func testDoubleQuotedEscapes() throws {
        XCTAssertEqual(try loadScalar("\"a\\nb\""), .string("a\nb"))
        XCTAssertEqual(try loadScalar("\"tab\\there\""), .string("tab\there"))
        XCTAssertEqual(try loadScalar("\"quote\\\"x\""), .string("quote\"x"))
        XCTAssertEqual(try loadScalar("\"\\u00e9\""), .string("é"))
    }

    func testSingleQuotedEscape() throws {
        XCTAssertEqual(try loadScalar("'it''s'"), .string("it's"))
        // A colon inside single quotes stays literal.
        XCTAssertEqual(try loadScalar("'a: b'"), .string("a: b"))
    }
}

final class ParserStructureTests: XCTestCase {

    func testBlockMapping() throws {
        let y = "name: Konyha\nid: kitchen\ncount: 3\n"
        let v = try YAMLParser.parse(y)
        XCTAssertEqual(v["name"], .string("Konyha"))
        XCTAssertEqual(v["id"], .string("kitchen"))
        XCTAssertEqual(v["count"], .int(3))
    }

    func testNestedMappingByIndent() throws {
        let y = """
        outer:
          inner: value
          number: 5
        sibling: x
        """
        let v = try YAMLParser.parse(y)
        XCTAssertEqual(v["outer"]?["inner"], .string("value"))
        XCTAssertEqual(v["outer"]?["number"], .int(5))
        XCTAssertEqual(v["sibling"], .string("x"))
    }

    func testSequenceAtKeyIndent() throws {
        let y = """
        items:
        - a
        - b
        - c
        """
        XCTAssertEqual(try YAMLParser.parse(y)["items"], .array([.string("a"), .string("b"), .string("c")]))
    }

    func testSequenceIndentedUnderKey() throws {
        let y = """
        items:
          - a
          - b
        """
        XCTAssertEqual(try YAMLParser.parse(y)["items"], .array([.string("a"), .string("b")]))
    }

    func testSequenceOfMappingsWithContinuation() throws {
        let y = """
        rows:
          - stem: ház
            form: házban
          - stem: kép
            form: képben
        """
        let rows = try YAMLParser.parse(y)["rows"]?.arrayElements
        XCTAssertEqual(rows?.count, 2)
        XCTAssertEqual(rows?[0]["stem"], .string("ház"))
        XCTAssertEqual(rows?[0]["form"], .string("házban"))
        XCTAssertEqual(rows?[1]["form"], .string("képben"))
    }

    func testCommentsIgnored() throws {
        let y = """
        # leading comment
        a: 1   # trailing comment
        # another
        b: 2
        """
        let v = try YAMLParser.parse(y)
        XCTAssertEqual(v["a"], .int(1))
        XCTAssertEqual(v["b"], .int(2))
    }

    func testHashInsideValueIsNotComment() throws {
        XCTAssertEqual(try YAMLParser.parse("lang: C#")["lang"], .string("C#"))
    }

    func testLeadingDocumentMarkerSkipped() throws {
        let v = try YAMLParser.parse("---\na: 1\n")
        XCTAssertEqual(v["a"], .int(1))
    }

    func testDashPrefixedScalarIsNotSequence() throws {
        XCTAssertEqual(try YAMLParser.parse("suffix: -ban/-ben")["suffix"], .string("-ban/-ben"))
        XCTAssertEqual(try YAMLParser.parse("n: -5")["n"], .int(-5))
    }
}
