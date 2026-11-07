import Foundation

/// A byte-fed streaming decoder for a top-level YAML block sequence. Push byte chunks as they
/// arrive and it emits decoded elements as each item completes, so neither the full text nor a full
/// `[Element]` array is ever held.
///
/// Item boundaries are found in raw bytes, which UTF-8 makes safe because neither 0x0A nor 0x0D ever
/// appears inside a multi-byte code unit. Only a completed item's bytes are decoded as text.
public final class YAMLByteSequenceReader<Element: Decodable> {
    private var lineBuffer: [UInt8] = []      // bytes of the current, unterminated line
    private var itemBuffer: [UInt8] = []      // complete lines accumulated for the item in progress
    private var baseIndent: Int? = nil        // indent of the top-level items, set on the first one
    private var skipRemaining = 0
    private let limits: YAMLLimits
    // One budget for the whole stream. Each item is its own parse, so a budget created per parse
    // would bound an item rather than the stream, and a small alias bomb repeated once per item
    // would cost the full ceiling as many times as the stream held items.
    private let budget = YAMLBudget()
    private var bytesSeen = 0
    private var state = YAMLLineState()
    private var stopped = false               // a real document-end marker was seen; nothing after it counts
    private var pendingCR = false              // the last byte handled was a CR; a push boundary can fall between it and a following LF

    /// Number of items emitted so far. Skipped items count as emitted.
    public private(set) var emitted = 0

    /// Creates a reader. Pass your own limits to tighten or loosen what the parser accepts.
    public init(limits: YAMLLimits = .default) {
        self.limits = limits
    }

    /// Skip the next `n` items without decoding them, for resuming an interrupted ingest. Boundaries
    /// are still scanned, so `emitted` still counts them.
    public func skip(_ n: Int) { skipRemaining += max(0, n) }

    /// Feeds a chunk of bytes and returns any elements this chunk completed.
    public func push(_ bytes: [UInt8]) throws -> [Element] {
        bytesSeen += bytes.count
        guard bytesSeen <= limits.maxInputBytes else {
            throw YAMLParseError("Stream is over the \(limits.maxInputBytes) byte limit.",
                                 kind: .inputTooLarge)
        }
        return try scan(bytes)
    }

    /// `Data` convenience for `push(_:)`.
    public func push(_ data: Data) throws -> [Element] { try push([UInt8](data)) }

    /// Signals end of input and flushes the final partial line and the last buffered item.
    public func finish() throws -> [Element] {
        var out: [Element] = []
        if !lineBuffer.isEmpty {
            if lineBuffer.last == 0x0D { lineBuffer.removeLast() }
            if let e = try handleLine(lineBuffer, endedWithBreak: false) { out.append(e) }
            lineBuffer.removeAll(keepingCapacity: true)
        }
        if let e = try flushItem() { out.append(e) }
        return out
    }

