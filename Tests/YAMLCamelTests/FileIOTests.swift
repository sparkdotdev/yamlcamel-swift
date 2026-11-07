import Foundation
import Testing
@testable import YAMLCamel

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct Word: Codable, Equatable {
    var hu: String
    var en: String
}

/// `ru_maxrss` is a whole-process high water mark, and Swift Testing runs suites concurrently by
/// default, so an RSS-delta test racing against another one in the same process would measure the
/// other test's allocations instead of its own. Shared with `LimitTests.streamingReaderHoldsNoLineTable`
/// so the two never overlap.
let rssMeasurementLock = NSLock()

/// Records every call instead of touching disk, so a test can prove a `fileIO:` argument is actually
/// used rather than the default.
private final class RecordingFileIO: YAMLFileIO, @unchecked Sendable {
    private(set) var readCalls: [URL] = []
    private(set) var writeCalls: [(data: Data, url: URL)] = []
    private(set) var openCalls: [URL] = []
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
        return RecordingFileHandle(data: stubbedData)
    }
}

private final class RecordingFileHandle: YAMLFileHandle {
    private var remaining: Data
    init(data: Data) { remaining = data }

    func read(_ count: Int) throws -> Data {
        let chunk = remaining.prefix(count)
        remaining.removeFirst(chunk.count)
        return Data(chunk)
    }

    func close() {}
}

