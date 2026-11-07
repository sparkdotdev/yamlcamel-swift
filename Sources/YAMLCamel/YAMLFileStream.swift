import Foundation

/// The shape a push-fed streaming reader needs to back a pull-style file reader: bytes go in,
/// decoded elements come out, and `skip` advances without decoding. `YAMLByteSequenceReader` already
/// has exactly this shape.
public protocol YAMLChunkReader: AnyObject {
    associatedtype Element
    func push(_ data: Data) throws -> [Element]
    func finish() throws -> [Element]
    func skip(_ n: Int)
}

extension YAMLByteSequenceReader: YAMLChunkReader {}

/// Turns a push-fed `YAMLChunkReader` into a pull-style reader over a file, the same shape as
/// `YAMLSequenceReader.next()`. Reads one chunk at a time so a large file is never held whole.
public final class YAMLFileSequenceReader<Inner: YAMLChunkReader> {
    private let handle: YAMLFileHandle
    private let chunkSize: Int
    private let inner: Inner
    // Index-tracked rather than `removeFirst()`, which would shift the whole array on every element.
    private var pending: [Inner.Element] = []
    private var pendingIndex = 0
    private var finished = false

    public init(handle: YAMLFileHandle, chunkSize: Int, inner: Inner) {
        self.handle = handle
        self.chunkSize = chunkSize
        self.inner = inner
    }

    deinit { if !finished { handle.close() } }

    /// Closes the underlying file early and discards any buffered elements.
    public func close() {
        if !finished { handle.close() }
        finished = true
        pending.removeAll()
        pendingIndex = 0
    }

    /// Skips buffered elements first, then skips later elements as they arrive.
    public func skip(_ n: Int) {
        let count = Swift.max(0, n)
        let buffered = Swift.min(count, pending.count - pendingIndex)
        pendingIndex += buffered
        inner.skip(count - buffered)
    }

    /// Reads and decodes the next element, or nil once the file and the reader are both exhausted.
    public func next() throws -> Inner.Element? {
        do {
            while pendingIndex >= pending.count {
                guard !finished else { return nil }
                let chunk = try handle.read(chunkSize)
                if chunk.isEmpty {
                    finished = true
                    handle.close()
                    pending = try inner.finish()
                } else {
                    pending = try inner.push(chunk)
                }
                pendingIndex = 0
            }
            let element = pending[pendingIndex]
            pendingIndex += 1
            return element
        } catch {
            close()
            throw error
        }
    }
}

public extension YAMLDecoder {

    /// A pull-style reader over a top-level YAML block sequence stored in a file, decoded a chunk at
    /// a time so the file is never held whole. Pass the element type and the file's url. Pass your
    /// own `YAMLFileIO` to route the read through something other than `FileManager`.
    func fileSequenceReader<Element: Decodable>(
        _ type: Element.Type,
        contentsOf url: URL,
        chunkSize: Int = 64 * 1024,
        fileIO: YAMLFileIO = LocalFileIO()
    ) throws -> YAMLFileSequenceReader<YAMLByteSequenceReader<Element>> {
        let handle = try fileIO.openForReading(url)
        let inner = YAMLByteSequenceReader<Element>(limits: limits)
        return YAMLFileSequenceReader(handle: handle, chunkSize: chunkSize, inner: inner)
    }
}
