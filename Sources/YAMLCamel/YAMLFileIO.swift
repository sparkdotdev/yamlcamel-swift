import Foundation

/// A file could not be read or opened. `FileHandle(forReadingAtPath:)` returning nil cannot tell a
/// missing file from one that exists but cannot be opened, so this carries only the path.
public struct YAMLFileIOError: Error, Equatable, CustomStringConvertible {
    public let path: String

    public init(path: String) { self.path = path }

    public var description: String { "Could not read or open the file at \(path)." }
}

/// File access a caller can substitute, so a consumer that already routes I/O through its own layer
/// is not forced through `FileManager` and `FileHandle` directly.
public protocol YAMLFileIO: Sendable {
    func read(contentsOf url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func openForReading(_ url: URL) throws -> YAMLFileHandle
}

/// An open file, read a chunk at a time.
public protocol YAMLFileHandle: AnyObject {
    /// Reads up to `count` bytes. Returns empty `Data` at end of file.
    func read(_ count: Int) throws -> Data
    func close()
}

/// The default `YAMLFileIO`, backed by `Data` and `FileHandle`.
public struct LocalFileIO: YAMLFileIO {
    public init() {}

    public func read(contentsOf url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    public func openForReading(_ url: URL) throws -> YAMLFileHandle {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw YAMLFileIOError(path: url.path)
        }
        return LocalFileHandle(handle)
    }
}

/// Wraps `FileHandle`. Uses `readData(ofLength:)` rather than the throwing `read(upToCount:)`, which
/// needs macOS 10.15.4 and iOS 13.4, past the floor `Package.swift` declares.
private final class LocalFileHandle: YAMLFileHandle {
    private let handle: FileHandle

    init(_ handle: FileHandle) { self.handle = handle }

    func read(_ count: Int) throws -> Data { handle.readData(ofLength: count) }
    func close() { handle.closeFile() }
}

public extension YAMLFileIO {

    /// Reads a file a chunk at a time, refusing as soon as the total crosses `limit` bytes rather
    /// than after the whole file already sits in memory.
    ///
    /// `read(contentsOf:)` alone cannot do this: it hands back the whole file in one call, so a
    /// limit applied to what it returns has already paid for the memory it exists to cap. Going
    /// through `openForReading` instead means a file many times the limit is refused for the cost
    /// of a few chunks, the same way the streaming readers already refuse an oversized push.
    func read(contentsOf url: URL, upTo limit: Int, chunkSize: Int = 64 * 1024) throws -> Data {
        let handle = try openForReading(url)
        defer { handle.close() }
        var data = Data()
        while true {
            let chunk = try handle.read(chunkSize)
            if chunk.isEmpty { return data }
            data.append(chunk)
            guard data.count <= limit else {
                throw YAMLParseError("File at \(url.path) is over the \(limit) byte limit.",
                                     kind: .inputTooLarge)
            }
        }
    }
}
