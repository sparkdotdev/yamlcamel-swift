import XCTest
@testable import YAMLCamel

private struct Row: Codable, Equatable {
    var hu: String
    var pos: String
    var senses: [String]?
}

final class YAMLByteSequenceReaderTests: XCTestCase {

    private let yaml = """
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

    private var expected: [Row] {
        [
            Row(hu: "ház", pos: "noun", senses: ["house", "home"]),
            Row(hu: "kutya", pos: "noun", senses: nil),
            Row(hu: "fut", pos: "verb", senses: ["to run"]),
        ]
    }

    /// The decoded result has to be identical however the byte stream is chunked, including when an
    /// item boundary falls across a chunk edge.
    func testChunkBoundaryInvariance() throws {
        let bytes = [UInt8](Data(yaml.utf8))
        for chunkSize in [1, 2, 3, 7, 16, 64, 1024] {
            let reader = YAMLByteSequenceReader<Row>()
            var out: [Row] = []
            var i = 0
            while i < bytes.count {
                let end = min(i + chunkSize, bytes.count)
                out.append(contentsOf: try reader.push(Array(bytes[i..<end])))
                i = end
            }
            out.append(contentsOf: try reader.finish())
            XCTAssertEqual(out, expected, "chunkSize=\(chunkSize)")
        }
    }

    func testCRLFTolerated() throws {
        let crlf = yaml.replacingOccurrences(of: "\n", with: "\r\n")
        let reader = YAMLByteSequenceReader<Row>()
        var out = try reader.push(Data(crlf.utf8))
        out.append(contentsOf: try reader.finish())
        XCTAssertEqual(out, expected)
    }

    func testSkipResumesCorrectly() throws {
        let reader = YAMLByteSequenceReader<Row>()
        reader.skip(2)   // as if the first two were already ingested
        var out = try reader.push(Data(yaml.utf8))
        out.append(contentsOf: try reader.finish())
        XCTAssertEqual(out, [Row(hu: "fut", pos: "verb", senses: ["to run"])])
        XCTAssertEqual(reader.emitted, 3)   // all three boundaries are still scanned
    }

    func testTrailingNewlineHandled() throws {
        let reader = YAMLByteSequenceReader<Row>()
        var out = try reader.push(Data((yaml + "\n").utf8))
        out.append(contentsOf: try reader.finish())
        XCTAssertEqual(out, expected)
    }

    func testMatchesStringSequenceReader() throws {
        let byteReader = YAMLByteSequenceReader<Row>()
        var streamed = try byteReader.push(Data(yaml.utf8))
        streamed.append(contentsOf: try byteReader.finish())

        let whole = try YAMLDecoder().decode([Row].self, from: yaml)
        XCTAssertEqual(streamed, whole)
    }

    func testNonSequenceThrows() throws {
        let reader = YAMLByteSequenceReader<Row>()
        XCTAssertThrowsError(try reader.push(Data("hu: not-a-sequence\npos: noun\n".utf8)))
    }
}