    /// Splits bytes into lines and feeds each complete one to `handleLine`. A push boundary can fall
    /// anywhere, including inside what would otherwise be a byte order mark, but `lineBuffer` already
    /// holds a complete line by the time `handleLine` sees it regardless of how many pushes built it,
    /// so a mark spanning a boundary is resolved there rather than needing its own buffering here.
    private func scan(_ bytes: [UInt8]) throws -> [Element] {
        var out: [Element] = []
        var start = bytes.startIndex
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let byte = bytes[i]
            if pendingCR {
                pendingCR = false
                if byte == 0x0A {
                    // The CR already ended a line; this LF is just the rest of the same CRLF pair.
                    start = i + 1
                    i += 1
                    continue
                }
            }
            if byte == 0x0A || byte == 0x0D {           // a line is complete
                lineBuffer.append(contentsOf: bytes[start..<i])
                if let e = try handleLine(lineBuffer, endedWithBreak: true) { out.append(e) }
                lineBuffer.removeAll(keepingCapacity: true)
                start = i + 1
                if byte == 0x0D { pendingCR = true }    // could be a lone CR, or the first half of a CRLF
            }
            i += 1
        }
        if start < bytes.endIndex { lineBuffer.append(contentsOf: bytes[start...]) }
        return out
    }

    // MARK: - line handling

    /// Feeds one complete line into the item accumulator and emits the previous item when this line
    /// opens a new top-level entry. Actual CR/LF breaks normalize to LF; an unterminated
    /// final line keeps its absence of a break so block scalar chomping is unchanged.
    private func handleLine(_ rawLine: [UInt8], endedWithBreak: Bool) throws -> Element? {
        guard !stopped else { return nil }

        // The parser reaches a line's content by skipping blanks one character at a time and counting
        // every one of them towards the column, tab included, rather than measuring indentation in
        // spaces alone. A line whose lead mixes a tab in with its spaces still has to compare equal
        // to one that is all spaces, the same number of characters deep.
        var indent = rawLine.prefix(while: { $0 == 0x20 || $0 == 0x09 }).count
        var content = Array(rawLine[indent...])

        // Only a raw column-zero BOM can be a prefix. Remove it for boundary scanning, then measure
        // the indentation after it. A BOM after indentation or inside an open scalar is content.
        if !state.isContinuation(indent: indent, isBlank: content.isEmpty),
           rawLine.starts(with: [0xEF, 0xBB, 0xBF]) {
            let afterBOM = rawLine.dropFirst(3)
            indent = afterBOM.prefix(while: { $0 == 0x20 || $0 == 0x09 }).count
            content = Array(afterBOM.dropFirst(indent))
        }
        let continuation = state.isContinuation(indent: indent, isBlank: content.isEmpty)
        // The item parser must still see the BOM's original position: erasing a raw-column-zero
        // prefix can turn an invalid dedent into valid indented scalar content.
        let line = rawLine

        // Validate root properties or refuse inline scalar content before discarding the framing.
        if baseIndent == nil, !continuation, indent == 0, isDocStart(content) {
            guard let prefix = String(bytes: content, encoding: .utf8) else {
                throw YAMLParseError("Input is not valid UTF-8.", kind: .syntax)
            }
            try YAMLParser.validateSequenceDocumentStart(prefix, limits: limits)
            return nil
        }
        state.feed(content: content, indent: indent)
        if continuation, baseIndent != nil {
            itemBuffer.append(contentsOf: line)
            if endedWithBreak { itemBuffer.append(0x0A) }
            return nil
        }

        if baseIndent == nil {
            // Nothing started yet; leading markers were handled before feeding scalar state.
            if content.isEmpty || content.first == 0x23 { return nil }
            guard isSequenceItem(content) else {
                throw YAMLParseError("Top-level YAML is not a block sequence; streaming decode needs a sequence.")
            }
            baseIndent = indent
            itemBuffer = line
            if endedWithBreak { itemBuffer.append(0x0A) }
            return nil
        }

        if !continuation, indent == 0, isDocEnd(content) {
            try YAMLDocumentEndSuffix.validate(content)
            stopped = true
            return try flushItem()
        }

        if !continuation, indent == baseIndent, isSequenceItem(content), !itemBuffer.isEmpty {
            // This line starts a new item, so the accumulated buffer is a complete previous one.
            let element = try flushItem()
            itemBuffer = line
            if endedWithBreak { itemBuffer.append(0x0A) }
            return element
        }

        // Continuation of the current item.
        itemBuffer.append(contentsOf: line)
        if endedWithBreak { itemBuffer.append(0x0A) }
        return nil
    }

    /// Parses and decodes the accumulated item, or discards it while skipping, then clears the buffer.
    private func flushItem() throws -> Element? {
        guard !itemBuffer.isEmpty else { return nil }
        let bytes = itemBuffer
        itemBuffer.removeAll(keepingCapacity: true)
        emitted += 1
        if skipRemaining > 0 { skipRemaining -= 1; return nil }   // skipped items are never parsed

        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw YAMLParseError("Input is not valid UTF-8.", kind: .syntax)
        }
        let node = try YAMLParser.parse(text, limits: limits, budget: budget)
        guard case .array(let items) = node, let element = items.first else {
            throw YAMLParseError("Streaming item did not parse as a sequence element.")
        }
        return try YAMLDecoder.decodeValue(Element.self, from: element)
    }

    // MARK: - byte predicates

    private func isSequenceItem(_ content: [UInt8]) -> Bool {
        guard content.first == 0x2D else { return false }
        if content.count == 1 { return true }
        return content[1] == 0x20 || content[1] == 0x09
    }

    private func isDocStart(_ content: [UInt8]) -> Bool {
        isMarker(content, byte: 0x2D)   // '-'
    }

    private func isDocEnd(_ content: [UInt8]) -> Bool {
        isMarker(content, byte: 0x2E)   // '.'
    }

    /// True when `content` is three of the given byte, alone or followed by a blank, which is what
    /// makes '---' or '...' a marker rather than the start of a plain scalar that reads the same way.
    private func isMarker(_ content: [UInt8], byte: UInt8) -> Bool {
        guard content.count >= 3, content[0] == byte, content[1] == byte, content[2] == byte else { return false }
        guard content.count > 3 else { return true }
        return content[3] == 0x20 || content[3] == 0x09
    }
}
