import Foundation
import YAMLCamel

public extension YAMLDecoder {

    /// Decodes a value from a gzipped YAML file. Pass the type and the file's url. Pass your own
    /// `YAMLCompression` or `YAMLFileIO` to route inflation or the read through something else.
    ///
    /// The compressed file is read a chunk at a time and checked against `gzipLimits.maxInputBytes`
    /// as it comes in, the same as the streaming reader does, so a compressed file far larger than
    /// the bound is refused without ever being held whole in memory ahead of inflation.
    func decode<T: Decodable>(_ type: T.Type,
                              contentsOfGzipped url: URL,
                              gzipLimits: GzipLimits = .default,
                              compression: YAMLCompression = GzipCompression(),
                              fileIO: YAMLFileIO = LocalFileIO()) throws -> T {
        let compressed = try readCompressed(url, fileIO: fileIO, limit: gzipLimits.maxInputBytes)
        let inflated = try compression.decompress(compressed, limits: gzipLimits)
        return try decode(type, from: inflated)
    }
}

public extension YAMLEncoder {

    /// Encodes a value to gzipped YAML and writes it to a file. Pass the value and the destination
    /// url. Pass your own `YAMLCompression` or `YAMLFileIO` to route compression or the write through
    /// something else.
    func encodeGzipped<T: Encodable>(_ value: T,
                                     to url: URL,
                                     level: Gzip.Level = .default,
                                     compression: YAMLCompression = GzipCompression(),
                                     fileIO: YAMLFileIO = LocalFileIO()) throws {
        let text = try encode(value)
        let compressed = try compression.compress(Data(text.utf8), level: level)
        try fileIO.write(compressed, to: url)
    }
}

/// Reads a compressed file a chunk at a time, refusing as soon as the total crosses `limit` bytes.
///
/// `GzipDecompressor` already checks its output incrementally; this gives the input the same
/// treatment, so a compressed file itself far larger than `gzipLimits.maxInputBytes` is refused
/// before it is ever held whole, rather than the bound only doing its job once inflation starts.
private func readCompressed(_ url: URL, fileIO: YAMLFileIO, limit: Int, chunkSize: Int = 64 * 1024) throws -> Data {
    let handle = try fileIO.openForReading(url)
    defer { handle.close() }
    var data = Data()
    while true {
        let chunk = try handle.read(chunkSize)
        if chunk.isEmpty { return data }
        data.append(chunk)
        guard data.count <= limit else {
            throw GzipError(.inputTooLarge, "Compressed file at \(url.path) is over the \(limit) byte limit.")
        }
    }
}

extension GzipYAMLSequenceReader: YAMLChunkReader {}

public extension YAMLDecoder {

    /// A pull-style reader over a top-level YAML block sequence stored in a gzipped file, decoded a
    /// chunk at a time so neither the compressed file nor the inflated text is ever held whole.
    func gzipFileSequenceReader<Element: Decodable>(
        _ type: Element.Type,
        contentsOf url: URL,
        chunkSize: Int = 64 * 1024,
        gzipLimits: GzipLimits = .default,
        fileIO: YAMLFileIO = LocalFileIO()
    ) throws -> YAMLFileSequenceReader<GzipYAMLSequenceReader<Element>> {
        let handle = try fileIO.openForReading(url)
        let inner = GzipYAMLSequenceReader<Element>(gzipLimits: gzipLimits, yamlLimits: limits)
        return YAMLFileSequenceReader(handle: handle, chunkSize: chunkSize, inner: inner)
    }
}
