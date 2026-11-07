import Foundation
import YAMLCamel

#if os(Linux)
/// libFuzzer entry point, compiled by the CI workflow rather than by the package manifest.
///
/// It sits outside `Sources` because libFuzzer has to own `main` and the unsafe build flags it needs
/// would stop this package being usable as a dependency. macOS has no libFuzzer for arm64, so only
/// this entry point is Linux-only and the checks it calls take bytes anything can hand them.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOneInput(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    checkOneInput(Array(UnsafeRawBufferPointer(start: start, count: count)))
    return 0
}
#endif

/// Runs every property this harness asserts over one input, trapping on the first disagreement.
func checkOneInput(_ bytes: [UInt8]) {
    let chunked = checkByteReaderChunking(bytes)
    guard let text = String(bytes: bytes, encoding: .utf8) else {
        checkInvalidUTF8(bytes)
        return
    }
    checkEmitRoundTrip(text)
    checkStreamingReaders(bytes, text, chunked: chunked)
}

// MARK: - parse, emit, parse again

private func checkEmitRoundTrip(_ text: String) {
    guard let documents = try? YAMLParser.parseStream(text) else { return }

    for document in documents {
        // Emitting expands what aliases share, so a few hundred bytes can become tens of megabytes
        // and seconds of work. The round trip exercises the same emitter paths on a small document,
        // and skipping the huge ones keeps the fuzzer covering ground instead of stringifying.
        guard document.shape.nodes <= 20_000 else { continue }

        guard let emitted = try? YAML.emit(document, limits: .permissive) else { continue }
        // Re-parsed on permissive limits because aliases let a small document hold more nodes than
        // its emitted form fits in the default input bound. That arithmetic is its own property,
        // asserted in the limit tests, and it is not what this harness is looking for.
        guard let reparsed = try? YAMLParser.parse(emitted, limits: .permissive) else {
            fatalError("Emitted text does not parse: \(emitted)")
        }
        // Compared as text rather than as values, because a document holding a NaN is never equal
        // to itself and that would report every `.nan` as a round trip failure.
        guard let again = try? YAML.emit(reparsed, limits: .permissive) else { continue }
        if again != emitted {
            fatalError("Round trip changed the value: \(emitted) became \(again)")
        }
    }
}

// MARK: - streaming readers

/// An element of whatever shape the input turns out to hold, so the readers can be pointed at input
/// nobody wrote a type for.
///
/// Both sides of every comparison decode through this, so a coercion it makes, an integral double
/// read back as an integer for instance, lands on both sides and cancels out.
private struct FuzzElement: Decodable {
    let value: YAMLValue

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: AnyKey.self) {
            var members: [YAMLValue.Member] = []
            for key in keyed.allKeys {
                members.append(.init(key: key.stringValue,
                                     value: try keyed.decode(FuzzElement.self, forKey: key).value))
            }
            value = .object(members)
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var items: [YAMLValue] = []
            while !unkeyed.isAtEnd { items.append(try unkeyed.decode(FuzzElement.self).value) }
            value = .array(items)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { value = .null; return }
        if let flag = try? single.decode(Bool.self) { value = .bool(flag); return }
        if let whole = try? single.decode(Int.self) { value = .int(whole); return }
        if let number = try? single.decode(Double.self) { value = .double(number); return }
        value = .string(try single.decode(String.self))
    }
}

/// Raw bytes still exercise the byte API even when they have no valid String equivalent.
private func checkByteReaderChunking(_ bytes: [UInt8]) -> Result<[YAMLValue], Error> {
    // The input picks the chunk size, so the fuzzer moves the push boundaries with the same
    // mutations it is already making. Sizes start at 1, which puts a boundary at every byte.
    let chunk = 1 + bytes.count % 32
    let chunked = byteReadResult(bytes, chunk: chunk)
    let atOnce = byteReadResult(bytes, chunk: max(1, bytes.count))

    // Where a chunk ends is transport, so it cannot decide what the reader produces.
    switch (chunked, atOnce) {
    case (.success(let inPieces), .success(let inOne)):
        if !sameElements(inPieces, inOne) {
            fatalError("Pushing in chunks of \(chunk) read \(inPieces) where one push read \(inOne)")
        }
    case (.failure, .failure):
        // Which elements arrive before a failure does depend on the boundaries, since a push that
        // throws drops the ones it had already collected, so only the failure itself is compared.
        break
    default:
        fatalError("Pushing in chunks of \(chunk) changed whether the byte reader accepted \(bytes.count) bytes")
    }

    return chunked
}

private func byteReadResult(_ bytes: [UInt8], chunk: Int) -> Result<[YAMLValue], Error> {
    do { return .success(try readInChunks(bytes, chunk: chunk)) }
    catch let error as YAMLParseError { return .failure(error) }
    catch let error as DecodingError { return .failure(error) }
    catch { fatalError("The byte reader leaked an unexpected error: \(error)") }
}

