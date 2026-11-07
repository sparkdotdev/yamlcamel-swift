import Foundation
import CZlib

private let chunkSize = 64 * 1024

/// Compresses to gzip a chunk at a time.
///
/// Push bytes as they become available and write out what comes back, then call `finish()` once.
/// Neither the input nor the output is ever held whole.
public final class GzipCompressor {
    private var stream = z_stream()
    private var buffer = [UInt8](repeating: 0, count: chunkSize)
    private var open = false
    private var done = false

    /// Creates a compressor. Pass a level to trade speed against size. Throws `GzipError`.
    public init(level: Gzip.Level = .default) throws {
        // 15 window bits plus 16 selects a gzip header and trailer rather than a zlib one.
        let status = deflateInit2_(&stream, level.zlibValue, Z_DEFLATED, 15 + 16, 8,
                                   Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                                   Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw GzipError(status == Z_MEM_ERROR ? .outOfMemory : .internalFailure,
                            "zlib refused to start a compressor (\(status)).")
        }
        open = true
    }

    deinit { if open { deflateEnd(&stream) } }

    /// Compresses a chunk and returns whatever bytes are ready. Returns empty data when zlib is
    /// still buffering. Throws `GzipError`.
    public func push(_ data: Data) throws -> Data {
        guard !done else { throw GzipError(.internalFailure, "Compressor was already finished.") }
        guard !data.isEmpty else { return Data() }
        return try data.withUnsafeBytes { raw -> Data in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return Data() }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(raw.count)
            return try drain(flush: Z_NO_FLUSH)
        }
    }

    /// Flushes what zlib is holding without ending the stream. Use this when a reader is waiting on
    /// bytes rather than on the end of the body. Throws `GzipError`.
    public func flush() throws -> Data {
        guard !done else { throw GzipError(.internalFailure, "Compressor was already finished.") }
        stream.next_in = nil
        stream.avail_in = 0
        return try drain(flush: Z_SYNC_FLUSH)
    }

    /// Ends the stream and returns the last bytes, trailer included. Call this once. Throws
    /// `GzipError`.
    public func finish() throws -> Data {
        guard !done else { throw GzipError(.internalFailure, "Compressor was already finished.") }
        stream.next_in = nil
        stream.avail_in = 0
        let out = try drain(flush: Z_FINISH)
        done = true
        deflateEnd(&stream)
        open = false
        return out
    }

    private func drain(flush: Int32) throws -> Data {
        var output = Data()
        while true {
            var status: Int32 = Z_OK
            var produced = 0
            buffer.withUnsafeMutableBufferPointer { buf in
                stream.next_out = buf.baseAddress
                stream.avail_out = uInt(buf.count)
                status = deflate(&stream, flush)
                produced = buf.count - Int(stream.avail_out)
                if produced > 0 { output.append(buf.baseAddress!, count: produced) }
            }
            switch status {
            case Z_OK, Z_BUF_ERROR:
                break
            case Z_STREAM_END:
                return output
            case Z_MEM_ERROR:
                throw GzipError(.outOfMemory, "zlib ran out of memory while compressing.")
            default:
                throw GzipError(.internalFailure, "zlib reported \(status) while compressing.")
            }
            // More room was needed only if the buffer filled, so stop once it did not.
            if stream.avail_out != 0 {
                if flush == Z_FINISH && status != Z_STREAM_END { continue }
                return output
            }
        }
    }
}

/// Decompresses gzip a chunk at a time, refusing to inflate past a bound.
///
/// The output bound is checked after every block zlib produces, so a body that expands enormously
/// stops at the bound rather than being inflated whole and measured afterwards.
public final class GzipDecompressor {
    private var stream = z_stream()
    private var buffer = [UInt8](repeating: 0, count: chunkSize)
    private var open = false
    private var reachedEnd = false
    private var sawAnyInput = false

    private let limits: GzipLimits

    /// Total decompressed bytes produced so far.
    public private(set) var outputBytes = 0

    /// Total compressed bytes accepted so far.
    public private(set) var inputBytes = 0

    /// Creates a decompressor. Pass your own limits to change what it will inflate.
    public init(limits: GzipLimits = .default) {
        self.limits = limits
    }

    deinit { if open { inflateEnd(&stream) } }

    private func start() throws {
        guard !open else { return }
        // 15 window bits plus 16 accepts a gzip header only, which is what Content-Encoding names.
        let status = inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw GzipError(status == Z_MEM_ERROR ? .outOfMemory : .internalFailure,
                            "zlib refused to start a decompressor (\(status)).")
        }
        open = true
    }

    /// Inflates a chunk and returns whatever bytes came out. Throws `GzipError`, including kind
    /// `outputTooLarge` the moment the output crosses the bound.
    public func push(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        inputBytes += data.count
        guard inputBytes <= limits.maxInputBytes else {
            throw GzipError(.inputTooLarge,
                            "Compressed body is over the \(limits.maxInputBytes) byte limit.")
        }
        sawAnyInput = true
        try start()
        return try data.withUnsafeBytes { raw -> Data in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return Data() }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(raw.count)
            return try drain()
        }
    }

    /// Signals end of input. Throws `GzipError` with kind `truncated` when the stream never reached
    /// its trailer, and returns any bytes still held.
    public func finish() throws -> Data {
        guard sawAnyInput else {
            throw GzipError(.truncated, "No gzip data was pushed before finishing.")
        }
        guard reachedEnd else {
            throw GzipError(.truncated, "Gzip stream ended before its trailer.")
        }
        if open { inflateEnd(&stream); open = false }
        return Data()
    }

    private func drain() throws -> Data {
        var output = Data()
        while stream.avail_in > 0 || !reachedEnd {
            var status: Int32 = Z_OK
            var produced = 0
            var overLimit = false

            buffer.withUnsafeMutableBufferPointer { buf in
                stream.next_out = buf.baseAddress
                stream.avail_out = uInt(buf.count)
                status = inflate(&stream, Z_NO_FLUSH)
                produced = buf.count - Int(stream.avail_out)
                if produced > 0 {
                    // The bound is checked here, between blocks, so inflation stops on the block
                    // that crosses it rather than after the whole body is in memory.
                    if outputBytes + produced > self.limits.maxOutputBytes {
                        overLimit = true
                        return
                    }
                    outputBytes += produced
                    output.append(buf.baseAddress!, count: produced)
                }
            }

            if overLimit {
                throw GzipError(.outputTooLarge,
                                "Decompressed body is over the \(limits.maxOutputBytes) byte limit.")
            }

            switch status {
            case Z_OK:
                break
            case Z_STREAM_END:
                reachedEnd = true
                // A gzip body may hold several members back to back, so keep going if input remains.
                if stream.avail_in > 0 {
                    let reset = inflateReset2(&stream, 15 + 16)
                    guard reset == Z_OK else {
                        throw GzipError(.internalFailure, "zlib reported \(reset) resetting the stream.")
                    }
                    reachedEnd = false
                    continue
                }
                return output
            case Z_BUF_ERROR:
                // zlib needs more input, which the next push will bring.
                return output
            case Z_DATA_ERROR:
                throw GzipError(.corrupt, "Gzip stream is malformed or its trailer disagrees with the data.")
            case Z_MEM_ERROR:
                throw GzipError(.outOfMemory, "zlib ran out of memory while decompressing.")
            case Z_NEED_DICT:
                throw GzipError(.corrupt, "Gzip stream asks for a preset dictionary.")
            default:
                throw GzipError(.internalFailure, "zlib reported \(status) while decompressing.")
            }

            if stream.avail_in == 0 && stream.avail_out != 0 { return output }
        }
        return output
    }
}
