import Foundation

/// Parses YAML 1.2.2 text into `YAMLValue`.
///
/// The reader below is recursive descent over unicode scalars, shaped to follow the spec's own
/// productions, so an indentation rule in the spec has one place here that implements it.
public enum YAMLParser {

    /// Parses a stream that holds exactly one document. Pass the text and optionally your own
    /// limits. Returns the document's value, or `.null` for an empty stream. Throws `YAMLParseError`,
    /// including kind `documentCount` when the stream holds more than one document.
    public static func parse(_ text: String, limits: YAMLLimits = .default) throws -> YAMLValue {
        let docs = try parseStream(text, limits: limits)
        if docs.isEmpty { return .null }
        guard docs.count == 1 else {
            throw YAMLParseError("Expected one document but the stream holds \(docs.count).",
                                 kind: .documentCount)
        }
        return docs[0]
    }

    /// Parses every document in a stream. Pass the text and optionally your own limits. Returns one
    /// value per document, in order. Throws `YAMLParseError`.
    public static func parseStream(_ text: String, limits: YAMLLimits = .default) throws -> [YAMLValue] {
        let reader = try Reader(text, limits: limits)
        return try reader.parseStream()
    }

    /// Parses one document against a budget the caller already holds, so several calls share one
    /// ceiling. The streaming readers use this, since each item they hand over is its own parse and
    /// a budget that started fresh each time would bound an item rather than the stream.
    static func parse(_ text: String, limits: YAMLLimits, budget: YAMLBudget) throws -> YAMLValue {
        let reader = try Reader(text, limits: limits, budget: budget)
        let docs = try reader.parseStream()
        if docs.isEmpty { return .null }
        guard docs.count == 1 else {
            throw YAMLParseError("Expected one document but the stream holds \(docs.count).",
                                 kind: .documentCount)
        }
        return docs[0]
    }

    /// Checks one document-start line without building its root or buffering the following items.
    /// Only properties may precede a block sequence on that line; inline values are different roots.
    static func validateSequenceDocumentStart(_ text: String, limits: YAMLLimits) throws {
        try Reader(text, limits: limits).validateSequenceDocumentStart()
    }
}

// MARK: - Shared budget

/// The totals a parse spends, held by reference so several parses can draw on one ceiling.
///
/// Every bound in `YAMLLimits` exists to cap the work one input can cause. A total that restarts at
/// a document boundary, or at each item a streaming reader hands over, bounds a piece of the input
/// rather than the whole of it, and an alias bomb small enough to fit inside one piece then
/// multiplies by however many pieces the input holds.
final class YAMLBudget {

    /// Nodes built so far, counting what every alias expanded into.
    var nodes = 0

    /// Aliases dereferenced so far.
    var aliases = 0

    /// Creates an empty budget.
    init() {}
}

// MARK: - Parse context

/// Which production family the reader is inside, which decides where a scalar ends.
enum YAMLContext {
    case blockIn, blockOut, blockKey, flowIn, flowOut, flowKey

    /// True only inside flow brackets, where `,`, `[`, `]`, `{` and `}` end a plain scalar.
    ///
    /// `flowOut` names a node written in block context, so it does not restrict those characters:
    /// a plain `a, b` after a block mapping key keeps its comma.
    var inFlowBrackets: Bool { self == .flowIn || self == .flowKey }

    /// True where an implicit key lives, so the scalar has to fit on one line. Only a block mapping
    /// key is restricted this way: a flow mapping key uses the same flow node grammar as any other
    /// flow scalar, so it folds across lines the same as a value does.
    var isSingleLine: Bool { self == .blockKey }
}

// MARK: - Reader

final class Reader {
    private let src: [Unicode.Scalar]
    private let limits: YAMLLimits

    private var i = 0
    private var line = 1
    private var col = 0

    private var depth = 0
    private let depthCeiling: Int
    private let budget: YAMLBudget

    private struct Anchor {
        let value: YAMLValue
        let nodes: Int
        let depth: Int
    }
    private var anchors: [String: Anchor] = [:]
    private var tagHandles: [String: String] = ["!": "!", "!!": "tag:yaml.org,2002:"]
    private var sawYAMLDirective = false

    /// The properties that may precede any node.
    private struct Properties {
        var anchor: String?
        var tag: String?
        var isEmpty: Bool { anchor == nil && tag == nil }
    }

    /// What kind of parent is asking for a value, which decides whether a collection may start on
    /// the same line and whether a sequence may sit at the parent's own indentation.
    private enum ParentKind {
        case mappingValue, sequenceItem, explicitKey, explicitValue, documentRoot

        /// True where the spec reaches a node through `s-l+block-indented`, which is what lets a
        /// collection start on the same line as the indicator that introduced it: a sequence entry's
        /// '-', or an explicit key's '?' or ':'. A plain mapping value and the document root both
        /// reach a node through `s-l+block-node` instead, where a mapping or sequence has to start on
        /// its own line.
        var allowsCompactCollection: Bool {
            switch self {
            case .sequenceItem, .explicitKey, .explicitValue: return true
            case .mappingValue, .documentRoot: return false
            }
        }

        /// True where a block sequence may sit at the same indentation as its parent, rather than
        /// more indented. The spec calls this out for a mapping's value, an explicit key and an
        /// explicit value; it does not extend to a sequence item, since a sequence nested directly in
        /// another sequence still needs the extra indentation to tell the two apart.
        var allowsZeroIndentSequence: Bool {
            switch self {
            case .mappingValue, .explicitKey, .explicitValue: return true
            case .sequenceItem, .documentRoot: return false
            }
        }
    }

    /// Creates a reader over normalised text. Pass your own budget to share one ceiling across
    /// several parses. Throws when the input is larger than the limit allows.
    init(_ text: String, limits: YAMLLimits, budget: YAMLBudget = YAMLBudget()) throws {
        guard text.utf8.count <= limits.maxInputBytes else {
            throw YAMLParseError("Input is \(text.utf8.count) bytes, over the \(limits.maxInputBytes) byte limit.",
                                 kind: .inputTooLarge)
        }
        self.limits = limits
        self.budget = budget
        self.depthCeiling = Swift.min(limits.maxDepth, YAMLLimits.maxSupportedDepth)
        let scalars = Array(text.unicodeScalars)
        guard !scalars.contains(where: { c in
            (c.value < 0x20 && c != "\t" && c != "\n" && c != "\r")
        }) else { throw YAMLParseError("Input contains a forbidden control character.", kind: .syntax) }
        // YAML 1.2 line breaks are LF and CR, and both normalise to LF everywhere they are content.
        // Normalising copies the whole input a second time and holds both copies at once, so it only
        // runs when there is a carriage return to normalise. A 0x0D byte never appears inside a
        // multi-byte UTF-8 sequence, so the byte view answers that without decoding anything.
        let normalised: [Unicode.Scalar]
        if text.utf8.contains(0x0D) {
            var out: [Unicode.Scalar] = []
            out.reserveCapacity(scalars.count)
            var k = 0
            while k < scalars.count {
                let c = scalars[k]
                if c == "\r" {
                    out.append("\n")
                    if k + 1 < scalars.count, scalars[k + 1] == "\n" { k += 1 }
                } else {
                    out.append(c)
                }
                k += 1
            }
            normalised = out
        } else {
            normalised = scalars
        }
        self.src = normalised
    }