/// Invalid UTF-8 is not repaired into a different document for cross-API comparisons. It still
/// exercises whole and streaming byte entry points, including bounds checked before decoding.
private func checkInvalidUTF8(_ bytes: [UInt8]) {
    let data = Data(bytes)
    let expected: YAMLParseError.Kind = bytes.count > YAMLLimits.default.maxInputBytes ? .inputTooLarge : .syntax
    expectParseError(expected) { try YAMLDecoder().decode(FuzzElement.self, from: data) }

    var bounded = YAMLLimits.default
    bounded.maxInputBytes = max(0, bytes.count - 1)
    expectParseError(.inputTooLarge) { try YAMLDecoder(limits: bounded).decode(FuzzElement.self, from: data) }
    expectParseError(.inputTooLarge) { try readInChunks(bytes, chunk: max(1, bytes.count), limits: bounded) }
}

private func expectParseError<Value>(_ kind: YAMLParseError.Kind, _ body: () throws -> Value) {
    do {
        _ = try body()
        fatalError("A byte input that should fail with \(kind) was accepted")
    } catch let error as YAMLParseError {
        if error.kind != kind { fatalError("Expected byte input failure \(kind), received \(error.kind)") }
    } catch {
        fatalError("A byte input leaked an unexpected error: \(error)")
    }
}

private func checkStreamingReaders(_ bytes: [UInt8], _ text: String,
                                   chunked: Result<[YAMLValue], Error>) {
    // Comparing against the whole decode needs input a reader is for: one document holding a block
    // sequence, no carriage return, since the two readers cut lines on it differently, and no alias,
    // since it can name an anchor from an item the reader has already gone past.
    guard !bytes.contains(0x0D), !text.contains("*"), opensBlockSequence(text) else { return }
    guard let whole = try? YAMLDecoder().decode([FuzzElement].self, from: text).map(\.value) else { return }

    guard case .success(let streamed) = chunked else {
        fatalError("The byte reader refused a block sequence that decodes whole: \(text)")
    }
    let fromText: [YAMLValue]
    do { fromText = try readWholeText(text) }
    catch { fatalError("The string reader refused a block sequence that decodes whole: \(text)") }

    // Same bound as the round trip above, since comparing elements means emitting them.
    guard YAMLValue.array(whole).shape.nodes <= 20_000 else { return }
    // A reader finds boundaries a line at a time, so it can still read two items as one and lose
    // what the second held. What is asserted is that every element a reader does produce is one the
    // whole decode produced, in the same order, rather than one for one.
    if !isSubsequence(streamed, of: whole) {
        fatalError("The byte reader read \(streamed) which is not in order in \(whole): \(text)")
    }
    if !isSubsequence(fromText, of: whole) {
        fatalError("The string reader read \(fromText) which is not in order in \(whole): \(text)")
    }
}

/// Pushes the input at the given chunk size and returns everything the reader emitted.
private func readInChunks(_ bytes: [UInt8], chunk: Int, limits: YAMLLimits = .default) throws -> [YAMLValue] {
    let reader = YAMLByteSequenceReader<FuzzElement>(limits: limits)
    var out: [YAMLValue] = []
    var offset = 0
    while offset < bytes.count {
        let end = min(offset + chunk, bytes.count)
        out += try reader.push(Array(bytes[offset ..< end])).map(\.value)
        offset = end
    }
    return try out + reader.finish().map(\.value)
}

/// Pulls every element through the reader that takes the document as text.
private func readWholeText(_ text: String) throws -> [YAMLValue] {
    let reader = try YAMLDecoder().sequenceReader(FuzzElement.self, from: text)
    var out: [YAMLValue] = []
    while let element = try reader.next() { out.append(element.value) }
    return out
}

/// True when the first line carrying anything opens a block sequence, which is all a reader takes.
private func opensBlockSequence(_ text: String) -> Bool {
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let content = line.drop(while: { $0 == " " })
        if content.isEmpty || content.first == "#" { continue }
        if content == "---" || content.hasPrefix("--- ") { continue }
        return content == "-" || content.hasPrefix("- ") || content.hasPrefix("-\t")
    }
    return false
}

/// Compares two element lists as emitted text, for the reason the round trip check does it.
private func sameElements(_ left: [YAMLValue], _ right: [YAMLValue]) -> Bool {
    guard left.count == right.count else { return false }
    let a = YAMLValue.array(left), b = YAMLValue.array(right)
    guard a.shape.nodes <= 20_000, b.shape.nodes <= 20_000 else { return true }
    return emit(a) == emit(b)
}

/// True when every element of `part` appears in `whole` in the same order.
private func isSubsequence(_ part: [YAMLValue], of whole: [YAMLValue]) -> Bool {
    var index = whole.startIndex
    for element in part {
        let wanted = emit(element)
        while index < whole.endIndex, emit(whole[index]) != wanted { index += 1 }
        guard index < whole.endIndex else { return false }
        index += 1
    }
    return true
}

private func emit(_ value: YAMLValue) -> String? {
    try? YAML.emit(value, limits: .permissive)
}
