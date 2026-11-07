import Foundation

/// Tracks the constructs that span lines, so a line-at-a-time splitter can tell a real item
/// boundary from a line that only looks like one.
///
/// The streaming readers find items by looking for a dash at the base indentation. A quoted scalar,
/// a flow collection and a block scalar can all carry a line that reads that way, and splitting
/// there cuts a value in half. Feeding every line through this keeps the splitters at one line of
/// state while still knowing what they are inside of.
struct YAMLLineState {

    private(set) var inSingleQuote = false
    private(set) var inDoubleQuote = false
    private(set) var flowDepth = 0

    /// Indentation a continuation line has to clear to belong to the block scalar currently being
    /// read. Usually the indentation of the line that opened it, but a header reached through a
    /// compact sequence entry ("- key: |") opens at the key's own column, not the dash's, since
    /// that is the column the following lines are actually measured against.
    private(set) var blockScalarIndent: Int?

    /// Indentation of the line that opened a plain scalar still being read, once nothing else
    /// (a quote, a flow collection, a block scalar) is open. A continuation line has to be indented
    /// past this, the same rule a block scalar's continuation follows.
    private(set) var openPlainScalarIndent: Int?

    /// True when the last line fed ended in the middle of an indicator-free run of characters
    /// (plain scalar content, or literal text inside an open flow collection) rather than at a
    /// position where a new node could start. Carried into the next line so its own leading
    /// character, a quote among them, reads as more of that text instead of opening a new node.
    private(set) var endedInPlainText = false

    private static let space: UInt8 = 0x20
    private static let tab: UInt8 = 0x09
    private static let hash: UInt8 = 0x23
    private static let quote: UInt8 = 0x27
    private static let doubleQuote: UInt8 = 0x22
    private static let backslash: UInt8 = 0x5C
    private static let openBracket: UInt8 = 0x5B
    private static let closeBracket: UInt8 = 0x5D
    private static let openBrace: UInt8 = 0x7B
    private static let closeBrace: UInt8 = 0x7D
    private static let pipe: UInt8 = 0x7C
    private static let angle: UInt8 = 0x3E
    private static let dash: UInt8 = 0x2D
    private static let plus: UInt8 = 0x2B
    private static let colon: UInt8 = 0x3A
    private static let comma: UInt8 = 0x2C
    private static let question: UInt8 = 0x3F
    private static let ampersand: UInt8 = 0x26
    private static let bang: UInt8 = 0x21
    private static let star: UInt8 = 0x2A

    /// True when nothing is open that a following line could belong to.
    var isBetweenItems: Bool { !inSingleQuote && !inDoubleQuote && flowDepth == 0 }

    /// True when a line at this indentation belongs to something that began on an earlier line.
    ///
    /// Pass the line's indentation and whether it holds anything after that indentation.
    func isContinuation(indent: Int, isBlank: Bool) -> Bool {
        if !isBetweenItems { return true }
        if let opener = blockScalarIndent { return isBlank || indent > opener }
        if let opener = openPlainScalarIndent { return isBlank || indent > opener }
        return false
    }

