import Foundation

// MARK: - Streaming decode of a top-level YAML sequence

/// Decodes the elements of a top-level YAML block sequence one at a time, so a large document never
/// becomes one giant tree or one giant `[Element]` array.
///
/// A line scan up front finds the item boundaries and gives `count` for progress reporting, then
/// each `next()` parses and decodes a single item. Peak memory is one item's subtree plus whatever
/// the caller retains.
public final class YAMLSequenceReader<Element: Decodable> {

    private let text: String            // original BOM positions retained, line breaks normalised
    private let starts: [String.Index]  // where each top-level item begins
    private let scanEnd: String.Index   // where the scan stopped, a real document end or the end of the text
    private let limits: YAMLLimits
    // One budget for the whole stream, for the reason `YAMLByteSequenceReader` keeps one.
    private let budget = YAMLBudget()
    private var cursor = 0

    /// Total number of top-level items, usable as a progress denominator.
    public let count: Int

    /// Number of items already returned by `next()`.
    public var consumed: Int { cursor }

    /// Advances past the next `n` items without parsing them, for resuming an interrupted ingest.
    /// Pass the number already consumed. Clamped to the item count.
    public func skip(_ n: Int) {
        cursor = Swift.min(cursor + Swift.max(0, n), starts.count)
    }

    fileprivate init(text input: String, limits: YAMLLimits) throws {
        guard input.utf8.count <= limits.maxInputBytes else {
            throw YAMLParseError("Input is \(input.utf8.count) bytes, over the \(limits.maxInputBytes) byte limit.",
                                 kind: .inputTooLarge)
        }
        self.limits = limits
        // CR and CRLF normalise to LF everywhere they are content, the same as the parser does, so a
        // CRLF document splits at the same lines a CR-normalised one would. `\r\n` is one Swift
        // `Character`, so splitting on `"\n"` the way this used to never found the break at all.
        let text = YAMLSequenceReader.normalizingLineBreaks(input)

        // The scan walks a line at a time and keeps only where the items begin. Holding every line
        // as a `Substring` the way this used to cost far more than the text itself: a line is 32
        // bytes of array whatever it holds, so a document of short lines came out tens of times
        // larger in memory than on the wire, and it was paid even for input the scan then refused.
        var starts: [String.Index] = []
        var baseIndent: Int? = nil
        var state = YAMLLineState()
        var scanEnd = text.endIndex

        var lineStart = text.startIndex
        var lineNumber = 0
        var lastLine = false
        while !lastLine {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let raw = text[lineStart ..< lineEnd]
            let thisStart = lineStart
            let thisLine = lineNumber
            // Advancing before the body runs is what lets the checks below carry on to the next line
            // with a plain `continue`.
            if lineEnd == text.endIndex {
                lastLine = true
            } else {
                lineStart = text.index(after: lineEnd)
                lineNumber += 1
            }

            // The parser reaches a line's content by skipping blanks one character at a time and
            // counting every one of them towards the column, tab included, rather than measuring
            // indentation in spaces alone. A line whose lead mixes a tab in with its spaces still
            // has to compare equal to one that is all spaces, the same number of characters deep.
            var indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
            var content = raw.dropFirst(indent)
            // Scan past a prefix BOM before measuring indentation, but retain it in text so each
            // item is parsed at its original positions. A mark after indentation is never framing.
            if !state.isContinuation(indent: indent, isBlank: content.isEmpty), raw.first == "\u{FEFF}" {
                let afterBOM = raw.dropFirst()
                indent = afterBOM.prefix(while: { $0 == " " || $0 == "\t" }).count
                content = afterBOM.dropFirst(indent)
            }

            // A line inside a quoted scalar, a flow collection or a block scalar belongs to the item
            // already in progress, however much it looks like the start of a new one.
            if state.isContinuation(indent: indent, isBlank: content.isEmpty) {
                state.feed(content: content.utf8, indent: indent)
                continue
            }
            // A document marker only counts at column zero; indented, it is content, same as the
            // parser treats it. Three dashes or dots alone, or followed by a space or a tab, are the
            // marker; anything else glued onto them is a plain scalar that only starts the same way.
            // Framing must not enter scalar state: an indented first item would otherwise look
            // like a continuation of the marker rather than the start of the sequence.
            if indent == 0, content == "---" || content.hasPrefix("--- ") || content.hasPrefix("---\t") {
                if baseIndent == nil {
                    try YAMLParser.validateSequenceDocumentStart(String(content), limits: limits)
                }
                continue
            }
            if indent == 0, content == "..." || content.hasPrefix("... ") || content.hasPrefix("...\t") {
                try YAMLDocumentEndSuffix.validate(content.utf8, line: thisLine + 1)
                scanEnd = thisStart
                break
            }
            state.feed(content: content.utf8, indent: indent)
            if content.isEmpty || content.first == "#" { continue }

            let isSequenceItem = content == "-" || content.hasPrefix("- ") || content.hasPrefix("-\t")
            if baseIndent == nil {
                guard isSequenceItem else {
                    throw YAMLParseError("Top-level YAML is not a block sequence; streaming decode needs a sequence.",
                                         line: thisLine + 1)
                }
                baseIndent = indent
            }
            if isSequenceItem && indent == baseIndent {
                starts.append(thisStart)
            }
        }

        self.text = text
        self.starts = starts
        self.scanEnd = scanEnd
        self.count = starts.count
    }

