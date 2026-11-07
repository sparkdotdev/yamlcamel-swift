import Foundation
import Testing
@testable import YAMLCamel

/// Walks every file in `Corpus` and holds each one to the same contract.
///
/// The corpus accumulates: every crash, hang or wrong round trip found in development becomes a file
/// there, so a later change cannot quietly bring it back. A file starts with a `#!` note saying what
/// it is, then a `#!---` line, then the input.
@Suite("Corpus")
struct CorpusTests {

    struct Case {
        let name: String
        let note: String
        let text: String
    }

    /// Reads the corpus as raw bytes, because some cases are not valid UTF-8 on purpose.
    static func load() throws -> [Case] {
        guard let root = Bundle.module.resourceURL?.appendingPathComponent("Corpus"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            Issue.record("Corpus directory is missing from the test bundle.")
            return []
        }
        var cases: [Case] = []
        for name in names.sorted() where name.hasSuffix(".yaml") {
            let data = try Data(contentsOf: root.appendingPathComponent(name))
            let whole = String(decoding: data, as: UTF8.self)
            guard let separator = whole.range(of: "#!---\n") else {
                Issue.record("\(name) has no '#!---' separator.")
                continue
            }
            let header = String(whole[whole.startIndex ..< separator.lowerBound])
            let note = header
                .split(separator: "\n")
                .compactMap { $0.hasPrefix("#! ") ? String($0.dropFirst(3)) : nil }
                .joined(separator: " ")
            if note.isEmpty { Issue.record("\(name) has no note saying what it is.") }
            cases.append(Case(name: String(name.dropLast(5)),
                              note: note,
                              text: String(whole[separator.upperBound...])))
        }
        return cases
    }

    @Test("every corpus case parses to a value or a YAMLParseError, and nothing else")
    func everyCaseEndsCleanly() throws {
        let cases = try Self.load()
        #expect(cases.count > 20, "the corpus should not have shrunk")
        for item in cases {
            do {
                _ = try YAMLParser.parseStream(item.text)
            } catch is YAMLParseError {
                continue
            } catch {
                Issue.record("\(item.name) threw \(type(of: error)) rather than a YAMLParseError: \(error)")
            }
        }
    }