    /// Reads one line and carries forward what it leaves open. Pass the bytes after the line's
    /// indentation, and that indentation.
    mutating func feed<S: BidirectionalCollection>(content: S, indent: Int) where S.Element == UInt8 {
        if let opener = blockScalarIndent {
            if content.isEmpty || indent > opener { return }
            blockScalarIndent = nil
        }

        // A blank line does not end anything that is open, plain scalar included, so it is passed
        // through untouched: no new state to seed from, and nothing below to update either.
        guard !content.isEmpty else { return }

        // A quote only opens a scalar where a node may start, so an apostrophe in the middle of a
        // plain scalar is the text it looks like rather than an opening quote. A line that continues
        // a plain scalar or an open flow entry from an earlier line starts past that position too.
        let continuingPlainRun = !isBetweenItems
            || openPlainScalarIndent.map { indent > $0 } ?? false
        var atNodeStart = continuingPlainRun ? !endedInPlainText : true
        if !continuingPlainRun { openPlainScalarIndent = nil }
        var endsInPlainText = !atNodeStart

        var significantEnd = content.endIndex
        var previous = Self.space
        var index = content.startIndex
        var inProperty = false

        // Column a block scalar header at the end of this line would open at, if it turns out to be
        // one. Defaults to the line's own indentation, which is right whenever the header sits at
        // the start of a line. A key or a dash ahead of it on the same line (compact notation) moves
        // this to that key's or dash's own column instead, since a mapping's or sequence's entries
        // are measured from there, not from wherever the line itself starts.
        var nodeIndent = indent
        var contentOffset = 0
        var runStartOffset = 0

        while index < content.endIndex {
            let byte = content[index]

            if previous == Self.space || previous == Self.tab { runStartOffset = contentOffset }

            if inDoubleQuote {
                if byte == Self.backslash {
                    let next = content.index(index, offsetBy: 2, limitedBy: content.endIndex) ?? content.endIndex
                    contentOffset += content.distance(from: index, to: next)
                    index = next
                    previous = 0
                    continue
                }
                if byte == Self.doubleQuote { inDoubleQuote = false; atNodeStart = false; endsInPlainText = false }
            } else if inSingleQuote {
                if byte == Self.quote {
                    let next = content.index(after: index)
                    if next < content.endIndex, content[next] == Self.quote {
                        let after = content.index(after: next)
                        contentOffset += content.distance(from: index, to: after)
                        index = after
                        previous = 0
                        continue
                    }
                    inSingleQuote = false
                    atNodeStart = false
                    endsInPlainText = false
                }
            } else {
                if byte == Self.hash, index == content.startIndex || previous == Self.space || previous == Self.tab {
                    significantEnd = index
                    break
                }
                switch byte {
                case Self.doubleQuote where atNodeStart && !inProperty: inDoubleQuote = true
                case Self.quote where atNodeStart && !inProperty: inSingleQuote = true
                // A bracket opens a flow collection where a node may start, and inside one it always
                // does. Anywhere else it is a character in a plain scalar, which block context allows.
                case Self.openBracket, Self.openBrace:
                    inProperty = false
                    if atNodeStart || flowDepth > 0 {
                        flowDepth += 1; atNodeStart = true; endsInPlainText = false
                    } else {
                        atNodeStart = false; endsInPlainText = true
                    }
                case Self.closeBracket, Self.closeBrace:
                    inProperty = false
                    if flowDepth > 0 { flowDepth -= 1 }
                    atNodeStart = false
                    endsInPlainText = false
                case Self.comma where flowDepth > 0: inProperty = false; atNodeStart = true; endsInPlainText = false
                case Self.space, Self.tab: inProperty = false
                // A colon ends a key and opens the position after it, and inside flow brackets it
                // does so whatever follows, since a plain scalar there may not hold one. Only a block
                // context colon can be the key of a header's enclosing mapping, so only that one
                // moves the baseline.
                case Self.colon where !inProperty:
                    atNodeStart = flowDepth > 0 || endsToken(content, at: index)
                    endsInPlainText = !atNodeStart
                    if atNodeStart, flowDepth == 0 { nodeIndent = indent + runStartOffset }
                // A dash or a question mark holds the position it is already in and never reopens
                // one, since both are text once a plain scalar has started on the line.
                case Self.dash, Self.question:
                    if !inProperty, atNodeStart {
                        atNodeStart = endsToken(content, at: index)
                        endsInPlainText = !atNodeStart
                        if atNodeStart, flowDepth == 0 { nodeIndent = indent + runStartOffset }
                    }
                // An anchor, a tag or an alias sits ahead of the node it belongs to, so the
                // characters of the token leave the position open.
                case Self.ampersand, Self.bang, Self.star: inProperty = atNodeStart
                default: if !inProperty { atNodeStart = false; endsInPlainText = true }
                }
            }

            previous = byte
            contentOffset += 1
            index = content.index(after: index)
        }

        if isBetweenItems, endsWithBlockScalarHeader(content[content.startIndex ..< significantEnd]) {
            blockScalarIndent = nodeIndent
            openPlainScalarIndent = nil
            endedInPlainText = false
            return
        }

        endedInPlainText = endsInPlainText
        if isBetweenItems, endsInPlainText, significantEnd > content.startIndex {
            if openPlainScalarIndent == nil { openPlainScalarIndent = indent }
        } else {
            openPlainScalarIndent = nil
        }
    }

    /// True when whitespace or the end of the line follows `index`, which is what makes an indicator
    /// an indicator rather than one more character of a plain scalar.
    private func endsToken<S: BidirectionalCollection>(_ content: S, at index: S.Index) -> Bool where S.Element == UInt8 {
        let next = content.index(after: index)
        guard next < content.endIndex else { return true }
        return content[next] == Self.space || content[next] == Self.tab
    }

    /// True when the line ends with a block scalar header, meaning `|` or `>` and its indicators.
    ///
    /// Reading a plain scalar that happens to end in `>` as a header is harmless, because the lines
    /// it then skips are more indented and belong to the same item either way. Missing a real header
    /// is not harmless, so this errs towards saying yes.
    private func endsWithBlockScalarHeader<S: BidirectionalCollection>(_ significant: S) -> Bool where S.Element == UInt8 {
        var end = significant.endIndex
        while end > significant.startIndex {
            let previous = significant.index(before: end)
            if significant[previous] == Self.space || significant[previous] == Self.tab { end = previous } else { break }
        }
        guard end > significant.startIndex else { return false }

        var cursor = end
        var sawIndicator = false
        while cursor > significant.startIndex {
            let previous = significant.index(before: cursor)
            let byte = significant[previous]
            if byte == Self.pipe || byte == Self.angle { return true }
            let isChomping = byte == Self.dash || byte == Self.plus
            let isDigit = byte >= 0x31 && byte <= 0x39
            guard isChomping || isDigit, !sawIndicator || isChomping != isDigit else { return false }
            sawIndicator = true
            cursor = previous
        }
        return false
    }
}
