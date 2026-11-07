import XCTest
@testable import YAMLCamel

// Types mirroring real Codable shapes this library encodes and decodes.

private struct Word: Codable, Equatable {
    var hu: String
    var en: String
    var note: String?
    var pos: String?
}

private struct Section: Codable, Equatable {
    var name: String
    var id: String
    var type: String?
    var words: [Word]
}

private struct Wrapper: Codable, Equatable { var sections: [Section] }

private struct Payload: Codable, Equatable {
    var schemaVersion: Int
    var id: String
    var name: String
    var words: [Word]
}

final class CodableDecodeTests: XCTestCase {

    func testDecodeNestedStructWithOptionals() throws {
        let y = """
        name: Konyha
        id: kitchen
        words:
        - hu: kés
          en: knife
        - hu: kanál
          en: spoon
          note: evőeszköz
          pos: noun
        """
        let s = try YAMLDecoder().decode(Section.self, from: y)
        XCTAssertEqual(s.name, "Konyha")
        XCTAssertEqual(s.words.count, 2)
        XCTAssertEqual(s.words[0], Word(hu: "kés", en: "knife", note: nil, pos: nil))
        XCTAssertEqual(s.words[1], Word(hu: "kanál", en: "spoon", note: "evőeszköz", pos: "noun"))
    }

    func testDecodeTopLevelArray() throws {
        let y = """
        - hu: egy
          en: one
        - hu: kettő
          en: two
        """
        let words = try YAMLDecoder().decode([Word].self, from: y)
        XCTAssertEqual(words.map(\.hu), ["egy", "kettő"])
    }

    func testDecodeIntField() throws {
        let y = "schemaVersion: 1\nid: p\nname: Test\nwords: []\n"
        let p = try YAMLDecoder().decode(Payload.self, from: y)
        XCTAssertEqual(p.schemaVersion, 1)
        XCTAssertTrue(p.words.isEmpty)
    }

    func testDecodeFromData() throws {
        let data = Data("id: x\nname: N\nwords: []\nschemaVersion: 2\n".utf8)
        let p = try YAMLDecoder().decode(Payload.self, from: data)
        XCTAssertEqual(p.schemaVersion, 2)
    }

    func testMissingOptionalIsNil() throws {
        let w = try YAMLDecoder().decode(Word.self, from: "hu: a\nen: b\n")
        XCTAssertNil(w.note)
        XCTAssertNil(w.pos)
    }
}

final class CodableEncodeTests: XCTestCase {

    func testEncodeDropsNilOptionals() throws {
        let s = Section(name: "A", id: "a", type: "vocab",
                        words: [Word(hu: "x", en: "y", note: nil, pos: nil)])
        let yaml = try YAMLEncoder().encode(Wrapper(sections: [s]))
        XCTAssertTrue(yaml.contains("sections:"))
        XCTAssertFalse(yaml.contains("note:"))
        XCTAssertFalse(yaml.contains("pos:"))
    }

    func testEncodeIntNotFloat() throws {
        let p = Payload(schemaVersion: 1, id: "p", name: "N", words: [])
        let yaml = try YAMLEncoder().encode(p)
        XCTAssertTrue(yaml.contains("schemaVersion: 1"))
        XCTAssertFalse(yaml.contains("1.0"), "Int must not emit as a float")
    }

    func testSortKeysIsDeterministicAndSorted() throws {
        let p = Payload(schemaVersion: 1, id: "p", name: "N",
                        words: [Word(hu: "kutya", en: "dog", note: nil, pos: nil)])
        let enc = YAMLEncoder()
        enc.options.sortKeys = true
        let a = try enc.encode(p)
        let b = try enc.encode(p)
        XCTAssertEqual(a, b, "sorted output must be deterministic")
        // id < name < schemaVersion < words
        let idxId = a.range(of: "id:")!.lowerBound
        let idxName = a.range(of: "name:")!.lowerBound
        let idxSchema = a.range(of: "schemaVersion:")!.lowerBound
        let idxWords = a.range(of: "words:")!.lowerBound
        XCTAssertTrue(idxId < idxName && idxName < idxSchema && idxSchema < idxWords)
    }