    // MARK: cursor

    private var current: Unicode.Scalar? { i < src.count ? src[i] : nil }
    private func at(_ k: Int) -> Unicode.Scalar? { i + k < src.count ? src[i + k] : nil }
    private var eof: Bool { i >= src.count }

    private func advance() {
        guard i < src.count else { return }
        if src[i] == "\n" { line += 1; col = 0 } else { col += 1 }
        i += 1
    }

    private func advance(_ n: Int) { for _ in 0 ..< n { advance() } }

    private struct Mark { let i: Int; let line: Int; let col: Int }
    private var mark: Mark { Mark(i: i, line: line, col: col) }
    private func reset(to m: Mark) { i = m.i; line = m.line; col = m.col }

    // MARK: character predicates

    private func isBlank(_ c: Unicode.Scalar?) -> Bool { c == " " || c == "\t" }
    private func isBlankOrBreak(_ c: Unicode.Scalar?) -> Bool { c == nil || c == " " || c == "\t" || c == "\n" }

    @discardableResult
    private func skipBlanks() -> Bool {
        var tab = false
        while isBlank(current) { tab = tab || current == "\t"; advance() }
        return tab
    }

    /// Indentation consists of leading spaces only; a following tab is separation or content.
    private var leadingSpaces: Int {
        var start = i
        while start > 0 && src[start - 1] != "\n" { start -= 1 }
        var end = start
        while end < src.count && src[end] == " " { end += 1 }
        return end - start
    }

    private var indentationHasTab: Bool {
        var start = i
        while start > 0 && src[start - 1] != "\n" { start -= 1 }
        var index = start
        if index < src.count && src[index] == "\u{FEFF}" { index += 1 }
        var tab = false
        while index < src.count && isBlank(src[index]) {
            tab = tab || src[index] == "\t"
            index += 1
        }
        return tab
    }

    private func checkPrintable(_ text: String) throws {
        if text.unicodeScalars.contains(where: { c in
            (0x7F...0x9F).contains(c.value) && c.value != 0x85 || c.value == 0xFFFE || c.value == 0xFFFF
        }) { throw syntax("Non-printable characters must be quoted or escaped.") }
    }
    private func skipToEndOfLine() throws {
        while let c = current, c != "\n" {
            if ((0x7F...0x9F).contains(c.value) && c.value != 0x85) || c.value == 0xFFFE || c.value == 0xFFFF {
                throw syntax("Non-printable characters must be quoted or escaped.")
            }
            advance()
        }
    }

    /// Moves to the first non-space character of the next line that holds content, skipping blank
    /// lines and comment lines. Leaves `col` holding that line's indentation.
    ///
    /// Pass `skipBOM: true` wherever this is used to look for what comes after a value or an item
    /// has fully finished: a document may begin right there, whether that is the stream's own start
    /// or a collection unwinding straight into the next one, and `l-document-prefix` allows a byte
    /// order mark at exactly that position. It is data everywhere else, mid-scalar included, which
    /// is why nothing here runs while a scalar, a quote or a block is still being read; those loops
    /// never call this. The mark can sit on whichever line this scan lands on, past a blank line or
    /// two, so this keeps looking for it rather than checking once before the loop starts.
    private func skipToContent(skipBOM: Bool = false) throws {
        var skipBOM = skipBOM
        while true {
            if skipBOM, current == "\u{FEFF}" {
                // `advance()` would count the mark as a column, so a '---' or '...' right after it
                // would no longer read as sitting at column zero.
                i += 1
                skipBOM = false   // only one mark belongs to this document's prefix
            }
            if col == 0 {
                while current == " " { advance() }
                if current == "\t" {
                    var next = i
                    while next < src.count && isBlank(src[next]) { next += 1 }
                    if next == src.count || src[next] == "\n" || src[next] == "#" { skipBlanks() }
                }
            } else { skipBlanks() }
            // A comment needs a space, a tab or a line break before it. That is always true at the
            // very start of the text, since there is nothing there for it to be glued onto.
            if current == "#", i == 0 || isBlank(src[i - 1]) || src[i - 1] == "\n" { try skipToEndOfLine() }
            if current == "\n" { advance(); continue }
            return
        }
    }

    private var atDocumentStartMarker: Bool {
        col == 0 && at(0) == "-" && at(1) == "-" && at(2) == "-" && isBlankOrBreak(at(3))
    }

    private var atDocumentEndMarker: Bool {
        col == 0 && at(0) == "." && at(1) == "." && at(2) == "." && isBlankOrBreak(at(3))
    }

    private var atDocumentBoundary: Bool { atDocumentStartMarker || atDocumentEndMarker }

    private var atSequenceEntry: Bool { current == "-" && isBlankOrBreak(at(1)) }

    private var atExplicitKey: Bool { current == "?" && isBlankOrBreak(at(1)) }

    private var atExplicitValue: Bool { current == ":" && isBlankOrBreak(at(1)) }

    // MARK: budgets

    private func pushDepth() throws {
        depth += 1
        guard depth <= depthCeiling else {
            throw YAMLParseError("Nesting is deeper than the limit of \(depthCeiling).",
                                 line: line, kind: .depthExceeded)
        }
    }

    private func popDepth() { depth -= 1 }

    private func countNode(_ n: Int = 1) throws {
        budget.nodes += n
        guard budget.nodes <= limits.maxNodes else {
            throw YAMLParseError("Stream produces more than \(limits.maxNodes) nodes.",
                                 line: line, kind: .tooManyNodes)
        }
    }

    private func checkScalarLength(_ n: Int) throws {
        guard n <= limits.maxScalarLength else {
            throw YAMLParseError("Scalar is longer than the limit of \(limits.maxScalarLength).",
                                 line: line, kind: .scalarTooLong)
        }
    }

    private func syntax(_ message: String) -> YAMLParseError {
        YAMLParseError(message, line: line, kind: .syntax)
    }

    // MARK: - stream

