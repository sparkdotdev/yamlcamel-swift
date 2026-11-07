import Foundation
import Testing
@testable import YAMLCamelGzip
import YAMLCamel

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct Word: Codable, Equatable {
    var hu: String
    var en: String
}

/// Records every call instead of touching disk, so a test can prove a `fileIO:` argument is actually
/// used rather than the default.
private final class RecordingFileIO: YAMLFileIO, @unchecked Sendable {
    private(set) var readCalls: [URL] = []
    private(set) var writeCalls: [(data: Data, url: URL)] = []
    private(set) var openCalls: [URL] = []
    /// Total bytes handed back across every chunk `openForReading`'s handle has served, so a test
    /// can prove a reader stopped pulling chunks early rather than draining the whole stub.
    private(set) var bytesServed = 0
    var stubbedData: Data

    init(stubbedData: Data = Data()) { self.stubbedData = stubbedData }

    func read(contentsOf url: URL) throws -> Data {
        readCalls.append(url)
        return stubbedData
    }

    func write(_ data: Data, to url: URL) throws {
        writeCalls.append((data, url))
    }

    func openForReading(_ url: URL) throws -> YAMLFileHandle {
        openCalls.append(url)
        return RecordingFileHandle(data: stubbedData) { [weak self] n in self?.bytesServed += n }
    }
}

private final class RecordingFileHandle: YAMLFileHandle {
    private var remaining: Data
    private let onRead: ((Int) -> Void)?
    init(data: Data, onRead: ((Int) -> Void)? = nil) {
        remaining = data
        self.onRead = onRead
    }

    func read(_ count: Int) throws -> Data {
        let chunk = remaining.prefix(count)
        remaining.removeFirst(chunk.count)
        onRead?(chunk.count)
        return Data(chunk)
    }

    func close() {}
}

/// Delegates to the real `Gzip` calls while recording every one, so a test can prove a
/// `compression:` argument is actually used rather than the default.
private final class RecordingCompression: YAMLCompression, @unchecked Sendable {
    private(set) var compressCalls = 0
    private(set) var decompressCalls = 0

    func compress(_ data: Data, level: Gzip.Level) throws -> Data {
        compressCalls += 1
        return try Gzip.compress(data, level: level)
    }

    func decompress(_ data: Data, limits: GzipLimits) throws -> Data {
        decompressCalls += 1
        return try Gzip.decompress(data, limits: limits)
    }
}