    /// Replaces every CRLF and lone CR with an LF. Walks unicode scalars rather than `Character`s,
    /// since `\r\n` is a single `Character` and a byte-by-byte view is what a line break actually is.
    private static func normalizingLineBreaks(_ text: String) -> String {
        // `String.contains` compares whole `Character`s, and `\r\n` is one `Character`, so it never
        // finds a lone `\r` this way; the UTF-8 view has no such notion and just sees the byte.
        guard text.utf8.contains(0x0D) else { return text }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        var iterator = text.unicodeScalars.makeIterator()
        var pending = iterator.next()
        while let scalar = pending {
            if scalar == "\r" {
                out.append("\n")
                let next = iterator.next()
                pending = next == "\n" ? iterator.next() : next
            } else {
                out.append(scalar)
                pending = iterator.next()
            }
        }
        return String(out)
    }

    /// Decodes and returns the next element, or nil once the sequence is exhausted. Throws on a
    /// malformed item, matching whole-array decode where one bad entry fails the call.
    public func next() throws -> Element? {
        guard cursor < starts.count else { return nil }
        let start = starts[cursor]
        let end = cursor + 1 < starts.count ? starts[cursor + 1] : scanEnd
        cursor += 1

        let chunk = String(text[start ..< end])
        let node = try YAMLParser.parse(chunk, limits: limits, budget: budget)
        guard case .array(let items) = node, let element = items.first else {
            throw YAMLParseError("Streaming item did not parse as a sequence element.",
                                 line: lineNumber(of: start))
        }
        return try YAMLDecoder.decodeValue(Element.self, from: element)
    }

    /// Counts the lines ahead of an item, for the one error that names one. Kept off the scan so
    /// the item table stays one index per item rather than an index and a number.
    private func lineNumber(of index: String.Index) -> Int {
        var line = 1
        for character in text[text.startIndex ..< index] where character == "\n" { line += 1 }
        return line
    }
}

// MARK: - YAMLDecoder streaming / async surface

public extension YAMLDecoder {

    /// A synchronous streaming reader over a top-level YAML sequence. Pass the element type and the
    /// document text, then pull a batch at a time to bound memory.
    func sequenceReader<Element: Decodable>(_ type: Element.Type, from string: String) throws -> YAMLSequenceReader<Element> {
        try YAMLSequenceReader<Element>(text: string, limits: limits)
    }

    /// An `AsyncThrowingStream` of decoded elements from a top-level YAML sequence, decoded one per
    /// demand so back-pressure is preserved. Pass a `Sendable` element type; `sequenceReader` carries
    /// no such requirement.
    func decodeSequence<Element: Decodable & Sendable>(
        _ type: Element.Type, from string: String
    ) -> AsyncThrowingStream<Element, Error> {
        // The box is only touched inside the unfolding closure, which the stream invokes serially.
        let box = YAMLSequenceBox<Element>(string, limits: limits)
        return AsyncThrowingStream(unfolding: {
            if let error = box.pendingError { box.pendingError = nil; throw error }
            return try box.reader?.next()
        })
    }

    /// Decodes on a detached utility task so a large document never blocks the caller. Pass a
    /// `Sendable` result type so it can cross the task boundary.
    func decode<T: Decodable & Sendable>(_ type: T.Type, from string: String) async throws -> T {
        let limits = self.limits
        return try await Task.detached(priority: .utility) {
            try YAMLDecoder(limits: limits).decode(type, from: string)
        }.value
    }

    /// UTF-8 `Data` overload of the detached `decode`.
    func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) async throws -> T {
        let limits = self.limits
        return try await Task.detached(priority: .utility) {
            try YAMLDecoder(limits: limits).decode(type, from: data)
        }.value
    }
}

/// Holds a reader so `decodeSequence`'s unfolding closure can capture it. Access is serial because
/// the stream invokes that closure serially.
private final class YAMLSequenceBox<Element: Decodable & Sendable>: @unchecked Sendable {
    var reader: YAMLSequenceReader<Element>?
    var pendingError: Error?
    init(_ string: String, limits: YAMLLimits) {
        do { reader = try YAMLSequenceReader<Element>(text: string, limits: limits) }
        catch { pendingError = error }
    }
}