    func validateSequenceDocumentStart() throws {
        guard atDocumentStartMarker else { throw syntax("Expected a document-start marker.") }
        advance(3)
        skipBlanks()
        let props = try parseProperties()
        skipBlanks()
        guard eof || current == "#" else {
            throw syntax("Top-level YAML is not a block sequence; streaming decode needs a sequence.")
        }
        // Property syntax, tag resolution and tag limits match the real parser. No nodes or aliases
        // are built, and a root anchor cannot be referenced until its entire sequence is complete.
        _ = try YAMLTag.resolveCollection(.array([]), tag: props.tag, line: line)
    }

    func parseStream() throws -> [YAMLValue] {
        var docs: [YAMLValue] = []
        while true {
            // A byte order mark is only ever data once a document's own content has started, so a
            // document past the first one still gets its prefix checked for one here.
            try skipToContent(skipBOM: true)
            if eof { break }

            var sawDirective = false
            while current == "%" {
                try parseDirective()
                sawDirective = true
                try skipToContent()
            }

            var explicit = false
            if atDocumentStartMarker {
                advance(3)
                explicit = true
            } else if sawDirective {
                throw syntax("A directive has to be followed by a '---' marker.")
            }

            if atDocumentEndMarker {
                advance(3)
                // A '---' with nothing after it is an explicit empty document. A bare '...' with no
                // '---' of its own is just a leftover end marker between documents and starts nothing.
                if explicit { try append(&docs, .null) }
                resetDocumentState()
                continue
            }

            let value: YAMLValue
            if explicit {
                value = try parseNodeValue(parentIndent: -1, parent: .documentRoot)
            } else {
                try skipToContent()
                if eof { break }
                value = try parseNodeHere(indent: col, parentIndent: -1, props: Properties())
            }
            try append(&docs, value)

            let save = mark
            // Whatever follows this document's content is the next one's prefix, so a mark is legal
            // here too.
            try skipToContent(skipBOM: true)
            if eof { break }
            if atDocumentEndMarker {
                advance(3)
                resetDocumentState()
                continue
            }
            if atDocumentStartMarker {
                resetDocumentState()
                continue
            }
            reset(to: save)
            throw syntax("Content after the end of a document needs a '---' or '...' marker.")
        }
        return docs
    }

    private func append(_ docs: inout [YAMLValue], _ value: YAMLValue) throws {
        guard docs.count < limits.maxDocuments else {
            throw YAMLParseError("Stream holds more than \(limits.maxDocuments) documents.",
                                 line: line, kind: .tooManyDocuments)
        }
        docs.append(value)
    }

    /// Anchors and tag handles do not cross a document boundary.
    ///
    /// The node and alias totals do cross it, and deliberately. They bound the work one input can
    /// cause, and a stream is one input however many `---` markers it holds; resetting them here
    /// let a few hundred bytes of alias bomb be repeated once per document for as many documents as
    /// the stream bound allowed.
    private func resetDocumentState() {
        anchors.removeAll()
        tagHandles = ["!": "!", "!!": "tag:yaml.org,2002:"]
        sawYAMLDirective = false
    }

    private func parseDirective() throws {
        advance()
        var name = ""
        while let c = current, !isBlankOrBreak(c) { name.unicodeScalars.append(c); advance() }
        skipBlanks()
        var args: [String] = []
        while let c = current, c != "\n", c != "#" {
            var arg = ""
            while let d = current, !isBlankOrBreak(d), d != "#" { arg.unicodeScalars.append(d); advance() }
            if !arg.isEmpty { args.append(arg) }
            skipBlanks()
            _ = c
        }
        try checkPrintable(name)
        for arg in args { try checkPrintable(arg) }
        switch name {
        case "YAML":
            guard !sawYAMLDirective else { throw syntax("A document has at most one %YAML directive.") }
            sawYAMLDirective = true
            guard args.count == 1, let version = args.first else {
                throw syntax("A %YAML directive takes exactly one version.")
            }
            guard version.hasPrefix("1.") else {
                throw syntax("This library reads YAML 1.x, and the stream declares \(version).")
            }
        case "TAG":
            guard args.count == 2 else { throw syntax("A %TAG directive needs a handle and a prefix.") }
            tagHandles[args[0]] = args[1]
        default:
            break
        }
        try skipToEndOfLine()
    }

    // MARK: - node properties

    private func parseProperties(_ starting: Properties = Properties()) throws -> Properties {
        var props = starting
        while true {
            if current == "&", props.anchor == nil {
                advance()
                props.anchor = try readName(what: "anchor")
            } else if current == "!", props.tag == nil {
                props.tag = try readTag()
            } else {
                break
            }
            let save = mark
            skipBlanks()
            if current == "&" || current == "!" { continue }
            reset(to: save)
            break
        }
        return props
    }

    private func readName(what: String) throws -> String {
        var name = ""
        while let c = current, !isBlankOrBreak(c),
              c != "," && c != "[" && c != "]" && c != "{" && c != "}" {
            name.unicodeScalars.append(c)
            advance()
        }
        guard !name.isEmpty else { throw syntax("An \(what) needs a name.") }
        try checkPrintable(name)
        return name
    }

    private func readTag() throws -> String {
        advance()
        if current == "<" {
            advance()
            var body = ""
            while let c = current, c != ">" { body.unicodeScalars.append(c); advance() }
            guard current == ">" else { throw syntax("A verbatim tag needs a closing '>'.") }
            advance()
            guard !body.isEmpty else { throw syntax("A verbatim tag needs a body.") }
            try checkTagLength(body.utf8.count)
            try checkPrintable(body)
            return body
        }
        var first = ""
        while let c = current, !isBlankOrBreak(c),
              c != "," && c != "[" && c != "]" && c != "{" && c != "}" && c != "!" {
            first.unicodeScalars.append(c)
            advance()
        }
        if current == "!" {
            advance()
            let handle = "!" + first + "!"
            var suffix = ""
            while let c = current, !isBlankOrBreak(c),
                  c != "," && c != "[" && c != "]" && c != "{" && c != "}" {
                suffix.unicodeScalars.append(c)
                advance()
            }
            guard let prefix = tagHandles[handle] else {
                throw syntax("Tag handle \(handle) has no %TAG directive.")
            }
            return try combinedTag(prefix: prefix, suffix: suffix)
        }
        if first.isEmpty { return "!" }
        return try combinedTag(prefix: tagHandles["!"] ?? "!", suffix: first)
    }

    /// Joins a `%TAG` prefix onto a shorthand suffix and percent-decodes the result.
    ///
    /// The handle is declared once but a document can invoke it as many times as it has bytes to
    /// spare for a two-character shorthand, and every invocation used to rebuild the whole tag by
    /// concatenating the prefix onto the suffix with no bound on the result. A short document could
    /// therefore demand a directive-length copy once per invocation, however many that turned out to
    /// be, so the length is checked on the raw pieces before they are joined or decoded rather than
    /// on the string that concatenation already paid to build.
    private func combinedTag(prefix: String, suffix: String) throws -> String {
        try checkPrintable(prefix)
        try checkPrintable(suffix)
        try checkTagLength(prefix.utf8.count + suffix.utf8.count)
        return prefix + percentDecoded(suffix)
    }

