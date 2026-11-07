/// Validates only the remainder of a recognized document-end marker's line. The streaming readers
/// deliberately stop before later documents, but content on this same line cannot be discarded.
enum YAMLDocumentEndSuffix {
    static func validate<Bytes: Collection>(_ lineBytes: Bytes, line: Int = 0) throws
        where Bytes.Element == UInt8 {
        let suffix = lineBytes.dropFirst(3).drop(while: { $0 == 0x20 || $0 == 0x09 })
        guard suffix.isEmpty || suffix.first == 0x23 else {
            throw YAMLParseError("Only whitespace or a comment may follow a document-end marker.",
                                 line: line, kind: .syntax)
        }
    }
}