    func testRoundTrip() throws {
        let original = Wrapper(sections: [
            Section(name: "Konyha", id: "kitchen", type: "vocab", words: [
                Word(hu: "kés", en: "knife", note: nil, pos: nil),
                Word(hu: "kanál", en: "spoon", note: "evőeszköz", pos: "noun"),
            ])
        ])
        let yaml = try YAMLEncoder().encode(original)
        let decoded = try YAMLDecoder().decode(Wrapper.self, from: yaml)
        XCTAssertEqual(decoded, original)
    }

    func testRoundTripAmbiguousStringsGetQuoted() throws {
        // Values that would re-read as null, a bool or a number have to survive as strings.
        let s = Section(name: "true", id: "123", type: "2.4",
                        words: [Word(hu: "null", en: "~", note: nil, pos: nil)])
        let yaml = try YAMLEncoder().encode(s)
        let back = try YAMLDecoder().decode(Section.self, from: yaml)
        XCTAssertEqual(back, s)
    }

    func testEncodeSpecialCharsRoundTrip() throws {
        let w = Word(hu: "a: b # c", en: "line1\nline2", note: "  spaced  ", pos: "x,y")
        let yaml = try YAMLEncoder().encode(w)
        let back = try YAMLDecoder().decode(Word.self, from: yaml)
        XCTAssertEqual(back, w)
    }

    // A UInt64 above Int64.max has no exact Int representation, which is what .uint exists for.

    func testUInt64AboveInt64MaxRoundTrips() throws {
        struct V: Codable, Equatable { var x: UInt64 }
        let original = V(x: 10_000_000_000_000_000_500)
        let yaml = try YAMLEncoder().encode(original)
        XCTAssertEqual(yaml, "x: 10000000000000000500\n", "must emit as a plain decimal, not scientific notation")
        let back = try YAMLDecoder().decode(V.self, from: yaml)
        XCTAssertEqual(back, original)
    }

    func testUInt64MaxRoundTrips() throws {
        struct V: Codable, Equatable { var x: UInt64 }
        let original = V(x: UInt64.max)
        let yaml = try YAMLEncoder().encode(original)
        let back = try YAMLDecoder().decode(V.self, from: yaml)
        XCTAssertEqual(back, original)
    }

    func testUIntAboveInt64MaxRoundTrips() throws {
        struct V: Codable, Equatable { var x: UInt }
        let original = V(x: UInt(UInt64.max))
        let yaml = try YAMLEncoder().encode(original)
        let back = try YAMLDecoder().decode(V.self, from: yaml)
        XCTAssertEqual(back, original)
    }

    func testUInt64AboveInt64MaxDecodesFromPlainLiteral() throws {
        struct V: Codable, Equatable { var x: UInt64 }
        let v = try YAMLDecoder().decode(V.self, from: "x: 18446744073709551615\n")
        XCTAssertEqual(v.x, UInt64.max)
    }

    func testUInt64AboveInt64MaxOverflowingFieldThrows() throws {
        struct Small: Codable { var x: UInt32 }
        XCTAssertThrowsError(try YAMLDecoder().decode(Small.self, from: "x: 18446744073709551615\n"))
    }

    func testUInt64AboveInt64MaxAsExplicitIntTag() throws {
        let v = try YAMLParser.parse("!!int 18446744073709551615")
        XCTAssertEqual(v, .uint(UInt64.max))
    }

    func testNegativeZeroKeepsItsSign() throws {
        // Int64 has no negative zero, so a Double field holding -0.0 must not fall through the
        // integer-formatting path the way every other whole-number Double does.
        struct V: Codable { var x: Double }
        let yaml = try YAMLEncoder().encode(V(x: -0.0))
        XCTAssertTrue(yaml.contains("-0.0"), "expected -0.0 in output, got \(yaml)")
        let back = try YAMLDecoder().decode(V.self, from: yaml)
        XCTAssertEqual(back.x.sign, .minus)
    }
}