    private func checkTagLength(_ n: Int) throws {
        guard n <= limits.maxTagLength else {
            throw YAMLParseError("Tag is \(n) bytes, over the \(limits.maxTagLength) byte limit.",
                                 line: line, kind: .tagTooLong)
        }
    }

    private func percentDecoded(_ s: String) -> String {
        guard s.contains("%") else { return s }
        return s.removingPercentEncoding ?? s
    }

    // MARK: - values

    /// Parses the node that follows a parent's indicator, where the parent sits at `parentIndent`.
    private func parseNodeValue(parentIndent n: Int, parent: ParentKind) throws -> YAMLValue {
        var tab = skipBlanks()
        // A compact collection's baseline is the column right after the indicator that introduced
        // this node ('-', '?' or ':'), not wherever the key text lands once a leading anchor or tag
        // has been read off the same line, so this is captured before parseProperties can consume one.
        let indicatorCol = col
        var props = Properties()
        if current == "&" || current == "!" {
            props = try parseProperties()
            tab = skipBlanks() || tab
        }

        if current == "#" || current == "\n" || eof {
            if current == "#" { try skipToEndOfLine() }
            if current == "\n" { advance() }

            let save = mark
            try skipToContent(skipBOM: true)
            if eof || atDocumentBoundary {
                reset(to: save)
                return try buildScalar(text: "", plain: true, props: props)
            }
            let m = col
            if m > n {
                return try parseNodeHere(indent: m, parentIndent: n, props: props, parent: parent)
            }
            if m == n, parent.allowsZeroIndentSequence, atSequenceEntry {
                return try parseBlockSequence(indent: m, props: props)
            }
            reset(to: save)
            return try buildScalar(text: "", plain: true, props: props)
        }

        if current == "|" || current == ">" {
            let text = try parseBlockScalar(parentIndent: n)
            return try buildScalar(text: text, plain: false, props: props, isBlock: true)
        }

        let m = indicatorCol
        if parent.allowsCompactCollection {
            if atSequenceEntry {
                if tab { throw syntax("A tab cannot indent a compact collection.") }
                return try parseBlockSequence(indent: m, props: props)
            }
            if try startsBlockMapping(indent: m) {
                if tab { throw syntax("A tab cannot indent a compact collection.") }
                return try parseBlockMapping(indent: m, props: props, firstKeyProps: props.isEmpty ? nil : props)
            }
        }
        return try parseFlowNode(parentIndent: n, context: .flowOut, props: props).value
    }

    /// Parses the node that begins at the cursor, which sits at the first content character of a
    /// line indented at `indent`.
    private func parseNodeHere(indent m: Int,
                               parentIndent n: Int,
                               props incoming: Properties,
                               parent: ParentKind = .documentRoot,
                               propsOnKeyLine: Bool = false) throws -> YAMLValue {
        var props = incoming
        let tab = skipBlanks() || indentationHasTab
        // An anchor and a tag may each sit on their own line, more indented than the parent, ahead
        // of the node they both belong to: only read the kind not already carried from an earlier line.
        if (props.anchor == nil && current == "&") || (props.tag == nil && current == "!") {
            props = try parseProperties(props)
            skipBlanks()
            if current == "#" || current == "\n" || eof {
                if current == "#" { try skipToEndOfLine() }
                if current == "\n" { advance() }
                let save = mark
                try skipToContent(skipBOM: true)
                if eof || atDocumentBoundary {
                    reset(to: save)
                    return try buildScalar(text: "", plain: true, props: props)
                }
                // A block sequence is allowed at the same indentation as the mapping value or
                // explicit entry it belongs to, so that case has to be checked before giving up on
                // account of col <= n.
                if col == n, parent.allowsZeroIndentSequence, atSequenceEntry {
                    return try parseBlockSequence(indent: col, props: props)
                }
                if col <= n {
                    reset(to: save)
                    return try buildScalar(text: "", plain: true, props: props)
                }
                return try parseNodeHere(indent: col, parentIndent: n, props: props, parent: parent)
            }
            if current == "|" || current == ">" {
                let text = try parseBlockScalar(parentIndent: n)
                return try buildScalar(text: text, plain: false, props: props, isBlock: true)
            }
            return try parseNodeHere(indent: m, parentIndent: n, props: props, parent: parent, propsOnKeyLine: true)
        }

        if current == "|" || current == ">" {
            let text = try parseBlockScalar(parentIndent: n)
            return try buildScalar(text: text, plain: false, props: props, isBlock: true)
        }
        if atSequenceEntry {
            if tab { throw syntax("A tab cannot indent a block collection.") }
            return try parseBlockSequence(indent: m, props: props)
        }
        if try startsBlockMapping(indent: m) {
            if tab { throw syntax("A tab cannot indent a block collection.") }
            return try parseBlockMapping(indent: m,
                                         props: props,
                                         firstKeyProps: propsOnKeyLine ? props : nil)
        }
        return try parseFlowNode(parentIndent: n, context: .flowOut, props: props).value
    }

    // MARK: - block collections

    private func startsBlockMapping(indent m: Int) throws -> Bool {
        if atExplicitKey { return true }
        // A ':' where a node may start, with nothing before it, is a mapping entry whose key was
        // omitted rather than the start of a plain scalar: ':' only opens one when non-blank follows.
        if atExplicitValue { return true }
        let save = mark
        let savedNodes = budget.nodes
        let savedAliases = budget.aliases
        // Probing must not spend the node or alias budget, since the same key is parsed again for
        // real right after: a key that is itself an alias, or that dereferences one while it is
        // being read, would otherwise be charged twice for one dereference, once here and once for
        // real, while a key parsed as an ordinary value only ever pays once.
        defer {
            reset(to: save)
            budget.nodes = savedNodes
            budget.aliases = savedAliases
        }
        let probe: FlowResult
        do {
            probe = try parseFlowNode(parentIndent: m, context: .blockKey, props: Properties())
        } catch let error as YAMLParseError where error.isLimit {
            // A limit crossed while probing is definitive, not a hint to backtrack and try reading
            // the same bytes as something else: whatever crossed it is still there however this is
            // parsed next, and reporting it as an ordinary syntax mismatch would hide from a caller
            // that the document is valid but bigger than the limits allow, rather than malformed.
            throw error
        } catch {
            return false
        }
        skipBlanks()
        guard current == ":" else { return false }
        return probe.jsonLike || isBlankOrBreak(at(1))
    }

