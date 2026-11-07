import Foundation
import Testing
@testable import YAMLCamelGzip
import YAMLCamel

@Suite("Gzip")
struct GzipTests {

    private func sample(_ size: Int) -> Data {
        var text = ""
        var k = 0
        while text.utf8.count < size { text += "line \(k) with some repeated content\n"; k += 1 }
        return Data(text.utf8)
    }

    @Test("a round trip through compress and decompress gives the original bytes",
          arguments: [0, 1, 10, 1_000, 100_000, 1_000_000])
    func oneShotRoundTrip(size: Int) throws {
        let original = size == 0 ? Data() : sample(size)
        let compressed = try Gzip.compress(original)
        #expect(Gzip.hasGzipMagic(compressed))
        #expect(try Gzip.decompress(compressed) == original)
    }

    @Test("every level round trips")
    func levelsRoundTrip() throws {
        let original = sample(50_000)
        for level in [Gzip.Level.none, .fastest, .default, .best, .custom(6)] {
            #expect(try Gzip.decompress(try Gzip.compress(original, level: level)) == original)
        }
    }

    @Test("compressing actually compresses repetitive input")
    func compressionHelps() throws {
        let original = Data(String(repeating: "abcabcabc", count: 20_000).utf8)
        let compressed = try Gzip.compress(original)
        #expect(compressed.count < original.count / 20)
    }

    // MARK: - Streaming

    @Test("streaming compression matches the one shot result on the wire",
          arguments: [1, 7, 1_000, 65_536])
    func streamingCompressionRoundTrips(chunk: Int) throws {
        let original = sample(200_000)
        let compressor = try GzipCompressor()
        var compressed = Data()
        var offset = 0
        while offset < original.count {
            let end = min(offset + chunk, original.count)
            compressed.append(try compressor.push(original.subdata(in: offset ..< end)))
            offset = end
        }
        compressed.append(try compressor.finish())
        #expect(try Gzip.decompress(compressed) == original)
    }

    @Test("streaming decompression gives the same bytes however the input is chunked",
          arguments: [1, 3, 512, 65_536])
    func streamingDecompressionRoundTrips(chunk: Int) throws {
        let original = sample(200_000)
        let compressed = try Gzip.compress(original)
        let decompressor = GzipDecompressor()
        var out = Data()
        var offset = 0
        while offset < compressed.count {
            let end = min(offset + chunk, compressed.count)
            out.append(try decompressor.push(compressed.subdata(in: offset ..< end)))
            offset = end
        }
        out.append(try decompressor.finish())
        #expect(out == original)
    }

    @Test("the streaming decompressor gives bytes back before the body ends")
    func decompressionIsIncremental() throws {
        // Output from the first eighth of the input is what separates streaming from buffering the
        // whole body and inflating it at the end.
        let original = sample(2_000_000)
        let compressed = try Gzip.compress(original)
        let decompressor = GzipDecompressor()
        let firstChunk = compressed.prefix(compressed.count / 8)
        let produced = try decompressor.push(Data(firstChunk))
        #expect(produced.count > 0)
        #expect(produced.count < original.count)
    }

    @Test("the bound stops a bomb long before the whole body is inflated")
    func boundAppliesDuringInflation() throws {
        // A gigabyte of zeroes compresses to about a megabyte. With a one megabyte output bound the
        // decompressor must stop near the bound rather than anywhere near a gigabyte.
        let bomb = try Gzip.compress(Data(repeating: 0, count: 1 << 30), level: .best)
        var limits = GzipLimits.default
        limits.maxOutputBytes = 1 << 20
        let decompressor = GzipDecompressor(limits: limits)
        var error: GzipError?
        do { _ = try decompressor.push(bomb) } catch let e as GzipError { error = e }
        #expect(error?.kind == .outputTooLarge)
        #expect(decompressor.outputBytes <= limits.maxOutputBytes)
    }

    @Test("several gzip members back to back read as one body")
    func concatenatedMembers() throws {
        let first = Data("one\n".utf8)
        let second = Data("two\n".utf8)
        var joined = try Gzip.compress(first)
        joined.append(try Gzip.compress(second))
        #expect(try Gzip.decompress(joined) == first + second)
    }