@Suite("File I/O")
struct FileIOTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("yamlcamel-\(UUID().uuidString).yaml")
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

    @Test("plain YAML round-trips through LocalFileIO to a file on disk")
    func fileRoundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let words = [Word(hu: "ház", en: "house"), Word(hu: "kutya", en: "dog")]
        try YAMLEncoder().encode(words, to: url)
        let read: [Word] = try YAMLDecoder().decode([Word].self, contentsOf: url)
        #expect(read == words)
    }

    @Test("fileSequenceReader streams a large file without holding it whole")
    func fileSequenceReaderStreamsLargeFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Same shape as LimitTests.streamingReaderHoldsNoLineTable: one real item followed by eight
        // megabytes of blank lines, which is what made a held line table visible in the first place.
        let text = "- 1\n" + String(repeating: "\n", count: 8 << 20)
        try Data(text.utf8).write(to: url)

        rssMeasurementLock.lock()
        defer { rssMeasurementLock.unlock() }

        let before = peakResidentMB()
        let reader = try YAMLDecoder().fileSequenceReader(Int.self, contentsOf: url)
        var items = 0
        while try reader.next() != nil { items += 1 }

        #expect(items == 1)
        // Darwin-only for the same reason LimitTests.streamingReaderHoldsNoLineTable is: glibc's
        // allocator retains far more resident memory for this pattern, so the budget is not portable
        // without per-platform tuning this suite has no grounds to guess at.
        //
        // The budget carries more headroom than that test's own 300 MB: this reader's true cost here
        // is under 60 MB, and the rest is margin for whatever else Swift Testing's default parallel
        // scheduling happens to run at the same time, since ru_maxrss is a whole-process high water
        // mark that the lock above only shields against this file's own other RSS-delta test.
        #if canImport(Darwin)
        #expect(peakResidentMB() - before < 500)
        #endif
    }

    @Test("decode(contentsOf:) refuses an oversized file without holding it whole in memory first")
    func decodeRefusesOversizedFileWithoutBufferingIt() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Far larger than the limit below, so a version that read the whole file before checking its
        // size would show up as a multi-ten-megabyte jump in resident memory.
        let text = String(repeating: "x", count: 32 << 20)
        try Data(text.utf8).write(to: url)

        var limits = YAMLLimits.default
        limits.maxInputBytes = 1 << 20
        let decoder = YAMLDecoder(limits: limits)

        rssMeasurementLock.lock()
        defer { rssMeasurementLock.unlock() }
        let before = peakResidentMB()

        let error = #expect(throws: YAMLParseError.self) {
            let _: String = try decoder.decode(String.self, contentsOf: url)
        }
        #expect(error?.kind == .inputTooLarge)

        // Darwin-only for the same reason fileSequenceReaderStreamsLargeFile is. The margin is
        // generous background-noise headroom; a version that reads the whole 32 MB file before
        // checking its size would blow well past it.
        #if canImport(Darwin)
        #expect(peakResidentMB() - before < 20)
        #endif
    }

    @Test("decode(contentsOf:fileIO:) uses the injected YAMLFileIO instead of touching disk")
    func decodeInjectsFileIO() throws {
        let sample = "- hu: ház\n  en: house\n"
        let fileIO = RecordingFileIO(stubbedData: Data(sample.utf8))
        let url = URL(fileURLWithPath: "/nonexistent/words.yaml")

        let words: [Word] = try YAMLDecoder().decode([Word].self, contentsOf: url, fileIO: fileIO)
        #expect(words == [Word(hu: "ház", en: "house")])
        // Goes through openForReading rather than the one-shot read(contentsOf:), so the size bound
        // can be checked as each chunk comes in instead of after the whole file is already in memory.
        #expect(fileIO.openCalls == [url])
    }

    @Test("encode(to:fileIO:) uses the injected YAMLFileIO instead of touching disk")
    func encodeInjectsFileIO() throws {
        let fileIO = RecordingFileIO()
        let url = URL(fileURLWithPath: "/nonexistent/out.yaml")

        try YAMLEncoder().encode([Word(hu: "kutya", en: "dog")], to: url, fileIO: fileIO)
        #expect(fileIO.writeCalls.count == 1)
        #expect(fileIO.writeCalls.first?.url == url)
        let written = fileIO.writeCalls.first.map { String(decoding: $0.data, as: UTF8.self) }
        #expect(try YAMLDecoder().decode([Word].self, from: written ?? "") == [Word(hu: "kutya", en: "dog")])
    }

    @Test("fileSequenceReader uses the injected YAMLFileIO's handle instead of opening a real file")
    func fileSequenceReaderInjectsFileIO() throws {
        let text = "- 1\n- 2\n- 3\n"
        let fileIO = RecordingFileIO(stubbedData: Data(text.utf8))
        let url = URL(fileURLWithPath: "/nonexistent/seq.yaml")

        let reader = try YAMLDecoder().fileSequenceReader(Int.self, contentsOf: url, fileIO: fileIO)
        var out: [Int] = []
        while let n = try reader.next() { out.append(n) }
        #expect(out == [1, 2, 3])
        #expect(fileIO.openCalls == [url])
    }

    @Test("a missing file reports the path rather than an opaque nil")
    func missingFileReportsPath() throws {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).yaml")
        let error = #expect(throws: YAMLFileIOError.self) {
            _ = try LocalFileIO().openForReading(url)
        }
        #expect(error?.path == url.path)
    }

    @Test("data read from a file over the byte bound is refused before it is turned into a String")
    func decodeDataChecksSizeBeforeConverting() throws {
        // `decode(_:from: Data)` used to build the whole `String` before checking its length against
        // the byte bound, so a `YAMLFileIO` (or any other source handing over `Data`, a gzipped file
        // or an HTTP body among them) that returns more than the bound paid for that conversion in
        // full before being refused. Fifty megabytes of 'a' bytes, well past the default bound,
        // proves the refusal now comes first: the RSS delta stays far under the buffer's own size,
        // which it would not if the whole thing had been walked and copied into a `String` first.
        let stubbedSize = 50 << 20
        let fileIO = RecordingFileIO(stubbedData: Data(repeating: 0x61, count: stubbedSize))
        let url = URL(fileURLWithPath: "/nonexistent/big.yaml")

        rssMeasurementLock.lock()
        defer { rssMeasurementLock.unlock() }
        let before = peakResidentMB()
        let error = #expect(throws: YAMLParseError.self) {
            let _: [Int] = try YAMLDecoder().decode([Int].self, contentsOf: url, fileIO: fileIO)
        }
        #expect(error?.kind == .inputTooLarge)
        #if canImport(Darwin)
        #expect(peakResidentMB() - before < 20)
        #endif
    }
}
