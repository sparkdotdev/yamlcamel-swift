import Foundation

public extension YAMLDecoder {

    /// Decodes a value from a YAML file. Pass the type and the file's url. Pass your own `YAMLFileIO`
    /// to route the read through something other than `FileManager`.
    ///
    /// The file is read a chunk at a time and checked against `limits.maxInputBytes` as it comes in,
    /// so a file far larger than the limit is refused without ever being held whole in memory.
    func decode<T: Decodable>(_ type: T.Type, contentsOf url: URL, fileIO: YAMLFileIO = LocalFileIO()) throws -> T {
        try decode(type, from: try fileIO.read(contentsOf: url, upTo: limits.maxInputBytes))
    }
}

public extension YAMLEncoder {

    /// Encodes a value to YAML and writes it to a file. Pass the value and the destination url. Pass
    /// your own `YAMLFileIO` to route the write through something other than `FileManager`.
    func encode<T: Encodable>(_ value: T, to url: URL, fileIO: YAMLFileIO = LocalFileIO()) throws {
        let text = try encode(value)
        try fileIO.write(Data(text.utf8), to: url)
    }
}
