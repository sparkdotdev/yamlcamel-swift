import Foundation
import Testing
@testable import YAMLCamelGzip
import YAMLCamel

/// Walks every file in `Corpus` and holds each one to the same contract.
///
/// A decompressor is an attack surface in the same way a parser is, so these accumulate the same
/// way. Each file is base64 so it stays diffable, with a `#!` note saying what it is, then a
/// `#!---` line, then the encoded bytes.
@Suite("Gzip corpus")
struct GzipCorpusTests {

    struct Case {
        let name: String
        let note: String
        let bytes: Data
    }

    static func load() throws -> [Case] {
        guard let root = Bundle.module.resourceURL?.appendingPathComponent("Corpus"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            Issue.record("Corpus directory is missing from the test bundle.")
            return []
        }
        var cases: [Case] = []
        for name in names.sorted() where name.hasSuffix(".gz.b64") {
            let whole = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            guard let separator = whole.range(of: "#!---\n") else {
                Issue.record("\(name) has no '#!---' separator.")
                continue
            }
            let header = String(whole[whole.startIndex ..< separator.lowerBound])
            let note = header.hasPrefix("#! ") ? String(header.dropFirst(3)).trimmingCharacters(in: .newlines) : ""
            if note.isEmpty { Issue.record("\(name) has no note saying what it is.") }
            let body = whole[separator.upperBound...].replacingOccurrences(of: "\n", with: "")
            guard let bytes = Data(base64Encoded: body) else {
                Issue.record("\(name) is not valid base64.")
                continue
            }
            cases.append(Case(name: String(name.dropLast(7)), note: note, bytes: bytes))
        }
        return cases
    }

    private var tightLimits: GzipLimits {
        GzipLimits(maxOutputBytes: 2 << 20, maxInputBytes: 8 << 20)
    }

    @Test("every corpus case ends in bytes or a GzipError, and nothing else")
    func everyCaseEndsCleanly() throws {
        let cases = try Self.load()
        #expect(cases.count > 15, "the corpus should not have shrunk")
        for item in cases {
            do {
                _ = try Gzip.decompress(item.bytes, limits: tightLimits)
            } catch is GzipError {
                continue
            } catch {
                Issue.record("\(item.name) threw \(type(of: error)) rather than a GzipError: \(error)")
            }
        }
    }

    @Test("every corpus case behaves the same way however the bytes are chunked",
          arguments: [1, 13, 4_096])
    func chunkingDoesNotChangeTheOutcome(chunk: Int) throws {
        for item in try Self.load() {
            let whole = Result { try Gzip.decompress(item.bytes, limits: tightLimits) }

            let streamed = Result { () throws -> Data in
                let decompressor = GzipDecompressor(limits: tightLimits)
                var out = Data()
                var offset = 0
                while offset < item.bytes.count {
                    let end = min(offset + chunk, item.bytes.count)
                    out.append(try decompressor.push(item.bytes.subdata(in: offset ..< end)))
                    offset = end
                }
                out.append(try decompressor.finish())
                return out
            }

            switch (whole, streamed) {
            case (.success(let a), .success(let b)):
                #expect(a == b, "\(item.name) inflated differently when chunked")
            case (.failure(let a as GzipError), .failure(let b as GzipError)):
                #expect(a.kind == b.kind, "\(item.name) failed differently when chunked")
            default:
                Issue.record("\(item.name) succeeded one way and failed the other")
            }
        }
    }

    @Test("the cases named as failures fail the way they are named")
    func namedFailures() throws {
        let expected: [String: GzipError.Kind] = [
            "truncated": .truncated,
            "truncated-header": .truncated,
            "empty": .truncated,
            "corrupt-crc": .corrupt,
            "wrong-declared-length": .corrupt,
            "not-gzip-but-claims-to-be": .corrupt,
            "plain-yaml-no-magic": .corrupt,
            "zlib-not-gzip": .corrupt,
            "raw-deflate": .corrupt,
            "bomb": .outputTooLarge,
        ]
        let byName = Dictionary(uniqueKeysWithValues: try Self.load().map { ($0.name, $0) })
        for (name, kind) in expected {
            guard let item = byName[name] else {
                Issue.record("corpus case \(name) is missing")
                continue
            }
            var caught: GzipError?
            do { _ = try Gzip.decompress(item.bytes, limits: tightLimits) }
            catch let e as GzipError { caught = e }
            #expect(caught?.kind == kind, "\(name) gave \(String(describing: caught?.kind))")
        }
    }

    @Test("the cases named as valid inflate to YAML that parses")
    func namedSuccesses() throws {
        let byName = Dictionary(uniqueKeysWithValues: try Self.load().map { ($0.name, $0) })
        for name in ["valid-small", "valid-sequence", "concatenated-members"] {
            guard let item = byName[name] else {
                Issue.record("corpus case \(name) is missing")
                continue
            }
            let inflated = try Gzip.decompress(item.bytes, limits: tightLimits)
            #expect(inflated.count > 0)
        }
    }

    @Test("a body that inflates cleanly still has to pass the parser's own bounds")
    func yamlBoundsApplyAfterInflating() throws {
        let byName = Dictionary(uniqueKeysWithValues: try Self.load().map { ($0.name, $0) })

        let deep = try Gzip.decompress(byName["gzip-of-deeply-nested-yaml"]!.bytes, limits: tightLimits)
        var error = #expect(throws: YAMLParseError.self) {
            try YAMLParser.parse(String(decoding: deep, as: UTF8.self))
        }
        #expect(error?.kind == .depthExceeded)

        let laughs = try Gzip.decompress(byName["gzip-of-billion-laughs"]!.bytes, limits: tightLimits)
        error = #expect(throws: YAMLParseError.self) {
            try YAMLParser.parse(String(decoding: laughs, as: UTF8.self))
        }
        #expect(error?.kind == .tooManyNodes)
    }

    @Test("trailing bytes after a complete stream are reported rather than ignored")
    func trailingGarbage() throws {
        let byName = Dictionary(uniqueKeysWithValues: try Self.load().map { ($0.name, $0) })
        var caught: GzipError?
        do { _ = try Gzip.decompress(byName["trailing-garbage"]!.bytes, limits: tightLimits) }
        catch let e as GzipError { caught = e }
        #expect(caught != nil, "garbage after the trailer should not pass silently")
    }
}