@Suite("Gzipped file I/O")
struct GzipFileIOTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("yamlcamel-gzip-\(UUID().uuidString).yaml.gz")
    }

    /// Peak resident memory in megabytes, as the kernel reports it for this process. Mirrors
    /// `LimitTests.peakResidentMB`, which explains why it only ever rises.
    private func peakResidentMB() -> Double {
        var usage = rusage()
        #if canImport(Darwin)
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / (1024 * 1024)
        #else
        getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &usage)
        return Double(usage.ru_maxrss) / 1024
        #endif
    }

    @Test("gzipped YAML round-trips through LocalFileIO to a file on disk")
    func gzipFileRoundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let words = [Word(hu: "ház", en: "house"), Word(hu: "kutya", en: "dog")]
        try YAMLEncoder().encodeGzipped(words, to: url)
        #expect(try Gzip.hasGzipMagic(Data(contentsOf: url)))
        let read: [Word] = try YAMLDecoder().decode([Word].self, contentsOfGzipped: url)
        #expect(read == words)
    }

    @Test("gzipFileSequenceReader streams a large compressed file without holding it whole")
    func gzipFileSequenceReaderStreamsLargeFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Same shape as FileIOTests.fileSequenceReaderStreamsLargeFile: one real item followed by
        // eight megabytes of blank lines, compressed so the reader has to inflate as it goes too.
        let text = "- 1\n" + String(repeating: "\n", count: 8 << 20)
        let compressed = try Gzip.compress(Data(text.utf8))
        try compressed.write(to: url)

        let before = peakResidentMB()
        let reader = try YAMLDecoder().gzipFileSequenceReader(Int.self, contentsOf: url)
        var items = 0
        while try reader.next() != nil { items += 1 }

        #expect(items == 1)
        // Darwin-only for the same reason LimitTests.streamingReaderHoldsNoLineTable is.
        #if canImport(Darwin)
        #expect(peakResidentMB() - before < 300)
        #endif
    }

    @Test("decode(contentsOfGzipped:) refuses an oversized compressed file without buffering it whole")
    func decodeRefusesOversizedCompressedFile() throws {
        // The bytes never have to be valid gzip: the bound this proves is checked while the file is
        // still being read, before compression ever sees a byte of it, so a stub is enough to show
        // whether the reader gave up early or drained the whole thing first.
        let stubSize = 24 << 20
        let fileIO = RecordingFileIO(stubbedData: Data(repeating: 0x1F, count: stubSize))
        let url = URL(fileURLWithPath: "/nonexistent/huge.yaml.gz")

        var gzipLimits = GzipLimits.default
        gzipLimits.maxInputBytes = 1 << 20

        let error = #expect(throws: GzipError.self) {
            let _: [Word] = try YAMLDecoder().decode([Word].self, contentsOfGzipped: url,
                                                      gzipLimits: gzipLimits, fileIO: fileIO)
        }
        #expect(error?.kind == .inputTooLarge)

        // Goes through openForReading rather than the one-shot read(contentsOf:), so the bound can
        // be checked as each chunk comes in instead of after the whole stub is already in hand.
        #expect(fileIO.readCalls.isEmpty, "the one-shot read(contentsOf:) should never be called")
        #expect(fileIO.openCalls == [url])
        // Within the chunked path, the reader gives up within a few chunks past the one megabyte
        // bound rather than draining the whole stub first.
        #expect(fileIO.bytesServed < stubSize / 4,
               "read \(fileIO.bytesServed) of \(stubSize) stub bytes; a bounded read should stop far short of that")
    }

    @Test("decode(contentsOfGzipped:fileIO:) uses the injected YAMLFileIO instead of touching disk")
    func decodeInjectsFileIO() throws {
        let compressed = try Gzip.compress(Data("- hu: ház\n  en: house\n".utf8))
        let fileIO = RecordingFileIO(stubbedData: compressed)
        let url = URL(fileURLWithPath: "/nonexistent/words.yaml.gz")

        let words: [Word] = try YAMLDecoder().decode([Word].self, contentsOfGzipped: url, fileIO: fileIO)
        #expect(words == [Word(hu: "ház", en: "house")])
        // Goes through openForReading rather than the one-shot read(contentsOf:), so the compressed
        // file's own size bound can be checked as each chunk comes in, ahead of inflation.
        #expect(fileIO.openCalls == [url])
    }

    @Test("encodeGzipped(to:fileIO:) uses the injected YAMLFileIO instead of touching disk")
    func encodeInjectsFileIO() throws {
        let fileIO = RecordingFileIO()
        let url = URL(fileURLWithPath: "/nonexistent/out.yaml.gz")

        try YAMLEncoder().encodeGzipped([Word(hu: "kutya", en: "dog")], to: url, fileIO: fileIO)
        #expect(fileIO.writeCalls.count == 1)
        #expect(fileIO.writeCalls.first?.url == url)
        let written = fileIO.writeCalls.first?.data ?? Data()
        #expect(Gzip.hasGzipMagic(written))
        #expect(try YAMLDecoder().decode([Word].self, fromGzipped: written) == [Word(hu: "kutya", en: "dog")])
    }

    @Test("gzipFileSequenceReader uses the injected YAMLFileIO's handle instead of opening a real file")
    func gzipFileSequenceReaderInjectsFileIO() throws {
        let compressed = try Gzip.compress(Data("- 1\n- 2\n- 3\n".utf8))
        let fileIO = RecordingFileIO(stubbedData: compressed)
        let url = URL(fileURLWithPath: "/nonexistent/seq.yaml.gz")

        let reader = try YAMLDecoder().gzipFileSequenceReader(Int.self, contentsOf: url, fileIO: fileIO)
        var out: [Int] = []
        while let n = try reader.next() { out.append(n) }
        #expect(out == [1, 2, 3])
        #expect(fileIO.openCalls == [url])
    }

    @Test("decode(contentsOfGzipped:compression:) uses the injected YAMLCompression instead of the default")
    func decodeInjectsCompression() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Gzip.compress(Data("- hu: ház\n  en: house\n".utf8)).write(to: url)

        let compression = RecordingCompression()
        let words: [Word] = try YAMLDecoder().decode([Word].self, contentsOfGzipped: url, compression: compression)
        #expect(words == [Word(hu: "ház", en: "house")])
        #expect(compression.decompressCalls == 1)
    }

    @Test("encodeGzipped(to:compression:) uses the injected YAMLCompression instead of the default")
    func encodeInjectsCompression() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let compression = RecordingCompression()
        try YAMLEncoder().encodeGzipped([Word(hu: "kutya", en: "dog")], to: url, compression: compression)
        #expect(compression.compressCalls == 1)
        let read: [Word] = try YAMLDecoder().decode([Word].self, contentsOfGzipped: url)
        #expect(read == [Word(hu: "kutya", en: "dog")])
    }
}