    private func parseBlockMapping(indent m: Int,
                                   props: Properties,
                                   firstKeyProps: Properties? = nil) throws -> YAMLValue {
        if indentationHasTab { throw syntax("A tab cannot indent a block collection.") }
        try pushDepth()
        defer { popDepth() }
        try countNode()

        var members: [YAMLValue.Member] = []
        var index: [String: Int] = [:]
        // Properties written before an implicit key belong to that key, so a mapping reached through
        // them must not claim them for itself.
        var keyProps = firstKeyProps ?? Properties()
        let collectionProps = firstKeyProps == nil ? props : Properties()

        while true {
            let key: String
            let value: YAMLValue

            if atExplicitKey {
                advance()
                let keyNode = try parseNodeValue(parentIndent: m, parent: .explicitKey)
                key = try keyText(keyNode)
                let save = mark
                try skipToContent(skipBOM: true)
                if !eof, col == m, atExplicitValue, !atDocumentBoundary {
                    advance()
                    value = try parseNodeValue(parentIndent: m, parent: .explicitValue)
                } else {
                    reset(to: save)
                    value = .null
                }
            } else if atExplicitValue {
                // The key was omitted entirely: any anchor or tag written before the ':' belongs to
                // that missing key, same as an empty node anywhere else.
                let keyNode = try buildScalar(text: "", plain: true, props: keyProps)
                keyProps = Properties()
                key = try keyText(keyNode)
                advance()
                value = try parseNodeValue(parentIndent: m, parent: .mappingValue)
            } else {
                let probe = try parseFlowNode(parentIndent: m, context: .blockKey, props: keyProps)
                keyProps = Properties()
                key = try keyText(probe.value)
                skipBlanks()
                guard current == ":", probe.jsonLike || isBlankOrBreak(at(1)) else {
                    throw syntax("Expected ':' after a mapping key.")
                }
                advance()
                value = try parseNodeValue(parentIndent: m, parent: .mappingValue)
            }

            try record(key: key, value: value, into: &members, index: &index)

            let save = mark
            try skipToContent(skipBOM: true)
            if eof || atDocumentBoundary { reset(to: save); break }
            if col < m { reset(to: save); break }
            if col > m {
                throw syntax("Line is indented past the mapping it belongs to.")
            }
            if atSequenceEntry { reset(to: save); break }
            if !atExplicitKey, !(try startsBlockMapping(indent: m)) {
                throw syntax("Expected another mapping key at this indentation.")
            }
        }

        return try applyCollectionTag(props: collectionProps, value: .object(members))
    }

    private func record(key: String,
                        value: YAMLValue,
                        into members: inout [YAMLValue.Member],
                        index: inout [String: Int]) throws {
        if let existing = index[key] {
            switch limits.duplicateKeys {
            case .reject:
                throw YAMLParseError("Mapping repeats the key \(key).", line: line, kind: .duplicateKey)
            case .firstWins:
                return
            case .lastWins:
                members[existing].value = value
                return
            }
        }
        index[key] = members.count
        members.append(.init(key: key, value: value))
    }

    private func parseBlockSequence(indent m: Int, props: Properties) throws -> YAMLValue {
        if indentationHasTab { throw syntax("A tab cannot indent a block collection.") }
        try pushDepth()
        defer { popDepth() }
        try countNode()

        var items: [YAMLValue] = []
        while true {
            guard atSequenceEntry else { throw syntax("Expected a '-' sequence entry.") }
            advance()
            items.append(try parseNodeValue(parentIndent: m, parent: .sequenceItem))

            let save = mark
            try skipToContent(skipBOM: true)
            if eof || atDocumentBoundary { reset(to: save); break }
            if col < m { reset(to: save); break }
            if col == m {
                if atSequenceEntry { continue }
                reset(to: save)
                break
            }
            throw syntax("Line is indented past the sequence it belongs to.")
        }

        return try applyCollectionTag(props: props, value: .array(items))
    }

    // MARK: - block scalars

    private func parseBlockScalar(parentIndent n: Int) throws -> String {
        let folded = current == ">"
        advance()

        var chomping: Unicode.Scalar? = nil
        var explicitIndent: Int? = nil
        while let c = current, !isBlankOrBreak(c) {
            if c == "-" || c == "+" {
                guard chomping == nil else { throw syntax("A block scalar header has one chomping indicator.") }
                chomping = c
            } else if let d = c.properties.numericValue, d >= 1, d <= 9, explicitIndent == nil {
                explicitIndent = n + Int(d)
            } else {
                throw syntax("A block scalar header does not accept '\(c)'.")
            }
            advance()
        }
        skipBlanks()
        if current == "#" { try skipToEndOfLine() }
        guard current == "\n" || eof else { throw syntax("A block scalar header ends the line.") }
        if current == "\n" { advance() }

        var contentIndent = explicitIndent
        var lines: [String] = []
        var leadingEmptyIndent = 0
        var collected = 0
        var contentEndedWithBreak = false

        while true {
            if eof { break }
            let lineStart = mark
            var spaces = 0
            while current == " " { spaces += 1; advance() }

            if current == "\n" || eof {
                if let ci = contentIndent, spaces > ci {
                    // Blank, but indented past the block's content: the indentation up to ci is not
                    // content, but the rest of the run of spaces is a line of that many spaces.
                    let text = String(repeating: " ", count: spaces - ci)
                    collected += text.unicodeScalars.count + 1
                    try checkScalarLength(collected)
                    lines.append(text)
                    contentEndedWithBreak = current == "\n"
                } else {
                    // A truly empty line, whose own indentation is not content.
                    if contentIndent == nil { leadingEmptyIndent = Swift.max(leadingEmptyIndent, spaces) }
                    if current == "\n" { lines.append("") }
                }
                if current == "\n" { advance() }
                if eof { break }
                continue
            }

            if spaces == 0, atDocumentBoundary {
                reset(to: lineStart)
                break
            }
            if contentIndent == nil {
                guard spaces > n else { reset(to: lineStart); break }
                guard spaces >= leadingEmptyIndent else {
                    throw syntax("A leading empty line is indented past the block scalar's content.")
                }
                contentIndent = spaces
            }
            guard let ci = contentIndent else { break }
            if spaces < ci {
                reset(to: lineStart)
                break
            }
            var text = String(repeating: " ", count: spaces - ci)
            while let c = current, c != "\n" { text.unicodeScalars.append(c); advance() }
            collected += text.unicodeScalars.count + 1
            try checkScalarLength(collected)
            lines.append(text)
            contentEndedWithBreak = current == "\n"
            if current == "\n" { advance() } else { break }
        }

        var trailingEmpties = 0
        while lines.last?.isEmpty == true { trailingEmpties += 1; lines.removeLast() }

        let body = folded ? foldBlockLines(lines, contentIndent: contentIndent ?? 0) : lines.joined(separator: "\n")
        try checkScalarLength(body.unicodeScalars.count + trailingEmpties)

        // Clipping keeps the last nonempty content line's actual break. Indentation-only
        // EOF whitespace contributes no extra line, even after genuine trailing blank lines.
        let lastBreak = contentEndedWithBreak && !body.isEmpty ? "\n" : ""
        switch chomping {
        case "-":
            return body
        case "+":
            return body + lastBreak + String(repeating: "\n", count: trailingEmpties)
        default:
            return body + lastBreak
        }
    }

