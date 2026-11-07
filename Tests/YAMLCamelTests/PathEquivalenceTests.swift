import XCTest
@testable import YAMLCamel

/// One construct-heavy sample decoded through whole decode, string streaming and byte streaming,
/// asserting that every path agrees and that the decoded values are right.
final class PathEquivalenceTests: XCTestCase {

    struct Row: Codable, Equatable {
        var name: String
        var count: Int?
        var ratio: Double?
        var active: Bool?
        var tags: [String]?
        var table: [[String]]?
        var note: String?
        var meta: Meta?
        struct Meta: Codable, Equatable { var id: String; var level: String? }
    }

    // Covers unicode, every scalar type, flow sequences with a quoted comma member, an empty flow
    // sequence, a folded block scalar, nested mappings and both present and absent optionals.
    let yaml = """
    - name: ház
      count: 3
      ratio: 2.5
      active: true
      tags: [a, "b, c", d]
      table:
      - [x1, y1]
      - [x2, y2]
      note: >-
        folded note line one
        line two
      meta:
        id: h1
        level: A1
    - name: "quoted: name"
      tags: []
      meta:
        id: k2
    """

    var expected: [Row] {
        [
            Row(name: "ház", count: 3, ratio: 2.5, active: true,
                tags: ["a", "b, c", "d"],
                table: [["x1", "y1"], ["x2", "y2"]],
                note: "folded note line one line two",
                meta: .init(id: "h1", level: "A1")),
            Row(name: "quoted: name", count: nil, ratio: nil, active: nil,
                tags: [], table: nil, note: nil,
                meta: .init(id: "k2", level: nil)),
        ]
    }

    private func wholeDecode() throws -> [Row] {
        try YAMLDecoder().decode([Row].self, from: yaml)
    }

    private func stringStream() throws -> [Row] {
        let reader = try YAMLDecoder().sequenceReader(Row.self, from: yaml)
        var out: [Row] = []
        while let r = try reader.next() { out.append(r) }
        return out
    }

    private func byteStream(chunkSize: Int) throws -> [Row] {
        let reader = YAMLByteSequenceReader<Row>()
        let bytes = [UInt8](Data(yaml.utf8))
        var out: [Row] = []
        var i = 0
        while i < bytes.count {
            let end = min(i + chunkSize, bytes.count)
            out.append(contentsOf: try reader.push(Array(bytes[i..<end])))
            i = end
        }
        out.append(contentsOf: try reader.finish())
        return out
    }

    func testWholeDecodeIsCorrect() throws {
        XCTAssertEqual(try wholeDecode(), expected)
    }

    func testAllPathsAgreeAndAreCorrect() throws {
        let whole = try wholeDecode()
        XCTAssertEqual(whole, expected)
        XCTAssertEqual(try stringStream(), expected)
        XCTAssertEqual(try byteStream(chunkSize: 1), expected)     // one byte at a time
        XCTAssertEqual(try byteStream(chunkSize: 7), expected)
        XCTAssertEqual(try byteStream(chunkSize: 4096), expected)  // a single push
    }

    func testTrickyScalarsSurviveEveryPath() throws {
        for rows in [try wholeDecode(), try stringStream(), try byteStream(chunkSize: 1)] {
            XCTAssertEqual(rows[0].tags?[1], "b, c")                 // a comma inside quotes does not split
            XCTAssertEqual(rows[0].note, "folded note line one line two")
            XCTAssertEqual(rows[0].table, [["x1", "y1"], ["x2", "y2"]])
            XCTAssertEqual(rows[1].name, "quoted: name")            // an inner colon in double quotes
            XCTAssertEqual(rows[1].tags, [])                        // an empty flow sequence
            XCTAssertNil(rows[1].count)
        }
    }
}
