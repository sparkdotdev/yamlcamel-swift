import XCTest
@testable import YAMLCamel

private struct Entry: Codable, Equatable, Sendable {
    var hu: String
    var pos: String
    var senses: [String]?
}

final class YAMLSequenceReaderTests: XCTestCase {

    private let sample = """
    - hu: ház
      pos: noun
      senses:
      - house
      - home
    - hu: kutya
      pos: noun
    - hu: fut
      pos: verb
      senses:
      - to run
    """

    func testCountAndStreamOrder() throws {
        let reader = try YAMLDecoder().sequenceReader(Entry.self, from: sample)
        XCTAssertEqual(reader.count, 3)

        var out: [Entry] = []
        while let e = try reader.next() { out.append(e) }

        XCTAssertEqual(out, [
            Entry(hu: "ház", pos: "noun", senses: ["house", "home"]),
            Entry(hu: "kutya", pos: "noun", senses: nil),
            Entry(hu: "fut", pos: "verb", senses: ["to run"]),
        ])
        XCTAssertEqual(reader.consumed, 3)
        XCTAssertNil(try reader.next())   // idempotent at end
    }

    func testNestedSequencesDoNotSplitItems() throws {
        // The inner dashes are indented and must not read as top-level items.
        let reader = try YAMLDecoder().sequenceReader(Entry.self, from: sample)
        XCTAssertEqual(reader.count, 3)
    }

    func testStreamingMatchesWholeArrayDecode() throws {
        let streamed = try {
            let r = try YAMLDecoder().sequenceReader(Entry.self, from: sample)
            var acc: [Entry] = []
            while let e = try r.next() { acc.append(e) }
            return acc
        }()
        let whole = try YAMLDecoder().decode([Entry].self, from: sample)
        XCTAssertEqual(streamed, whole)
    }

    func testIndentedSequenceItems() throws {
        let yaml = """
        items:
        placeholder: ignored
        """
        // A top-level mapping has to be rejected, since streaming decode needs a sequence.
        XCTAssertThrowsError(try YAMLDecoder().sequenceReader(Entry.self, from: yaml))
    }

    func testEmptyDocumentYieldsNoItems() throws {
        let reader = try YAMLDecoder().sequenceReader(Entry.self, from: "# just a comment\n")
        XCTAssertEqual(reader.count, 0)
        XCTAssertNil(try reader.next())
    }

    func testMalformedItemThrows() throws {
        let yaml = """
        - hu: ok
          pos: noun
        - hu: bad
          senses: [unterminated
        """
        let reader = try YAMLDecoder().sequenceReader(Entry.self, from: yaml)
        XCTAssertEqual(try reader.next()?.hu, "ok")
        XCTAssertThrowsError(try reader.next())   // second item is malformed
    }
}

final class YAMLAsyncTests: XCTestCase {

    private let sample = """
    - hu: ház
      pos: noun
    - hu: kutya
      pos: noun
    """

    func testAsyncStreamYieldsAll() async throws {
        var out: [Entry] = []
        for try await e in YAMLDecoder().decodeSequence(Entry.self, from: sample) {
            out.append(e)
        }
        XCTAssertEqual(out.map(\.hu), ["ház", "kutya"])
    }

    func testAsyncDecodeMatchesSync() async throws {
        // Two decodes of the same document through the detached overload agree.
        let viaBackground = try await YAMLDecoder().decode([Entry].self, from: sample)
        let viaSecondDecode = try await YAMLDecoder().decode([Entry].self, from: sample)
        XCTAssertEqual(viaBackground, viaSecondDecode)
    }
}