    /// Folds the lines of a `>` block scalar. A line indented past the content indentation keeps its
    /// own line breaks, which is what lets a folded scalar carry a verbatim block.
    private func foldBlockLines(_ lines: [String], contentIndent: Int) -> String {
        func isMoreIndented(_ s: String) -> Bool { s.first == " " || s.first == "\t" }

        var out = ""
        var started = false
        var k = 0
        var previousText: String? = nil

        while k < lines.count {
            if lines[k].isEmpty {
                var empties = 0
                while k < lines.count, lines[k].isEmpty { empties += 1; k += 1 }
                guard k < lines.count else { break }
                let next = lines[k]
                if !started {
                    out += String(repeating: "\n", count: empties)
                } else if isMoreIndented(previousText ?? "") || isMoreIndented(next) {
                    out += String(repeating: "\n", count: empties + 1)
                } else {
                    out += String(repeating: "\n", count: empties)
                }
                out += next
                previousText = next
                started = true
                k += 1
                continue
            }
            let text = lines[k]
            if !started {
                out += text
                started = true
            } else if isMoreIndented(previousText ?? "") || isMoreIndented(text) {
                out += "\n" + text
            } else {
                out += " " + text
            }
            previousText = text
            k += 1
        }
        return out
    }

    // MARK: - flow nodes

    private struct FlowResult {
        let value: YAMLValue
        let jsonLike: Bool
    }

    private func parseFlowNode(parentIndent n: Int,
                               context: YAMLContext,
                               props incoming: Properties) throws -> FlowResult {
        var props = incoming
        if props.isEmpty, current == "&" || current == "!" {
            props = try parseProperties()
            skipBlanks()
            if context.inFlowBrackets { try skipFlowSeparation(parentIndent: n) }
        }

        guard let c = current else {
            return FlowResult(value: try buildScalar(text: "", plain: true, props: props), jsonLike: false)
        }
        // ']', '}' and a line break only ever reach here where a caller already treats an omitted
        // node as valid and skipped this call. A comma does too, but only once an anchor or a tag
        // already read for this node makes it a deliberately empty node rather than a stray comma:
        // every flow entry needs some content of its own, tagged or not.
        if c == "]" || c == "}" || c == "\n" || (c == "," && !props.isEmpty) {
            return FlowResult(value: try buildScalar(text: "", plain: true, props: props), jsonLike: false)
        }
        if c == ":", context.inFlowBrackets,
           isBlankOrBreak(at(1)) || at(1) == "," || at(1) == "]" || at(1) == "}" {
            return FlowResult(value: try buildScalar(text: "", plain: true, props: props), jsonLike: false)
        }

        switch c {
        case "*":
            advance()
            let name = try readName(what: "alias")
            guard props.isEmpty else { throw syntax("An alias cannot carry an anchor or a tag.") }
            return FlowResult(value: try resolveAlias(name), jsonLike: false)
        case "[":
            let v = try parseFlowSequence(parentIndent: n, props: props)
            return FlowResult(value: v, jsonLike: true)
        case "{":
            let v = try parseFlowMapping(parentIndent: n, props: props)
            return FlowResult(value: v, jsonLike: true)
        case "\"", "'":
            let text = try parseQuoted(c, parentIndent: n, singleLine: context.isSingleLine)
            return FlowResult(value: try buildScalar(text: text, plain: false, props: props), jsonLike: true)
        default:
            guard isPlainFirst(c, context: context) else {
                throw syntax("A plain scalar cannot start with '\(c)'.")
            }
            let text = try parsePlainScalar(parentIndent: n, context: context)
            return FlowResult(value: try buildScalar(text: text, plain: true, props: props), jsonLike: false)
        }
    }

