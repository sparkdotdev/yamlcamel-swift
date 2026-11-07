import Foundation
import Testing
@testable import YAMLCamelGzip
import YAMLCamel

private struct Row: Codable, Equatable {
    var name: String
    var value: Int
}

@Suite("YAML over gzip")
struct YAMLGzipTests {

    private var rows: [Row] { (0 ..< 500).map { Row(name: "row \($0)", value: $0) } }

    private func sequenceYAML() -> String {
        rows.map { "- name: \($0.name)\n  value: \($0.value)\n" }.joined()
    }

    @Test("a Codable value survives an encode, a compress, a decompress and a decode")
    func codableRoundTrip() throws {
        let compressed = try YAMLEncoder().encodeGzipped(rows)
        #expect(Gzip.hasGzipMagic(compressed))
        #expect(try YAMLDecoder().decode([Row].self, fromGzipped: compressed) == rows)
    }

    @Test("the streaming reader decodes a gzipped sequence a chunk at a time",
          arguments: [1, 17, 1_024, 65_536])
    func streamingReader(chunk: Int) throws {
        let compressed = try Gzip.compress(Data(sequenceYAML().utf8))
        let reader = GzipYAMLSequenceReader<Row>()
        var out: [Row] = []
        var offset = 0
        while offset < compressed.count {
            let end = min(offset + chunk, compressed.count)
            out += try reader.push(compressed.subdata(in: offset ..< end))
            offset = end
        }
        out += try reader.finish()
        #expect(out == rows)
        #expect(reader.emitted == rows.count)
    }

    @Test("the streaming reader gives elements back before the body ends")
    func streamingReaderIsIncremental() throws {
        let compressed = try Gzip.compress(Data(sequenceYAML().utf8))
        let reader = GzipYAMLSequenceReader<Row>()
        let half = compressed.prefix(compressed.count * 3 / 4)
        let early = try reader.push(Data(half))
        #expect(early.count > 0, "elements should arrive before the last chunk does")
        #expect(early.count < rows.count)
    }

    @Test("the streaming reader can skip items an earlier run already handled")
    func streamingReaderSkips() throws {
        let compressed = try Gzip.compress(Data(sequenceYAML().utf8))
        let reader = GzipYAMLSequenceReader<Row>()
        reader.skip(100)
        var out = try reader.push(compressed)
        out += try reader.finish()
        #expect(out.count == rows.count - 100)
        #expect(out.first == rows[100])
    }

    @Test("the gzip bound applies to a streaming YAML read as well")
    func streamingReaderHonoursGzipBound() throws {
        let compressed = try Gzip.compress(Data(String(repeating: "- name: x\n  value: 1\n", count: 200_000).utf8))
        let reader = GzipYAMLSequenceReader<Row>(gzipLimits: GzipLimits(maxOutputBytes: 50_000))
        var caught: GzipError?
        do {
            _ = try reader.push(compressed)
            _ = try reader.finish()
        } catch let e as GzipError {
            caught = e
        }
        #expect(caught?.kind == .outputTooLarge)
    }

    @Test("the YAML bound applies to a streaming read after inflating")
    func streamingReaderHonoursYAMLBound() throws {
        let text = "- name: x\n  value: 1\n" + "- name: " + String(repeating: "y", count: 100_000) + "\n  value: 2\n"
        let compressed = try Gzip.compress(Data(text.utf8))
        let reader = GzipYAMLSequenceReader<Row>(yamlLimits: YAMLLimits(maxScalarLength: 1_000))
        var caught: YAMLParseError?
        do {
            _ = try reader.push(compressed)
            _ = try reader.finish()
        } catch let e as YAMLParseError {
            caught = e
        }
        #expect(caught?.kind == .scalarTooLong)
    }

    @Test("a truncated gzipped body is reported rather than treated as a short list")
    func truncatedBody() throws {
        let compressed = try Gzip.compress(Data(sequenceYAML().utf8))
        let reader = GzipYAMLSequenceReader<Row>()
        _ = try reader.push(Data(compressed.prefix(compressed.count / 2)))
        var caught: GzipError?
        do { _ = try reader.finish() } catch let e as GzipError { caught = e }
        #expect(caught?.kind == .truncated)
    }

    @Test("a body that is not gzip is reported as corrupt rather than parsed as YAML")
    func plainBodySentAsGzip() throws {
        let reader = GzipYAMLSequenceReader<Row>()
        var caught: GzipError?
        do { _ = try reader.push(Data(sequenceYAML().utf8)) } catch let e as GzipError { caught = e }
        #expect(caught?.kind == .corrupt)
    }

    @Test("compressing YAML is worth doing")
    func compressionRatio() throws {
        let text = Data(sequenceYAML().utf8)
        let compressed = try Gzip.compress(text)
        #expect(compressed.count < text.count / 3)
    }
    @Test("streaming block scalars preserve the absence of an EOF line break")
    func streamingBlockScalarEOF() throws {
        for style in ["|", "|+", "|-", ">", ">+", ">-"] {
            for tail in ["", "\n", "\n\n", "\n  "] {
                let text = "- first\n- " + style + "\n  literal EOF" + tail
                let expected = try YAMLDecoder().decode([String].self, from: text)
                let compressed = try Gzip.compress(Data(text.utf8))
                for chunk in [1, 2, 7, compressed.count] {
                    let reader = GzipYAMLSequenceReader<String>()
                    var values: [String] = []
                    var offset = 0
                    while offset < compressed.count {
                        let end = min(offset + chunk, compressed.count)
                        values += try reader.push(compressed.subdata(in: offset..<end))
                        offset = end
                    }
                    values += try reader.finish()
                    #expect(values == expected)
                }
            }
        }
    }

}