    // MARK: - Hostile input

    @Test("a bomb stops at the output bound rather than being inflated whole")
    func decompressionBomb() throws {
        let bomb = try Gzip.compress(Data(repeating: 0x41, count: 64 << 20), level: .best)
        #expect(bomb.count < 200_000, "the bomb should be small on the wire")

        var limits = GzipLimits.default
        limits.maxOutputBytes = 1 << 20
        let decompressor = GzipDecompressor(limits: limits)
        var error: GzipError?
        do {
            _ = try decompressor.push(bomb)
            _ = try decompressor.finish()
        } catch let e as GzipError {
            error = e
        }
        #expect(error?.kind == .outputTooLarge)
        #expect(error?.isLimit == true)
        // Inflation stopped at the bound rather than running to the end.
        #expect(decompressor.outputBytes <= limits.maxOutputBytes)
    }

    @Test("a compressed body larger than the input bound is refused")
    func inputTooLarge() throws {
        let compressed = try Gzip.compress(sample(1_000_000))
        var limits = GzipLimits.default
        limits.maxInputBytes = 100
        var error: GzipError?
        do { _ = try GzipDecompressor(limits: limits).push(compressed) }
        catch let e as GzipError { error = e }
        #expect(error?.kind == .inputTooLarge)
    }

    @Test("a truncated stream is reported as truncated rather than as a short body")
    func truncatedStream() throws {
        let compressed = try Gzip.compress(sample(100_000))
        let cut = compressed.prefix(compressed.count / 2)
        var error: GzipError?
        do { _ = try Gzip.decompress(Data(cut)) }
        catch let e as GzipError { error = e }
        #expect(error?.kind == .truncated)
    }

    @Test("a trailer that disagrees with the data is reported as corrupt")
    func corruptTrailer() throws {
        var compressed = try Gzip.compress(sample(10_000))
        // The last eight bytes are the CRC and the declared length.
        compressed[compressed.index(compressed.endIndex, offsetBy: -5)] ^= 0xFF
        var error: GzipError?
        do { _ = try Gzip.decompress(compressed) }
        catch let e as GzipError { error = e }
        #expect(error?.kind == .corrupt)
    }

    @Test("a declared length that disagrees with the data is reported as corrupt")
    func corruptDeclaredLength() throws {
        var compressed = try Gzip.compress(sample(10_000))
        compressed[compressed.index(compressed.endIndex, offsetBy: -1)] ^= 0xFF
        var error: GzipError?
        do { _ = try Gzip.decompress(compressed) }
        catch let e as GzipError { error = e }
        #expect(error?.kind == .corrupt)
    }

    @Test("bytes that are not gzip at all are reported as corrupt")
    func notGzipAtAll() throws {
        var error: GzipError?
        do { _ = try Gzip.decompress(Data("a: 1\nb: 2\n".utf8)) }
        catch let e as GzipError { error = e }
        #expect(error?.kind == .corrupt)
        #expect(Gzip.hasGzipMagic(Data("a: 1\n".utf8)) == false)
    }

    @Test("an empty body is reported as truncated rather than as an empty result")
    func emptyBody() throws {
        var error: GzipError?
        do { _ = try Gzip.decompress(Data()) }
        catch let e as GzipError { error = e }
        #expect(error?.kind == .truncated)
    }

    @Test("a corrupt payload with an intact header is reported as corrupt")
    func corruptPayload() throws {
        var compressed = try Gzip.compress(sample(10_000))
        for offset in 20 ..< 40 { compressed[compressed.startIndex + offset] ^= 0xAA }
        var error: GzipError?
        do { _ = try Gzip.decompress(compressed) }
        catch let e as GzipError { error = e }
        #expect(error?.kind == .corrupt || error?.kind == .truncated)
    }

    @Test("arbitrary bytes produce a gzip error and never a crash")
    func arbitraryBytesNeverCrash() throws {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
        for _ in 0 ..< 5_000 {
            var bytes = Data([0x1F, 0x8B])
            for _ in 0 ..< 60 { bytes.append(next()) }
            do { _ = try Gzip.decompress(bytes) }
            catch is GzipError { continue }
            catch { Issue.record("unexpected error type \(type(of: error))"); return }
        }
    }
}