    private func isPlainFirst(_ c: Unicode.Scalar, context: YAMLContext) -> Bool {
        switch c {
        case "-", "?", ":":
            guard let next = at(1) else { return false }
            if isBlankOrBreak(next) { return false }
            if context.inFlowBrackets, next == "," || next == "[" || next == "]" || next == "{" || next == "}" {
                return false
            }
            return true
        case ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`":
            return false
        case "\n", " ", "\t":
            return false
        default:
            return true
        }
    }

    /// Skips whitespace, comments and line breaks inside a flow collection. Throws when the flow
    /// runs into a document boundary or dedents out of its parent, which both mean it never closed.
    private func skipFlowSeparation(parentIndent n: Int) throws {
        var crossedLine = false
        while true {
            skipBlanks()
            // A comment needs a space, a tab or a line break before it, the same as anywhere else in
            // the grammar; one glued directly onto the token before it (a comma, a bracket, a scalar)
            // is not a comment at all, so it is left for whatever reads next to reject as it is. The
            // preceding character is read straight from the source, since the blank run before a
            // comment can just as well have already been consumed as the trailing edge of a scalar.
            if current == "#", i > 0, isBlank(src[i - 1]) || src[i - 1] == "\n" { try skipToEndOfLine() }
            if current == "\n" { advance(); crossedLine = true; continue }
            break
        }
        if crossedLine {
            if eof { throw syntax("Flow collection is not closed.") }
            if atDocumentBoundary { throw syntax("Flow collection is not closed before the document ends.") }
            if leadingSpaces <= n { throw syntax("Flow collection is not closed at this indentation.") }
        }
    }

    private func parseFlowSequence(parentIndent n: Int, props: Properties) throws -> YAMLValue {
        try pushDepth()
        defer { popDepth() }
        try countNode()

        advance()
        var items: [YAMLValue] = []
        try skipFlowSeparation(parentIndent: n)
        if current == "]" { advance(); return try applyCollectionTag(props: props, value: .array(items)) }

        while true {
            if current == "?" && isBlankOrBreak(at(1)) {
                items.append(try parseFlowPair(parentIndent: n, explicit: true))
            } else {
                let entry = try parseFlowNode(parentIndent: n, context: .flowIn, props: Properties())
                try skipFlowSeparation(parentIndent: n)
                if current == ":" , entry.jsonLike || isBlankOrBreak(at(1)) || at(1) == "," || at(1) == "]" {
                    advance()
                    try skipFlowSeparation(parentIndent: n)
                    let value: YAMLValue
                    if current == "," || current == "]" {
                        value = .null
                    } else {
                        value = try parseFlowNode(parentIndent: n, context: .flowIn, props: Properties()).value
                    }
                    try countNode()
                    items.append(.object([.init(key: try keyText(entry.value), value: value)]))
                } else {
                    items.append(entry.value)
                }
            }
            try skipFlowSeparation(parentIndent: n)
            guard let c = current else { throw syntax("Flow sequence is not closed.") }
            if c == "," {
                advance()
                try skipFlowSeparation(parentIndent: n)
                if current == "]" { advance(); break }
                continue
            }
            if c == "]" { advance(); break }
            throw syntax("Expected ',' or ']' in a flow sequence.")
        }
        return try applyCollectionTag(props: props, value: .array(items))
    }

    private func parseFlowPair(parentIndent n: Int, explicit: Bool) throws -> YAMLValue {
        advance()
        try skipFlowSeparation(parentIndent: n)
        var key: YAMLValue = .null
        if current != ":" && current != "," && current != "]" && current != "}" {
            key = try parseFlowNode(parentIndent: n, context: .flowKey, props: Properties()).value
        }
        try skipFlowSeparation(parentIndent: n)
        var value: YAMLValue = .null
        if current == ":" {
            advance()
            try skipFlowSeparation(parentIndent: n)
            if current != "," && current != "]" && current != "}" {
                value = try parseFlowNode(parentIndent: n, context: .flowIn, props: Properties()).value
            }
        }
        try countNode()
        return .object([.init(key: try keyText(key), value: value)])
    }

    private func parseFlowMapping(parentIndent n: Int, props: Properties) throws -> YAMLValue {
        try pushDepth()
        defer { popDepth() }
        try countNode()

        advance()
        var members: [YAMLValue.Member] = []
        var index: [String: Int] = [:]
        try skipFlowSeparation(parentIndent: n)
        if current == "}" { advance(); return try applyCollectionTag(props: props, value: .object(members)) }

        while true {
            var key: YAMLValue = .null
            var jsonLike = false
            var explicit = false

            if current == "?" && isBlankOrBreak(at(1)) {
                advance()
                explicit = true
                try skipFlowSeparation(parentIndent: n)
            }
            if current != ":" && current != "," && current != "}" {
                let probe = try parseFlowNode(parentIndent: n,
                                              context: explicit ? .flowIn : .flowKey,
                                              props: Properties())
                key = probe.value
                jsonLike = probe.jsonLike
            }
            try skipFlowSeparation(parentIndent: n)

            var value: YAMLValue = .null
            if current == ":", jsonLike || explicit || isBlankOrBreak(at(1)) || at(1) == "," || at(1) == "}" {
                advance()
                try skipFlowSeparation(parentIndent: n)
                if current != "," && current != "}" {
                    value = try parseFlowNode(parentIndent: n, context: .flowIn, props: Properties()).value
                }
                try skipFlowSeparation(parentIndent: n)
            }

            try record(key: try keyText(key), value: value, into: &members, index: &index)

            guard let c = current else { throw syntax("Flow mapping is not closed.") }
            if c == "," {
                advance()
                try skipFlowSeparation(parentIndent: n)
                if current == "}" { advance(); break }
                continue
            }
            if c == "}" { advance(); break }
            throw syntax("Expected ',' or '}' in a flow mapping.")
        }
        return try applyCollectionTag(props: props, value: .object(members))
    }

    // MARK: - scalars

    private func parsePlainScalar(parentIndent n: Int, context: YAMLContext) throws -> String {
        var out = ""
        var separator = ""
        var started = false
        var length = 0

        while true {
            let segment = readPlainSegment(context: context)
            if started { out += separator; length += separator.unicodeScalars.count }
            out += segment
            length += segment.unicodeScalars.count
            started = true
            try checkScalarLength(length)

            if context.isSingleLine { break }

            let save = mark
            var breaks = 0
            while true {
                skipBlanks()
                if current == "\n" { advance(); breaks += 1; continue }
                break
            }
            if breaks == 0 || eof { reset(to: save); break }
            if atDocumentBoundary { reset(to: save); break }
            if leadingSpaces <= n { reset(to: save); break }
            if current == "#" { reset(to: save); break }
            if context.inFlowBrackets, current == "," || current == "]" || current == "}" {
                reset(to: save)
                break
            }
            // A '-' or '?' here reads as an indicator only at the enclosing block's own indentation;
            // past the `col <= n` check above, this line is already more indented than that, so a
            // dash or question mark here is just more scalar text, the same as any other character.
            separator = breaks == 1 ? " " : String(repeating: "\n", count: breaks - 1)
        }
        return trimTrailingBlanks(out)
    }

    private func readPlainSegment(context: YAMLContext) -> String {
        var out = ""
        while let c = current {
            if c == "\n" { break }
            if c == "#", out.last == " " || out.last == "\t" { break }
            if c == ":" {
                let next = at(1)
                if isBlankOrBreak(next) { break }
                if context.inFlowBrackets, next == "," || next == "[" || next == "]" || next == "{" || next == "}" {
                    break
                }
            }
            if context.inFlowBrackets, c == "," || c == "[" || c == "]" || c == "{" || c == "}" { break }
            out.unicodeScalars.append(c)
            advance()
        }
        return trimTrailingBlanks(out)
    }

    private func trimTrailingBlanks(_ s: String) -> String {
        var out = s
        while out.last == " " || out.last == "\t" { out.removeLast() }
        return out
    }

    /// Trims trailing spaces and tabs, but never past `keep` scalars from the start. Used for a
    /// quoted scalar's line folding, where an escape can resolve to a space or a tab right at the end
    /// of a line: that character is real content, not the line's own trailing white space, so folding
    /// must leave it alone even though it looks the same once resolved.
    private func trimTrailingBlanks(_ s: String, keeping keep: Int) -> String {
        var out = s.unicodeScalars
        while out.count > keep, let last = out.last, last == " " || last == "\t" { out.removeLast() }
        return String(out)
    }

    private func parseQuoted(_ quote: Unicode.Scalar, parentIndent: Int, singleLine: Bool = false) throws -> String {
        advance()
        var out = ""
        var separator = ""
        var started = false
        var segment = ""
        // How many scalars `segment` holds, carried along as it grows. Asking the string itself
        // walks it, and the one place that wanted the answer was after every escape, which made a
        // scalar of nothing but escapes cost the square of its own length to read.
        var segmentLength = 0
        var escapedJoin = false
        var length = 0
        var escapedLength = 0   // segment's length right after the most recent escape, protected from trimming

        func flushSegment() throws {
            if started, !escapedJoin { out += separator; length += separator.unicodeScalars.count }
            out += segment
            length += segmentLength
            started = true
            escapedJoin = false
            segment = ""
            segmentLength = 0
            escapedLength = 0
            try checkScalarLength(length)
        }

        while true {
            guard let c = current else {
                throw syntax("Quoted scalar is not closed before the input ends.")
            }

            if c == "\n" {
                guard !singleLine else { throw syntax("An implicit key needs to be on one line.") }
                if quote == "\"" {
                    segment = trimTrailingBlanks(segment, keeping: escapedLength)
                } else {
                    segment = trimTrailingBlanks(segment)
                }
                // Trimming already walked this line's segment, and a segment is one line's worth,
                // so recounting it here stays linear over the scalar as a whole.
                segmentLength = segment.unicodeScalars.count
                try flushSegment()
                var breaks = 0
                while true {
                    skipBlanks()
                    if current == "\n" { advance(); breaks += 1; continue }
                    break
                }
                if eof { throw syntax("Quoted scalar is not closed before the input ends.") }
                if atDocumentBoundary { throw syntax("Quoted scalar runs into a document marker.") }
                if leadingSpaces <= parentIndent { throw syntax("Quoted scalar does not clear its parent's indentation.") }
                separator = breaks == 1 ? " " : String(repeating: "\n", count: breaks - 1)
                continue
            }

            if quote == "'" {
                if c == "'" {
                    if at(1) == "'" { segment += "'"; segmentLength += 1; advance(2); continue }
                    advance()
                    try flushSegment()
                    return out
                }
                segment.unicodeScalars.append(c)
                segmentLength += 1
                advance()
                continue
            }

            if c == "\\" {
                advance()
                guard let e = current else { throw syntax("A double-quoted scalar ends with a stray backslash.") }
                if e == "\n" {
                    if singleLine { throw syntax("An implicit key needs to be on one line.") }
                    advance()
                    skipBlanks()
                    if current != "\n" && !eof {
                        if atDocumentBoundary { throw syntax("Quoted scalar runs into a document marker.") }
                        if leadingSpaces <= parentIndent { throw syntax("Quoted scalar does not clear its parent's indentation.") }
                    }
                    try flushSegment()
                    escapedJoin = true
                    separator = ""
                    continue
                }
                let resolved = try readEscape(e)
                segment += resolved
                segmentLength += resolved.unicodeScalars.count
                escapedLength = segmentLength
                continue
            }
            if c == "\"" {
                advance()
                try flushSegment()
                return out
            }
            segment.unicodeScalars.append(c)
            segmentLength += 1
            advance()
        }
    }

    private func readEscape(_ e: Unicode.Scalar) throws -> String {
        advance()
        switch e {
        case "0": return "\0"
        case "a": return "\u{07}"
        case "b": return "\u{08}"
        case "t", "\t": return "\t"
        case "n": return "\n"
        case "v": return "\u{0B}"
        case "f": return "\u{0C}"
        case "r": return "\r"
        case "e": return "\u{1B}"
        case " ": return " "
        case "\"": return "\""
        case "/": return "/"
        case "\\": return "\\"
        case "N": return "\u{85}"
        case "_": return "\u{A0}"
        case "L": return "\u{2028}"
        case "P": return "\u{2029}"
        case "x": return try readHexEscape(digits: 2)
        case "u": return try readHexEscape(digits: 4)
        case "U": return try readHexEscape(digits: 8)
        default:
            throw syntax("A double-quoted scalar does not accept the escape '\\\(e)'.")
        }
    }

    private func readHexEscape(digits: Int) throws -> String {
        var hex = ""
        for _ in 0 ..< digits {
            guard let c = current, c.properties.isASCIIHexDigit else {
                throw syntax("A '\\x', '\\u' or '\\U' escape needs \(digits) hex digits.")
            }
            hex.unicodeScalars.append(c)
            advance()
        }
        guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
            throw syntax("Escape '\\\(hex)' is not a unicode scalar value.")
        }
        return String(Character(scalar))
    }

    // MARK: - building values

    private func buildScalar(text: String, plain: Bool, props: Properties, isBlock: Bool = false) throws -> YAMLValue {
        try countNode()
        try checkScalarLength(text.unicodeScalars.count)
        if plain || isBlock { try checkPrintable(text) }
        let resolved = try YAMLTag.resolveScalar(text: text,
                                                 plain: plain && !isBlock,
                                                 tag: props.tag,
                                                 line: line)
        if let anchor = props.anchor { rememberAnchor(anchor, resolved, nodes: 1, depth: 1) }
        return resolved
    }

    private func applyCollectionTag(props: Properties, value: YAMLValue) throws -> YAMLValue {
        let resolved = try YAMLTag.resolveCollection(value, tag: props.tag, line: line)
        if let anchor = props.anchor {
            let shape = resolved.shape
            rememberAnchor(anchor, resolved, nodes: shape.nodes, depth: shape.depth)
        }
        return resolved
    }

    private func rememberAnchor(_ name: String, _ value: YAMLValue, nodes: Int, depth: Int) {
        anchors[name] = Anchor(value: value, nodes: nodes, depth: depth)
    }

    private func resolveAlias(_ name: String) throws -> YAMLValue {
        guard let anchor = anchors[name] else {
            throw YAMLParseError("Alias '*\(name)' names an anchor that has not been defined.",
                                 line: line, kind: .undefinedAlias)
        }
        budget.aliases += 1
        guard budget.aliases <= limits.maxAliasExpansions else {
            throw YAMLParseError("Stream dereferences more than \(limits.maxAliasExpansions) aliases.",
                                 line: line, kind: .tooManyAliases)
        }
        // An alias drops a whole subtree in at this point, so it can build a value deeper than the
        // parser's own recursion ever went. The bound has to cover that as well as the stack.
        guard depth + anchor.depth <= depthCeiling else {
            throw YAMLParseError("Alias '*\(name)' would nest deeper than the limit of \(depthCeiling).",
                                 line: line, kind: .depthExceeded)
        }
        try countNode(anchor.nodes)
        return anchor.value
    }

    /// Mappings in this library are keyed by `String`, so a collection used as a key has no
    /// representation and is refused rather than flattened into something arbitrary.
    private func keyText(_ node: YAMLValue) throws -> String {
        switch node {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .uint(let u): return String(u)
        case .double(let d): return YAMLValue.doubleText(d, keepPointZero: false)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array, .object:
            throw syntax("A sequence or mapping used as a key has no representation in this library.")
        }
    }
}