    @Test("every corpus case behaves the same way twice")
    func everyCaseIsDeterministic() throws {
        for item in try Self.load() {
            let first = Result { try YAMLParser.parseStream(item.text) }
            let second = Result { try YAMLParser.parseStream(item.text) }
            switch (first, second) {
            case (.success(let a), .success(let b)):
                // Compared as text, since a document holding a NaN is never equal to itself.
                #expect(try a.map { try YAML.emit($0) } == b.map { try YAML.emit($0) },
                        "\(item.name) parsed differently on the second run")
            case (.failure(let a as YAMLParseError), .failure(let b as YAMLParseError)):
                #expect(a == b, "\(item.name) failed differently on the second run")
            default:
                Issue.record("\(item.name) succeeded once and failed once")
            }
        }
    }

    @Test("a corpus case that parses survives being emitted and parsed again")
    func everyCaseThatParsesRoundTrips() throws {
        for item in try Self.load() {
            guard let docs = try? YAMLParser.parseStream(item.text) else { continue }
            for doc in docs {
                let emitted = try YAML.emit(doc)
                do {
                    // Compared as text, since a document holding a NaN is never equal to itself,
                    // and on permissive limits, since an aliased document can emit past the input
                    // bound it parsed under.
                    let back = try YAMLParser.parse(emitted, limits: .permissive)
                    #expect(try YAML.emit(back) == emitted,
                            "\(item.name) changed value through emit and parse")
                } catch {
                    Issue.record("\(item.name) emitted text that does not parse: \(error)")
                }
            }
        }
    }

    @Test("the cases named as limit refusals are refused on the default limits")
    func limitCasesAreRefused() throws {
        let expected: [String: YAMLParseError.Kind] = [
            "nested-flow-1000": .depthExceeded,
            "nested-flow-2000": .depthExceeded,
            "nested-flow-32000": .depthExceeded,
            "nested-flow-mappings": .depthExceeded,
            "nested-block-sequences": .depthExceeded,
            "alternating-sequence-mapping": .depthExceeded,
            "billion-laughs": .tooManyNodes,
            "alias-bomb-once-per-document": .tooManyNodes,
            "alias-bomb-once-per-sequence-item": .tooManyNodes,
            "many-documents": .tooManyDocuments,
            "alias-to-undefined-anchor": .undefinedAlias,
            "alias-across-documents": .undefinedAlias,
            "self-referential-alias": .undefinedAlias,
            "duplicate-key-block": .duplicateKey,
            "duplicate-key-flow": .duplicateKey,
            "deep-alias-chain": .depthExceeded,
        ]
        let byName = Dictionary(uniqueKeysWithValues: try Self.load().map { ($0.name, $0) })
        for (name, kind) in expected {
            guard let item = byName[name] else {
                Issue.record("corpus case \(name) is missing")
                continue
            }
            let error = #expect(throws: YAMLParseError.self) { try YAMLParser.parseStream(item.text) }
            #expect(error?.kind == kind, "\(name) refused with \(String(describing: error?.kind))")
        }
    }

    @Test("the cases named as syntax errors are reported as syntax errors")
    func syntaxCasesAreReported() throws {
        let names = ["unterminated-flow-sequence", "unterminated-flow-mapping",
                     "unterminated-double-quote", "unterminated-single-quote",
                     "truncated-after-directive", "stray-backslash-at-end",
                     "over-indented-continuation", "content-after-document",
                     "collection-as-key", "leading-empty-line-over-indented",
                     "lone-surrogate-escape"]
        let byName = Dictionary(uniqueKeysWithValues: try Self.load().map { ($0.name, $0) })
        for name in names {
            guard let item = byName[name] else {
                Issue.record("corpus case \(name) is missing")
                continue
            }
            let error = #expect(throws: YAMLParseError.self) { try YAMLParser.parseStream(item.text) }
            #expect(error?.kind == .syntax, "\(name) reported \(String(describing: error?.kind))")
        }
    }

    @Test("the block scalar cases read their content rather than their own header")
    func blockScalarHeadersAreNotContent() throws {
        let byName = Dictionary(uniqueKeysWithValues: try Self.load().map { ($0.name, $0) })
        #expect(try YAMLParser.parse(byName["block-scalar-as-sequence-item"]!.text)
                == .array([.string("hello\n")]))
        #expect(try YAMLParser.parse(byName["block-scalar-at-document-root"]!.text)
                == .string("hello\n"))
    }

    @Test("a byte order mark inside a scalar survives a round trip")
    func byteOrderMarkSurvives() throws {
        let byName = Dictionary(uniqueKeysWithValues: try Self.load().map { ($0.name, $0) })
        for name in ["bom-in-quoted-scalar", "bom-as-mapping-key", "bom-mid-key", "bom-starts-a-folded-line"] {
            let value = try YAMLParser.parse(byName[name]!.text)
            #expect(try YAMLParser.parse(YAML.emit(value)) == value, "\(name) lost its mark")
        }
    }

    @Test("a byte order mark starting a folded continuation line is content, not a later document's prefix")
    func byteOrderMarkOnAFoldedLineIsContent() throws {
        // Stripping a mark wherever a line happens to start with one, rather than only where a
        // document itself may start, would fold this into "hello world" and silently drop it.
        let byName = Dictionary(uniqueKeysWithValues: try Self.load().map { ($0.name, $0) })
        let value = try YAMLParser.parse(byName["bom-starts-a-folded-line"]!.text)
        #expect(value == .string("hello \u{FEFF}world"))
    }

    @Test("a byte order mark opening a later document is stripped like the first one's is")
    func byteOrderMarkOpensLaterDocumentsToo() throws {
        let byName = Dictionary(uniqueKeysWithValues: try Self.load().map { ($0.name, $0) })
        let docs = try YAMLParser.parseStream(byName["bom-opens-a-later-document"]!.text)
        #expect(docs == [.object([.init(key: "a", value: .int(1))]),
                        .object([.init(key: "b", value: .int(2))])])
    }

    @Test("a byte order mark before a later document in the stream is stripped like the first one's")
    func byteOrderMarkStripsBeforeEveryDocument() throws {
        let byName = Dictionary(uniqueKeysWithValues: try Self.load().map { ($0.name, $0) })
        let docs = try YAMLParser.parseStream(byName["bom-before-second-document"]!.text)
        #expect(docs == [.object([.init(key: "a", value: .int(1))]),
                         .object([.init(key: "b", value: .int(2))])])
    }
}
