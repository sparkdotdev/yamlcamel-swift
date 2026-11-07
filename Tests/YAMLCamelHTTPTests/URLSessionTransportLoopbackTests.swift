import Foundation
import Testing
@testable import YAMLCamelHTTP
import YAMLCamel

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A minimal loopback HTTP server, raw sockets only, so `URLSessionTransport` can be pointed at a
/// server that keeps sending well past `maxResponseBytes` without declaring a `Content-Length`.
///
/// `BoundedResponseCollector`'s own tests drive its delegate methods directly and prove its logic in
/// isolation; this proves the other half, that `URLSessionTransport.send` really wires a real
/// `URLSession` download through that collector rather than through the completion-handler form that
/// never calls it at all. Everything here is loopback-only and closes itself down at the end of the
/// call that started it.
private final class LoopbackOversizedServer {
    private let listenFD: Int32
    let port: UInt16

    /// Bytes the server actually got onto the wire before its write failed or it hit `bodyCap`.
    /// Set once, after the background thread finishes; read only after `wait()` returns.
    private(set) var bytesWritten = 0

    private let done = DispatchSemaphore(value: 0)

    /// Pass how large a body to offer (`bodyCap`) and how big each write is. A client that never
    /// stops reading gets `bodyCap` bytes and a closed connection; one that cancels early is what
    /// `bytesWritten` catches.
    init(bodyCap: Int = 64 << 20, chunkSize: Int = 64 * 1024) {
        signal(SIGPIPE, SIG_IGN)   // a write to a socket the client already closed must not kill the test process

        // Built up through locals rather than `self.listenFD`/`self.port`: a stored property read
        // inside these closures before every property is set would force an implicit `self` capture
        // this initializer has not reached the point of allowing yet.
        //
        // SOCK_STREAM is already Int32 on Darwin but a distinct enum on Glibc, so only one of these
        // conversions type-checks on a given platform.
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0   // ask the kernel for an unused port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bindResult = withUnsafePointer(to: &addr) { raw -> Int32 in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bindResult == 0, "could not bind a loopback test socket")
        precondition(listen(fd, 1) == 0, "could not listen on a loopback test socket")

        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { raw -> Int32 in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &boundLen)
            }
        }

        listenFD = fd
        port = UInt16(bigEndian: bound.sin_port)

        Thread.detachNewThread { [weak self] in
            LoopbackOversizedServer.serveOnce(listenFD: fd, bodyCap: bodyCap, chunkSize: chunkSize) { written in
                self?.bytesWritten = written
                self?.done.signal()
            }
        }
    }

    /// Blocks until the one connection this server accepts has been served, or `timeout` passes.
    /// Returns false on a timeout, which means the test itself should fail rather than hang.
    func wait(timeout: TimeInterval = 10) -> Bool {
        done.wait(timeout: .now() + timeout) == .success
    }

    func close() { closeSocket(listenFD) }

    private static func serveOnce(listenFD: Int32, bodyCap: Int, chunkSize: Int, report: (Int) -> Void) {
        let connectionFD = accept(listenFD, nil, nil)
        guard connectionFD >= 0 else { report(0); return }
        defer { closeSocket(connectionFD) }

        // The request itself is never inspected: a fixed response goes back regardless of what was
        // asked for, since all this server exists to prove is how much of a body the client accepts.
        var requestBuffer = [UInt8](repeating: 0, count: 4096)
        _ = requestBuffer.withUnsafeMutableBytes { read(connectionFD, $0.baseAddress, $0.count) }

        // No Content-Length: a declared length lets a client refuse before the first body byte, and
        // this server means to prove the bound still holds when nothing declares one, the shape a
        // chunked or misbehaving server actually has.
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/yaml\r\nConnection: close\r\n\r\n"
        var total = 0
        guard writeAll(connectionFD, Array(header.utf8)) else { report(0); return }

        let chunk = [UInt8](repeating: 0x41, count: chunkSize)
        while total < bodyCap {
            guard writeAll(connectionFD, chunk) else { break }   // the client closed the connection
            total += chunk.count
        }
        report(total)
    }

    /// Writes every byte in `bytes`, looping over partial writes, and reports false the moment the
    /// socket refuses one rather than retrying forever.
    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        return bytes.withUnsafeBytes { raw -> Bool in
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}

/// `close(2)` under its own name, since `close` alone is ambiguous once `Foundation` is imported
/// alongside `Darwin` or `Glibc`.
private func closeSocket(_ fd: Int32) { _ = close(fd) }

@Suite("URLSessionTransport against a real socket")
struct URLSessionTransportLoopbackTests {

    @Test("a response with no declared length never resolves once received bytes cross the bound")
    func neverResolvesOnceOverTheBound() async throws {
        let bodyCap = 32 << 20   // 32 MB on offer; a working bound must stop far short of this
        let server = LoopbackOversizedServer(bodyCap: bodyCap)
        defer { server.close() }

        let maxResponseBytes = 64 * 1024
        let url = URL(string: "http://127.0.0.1:\(server.port)/")!
        let request = YAMLTransportRequest(url: url)

        var caught: Error?
        do {
            _ = try await URLSessionTransport().send(request, maxResponseBytes: maxResponseBytes)
            Issue.record("a body this large should have been refused")
        } catch {
            caught = error
        }

        #expect(server.wait(), "the loopback server never finished serving its one connection")

        guard case .responseTooLarge(let limit)? = caught as? YAMLHTTPError else {
            Issue.record("expected YAMLHTTPError.responseTooLarge, got \(String(describing: caught))")
            return
        }
        #expect(limit == maxResponseBytes)

        // Whichever platform this runs on, the oversized body must never reach the caller: the
        // collector discards what it already held the moment the bound is crossed, so `send` cannot
        // resolve with it, whatever the connection underneath is still doing.
        //
        // Only Darwin's URLSession is asserted to tear the connection down promptly enough that the
        // server sees the client stop reading well short of the full offer. swift-corelibs-foundation
        // reads a response through libcurl, which can already have pulled a fast loopback sender's
        // whole body into its own buffers before this collector ever gets a chance to cancel the
        // task, so `bytesWritten` on Linux is not a reliable signal of how much this process actually
        // held onto, only Darwin's is.
        #if canImport(Darwin)
        #expect(server.bytesWritten < bodyCap / 4,
               "the server delivered \(server.bytesWritten) of \(bodyCap) offered bytes; a bounded download should have stopped far short of that")
        #endif
    }
}
