import Foundation
import Testing
@testable import YAMLCamelHTTP

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `BoundedResponseCollector` is what makes `URLSessionTransport`, the default `YAMLTransport`, safe
/// to point at a server that will not stop sending: without it, `dataTask(with:completionHandler:)`
/// hands the whole body to its completion handler in one piece, so a bound checked on what that
/// returns has already paid for the memory it exists to cap.
///
/// These drive the collector's delegate methods directly, the same sequence `URLSession` itself would
/// call them in, so the cancel-on-overflow behaviour is provable without a real socket or server.
@Suite("URLSessionTransport response bound")
struct URLSessionTransportTests {

    private let url = URL(string: "https://example.invalid/words.yaml")!

    private func response(expectedContentLength: Int64) -> URLResponse {
        URLResponse(url: url, mimeType: "application/yaml",
                   expectedContentLength: Int(expectedContentLength), textEncodingName: nil)
    }

    /// A session and task the collector can call `invalidateAndCancel()`/`cancel()` on. The task is
    /// never resumed, so nothing it does reaches a real network; a session of its own, rather than
    /// `.shared`, means the collector invalidating it on overflow is exactly what production code
    /// does with its own per-call session instead of the runtime warning invalidating `.shared` would
    /// print.
    private func unresolvedTaskAndSession() -> (URLSessionDataTask, URLSession) {
        let session = URLSession(configuration: .ephemeral)
        return (session.dataTask(with: url), session)
    }

    @Test("a declared Content-Length over the bound is refused before any body byte arrives")
    func refusesOnDeclaredLength() async throws {
        let collector = BoundedResponseCollector(maxResponseBytes: 100)
        let (task, session) = unresolvedTaskAndSession()
        defer { task.cancel() }

        var disposition: URLSession.ResponseDisposition?
        collector.urlSession(session, dataTask: task,
                             didReceive: response(expectedContentLength: 10_000)) { disposition = $0 }
        #expect(disposition == .cancel)

        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                collector.continuation = continuation
                collector.urlSession(session, task: task, didCompleteWithError: nil)
            }
            Issue.record("a declared length over the bound should not resolve a body")
        } catch let error as YAMLHTTPError {
            guard case .responseTooLarge(let limit) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(limit == 100)
        }
    }

    @Test("a body with no declared length is cut off once received bytes cross the bound")
    func cancelsOnAccumulatedBytes() async throws {
        // -1 is what URLResponse reports for a body whose length was never declared, a chunked
        // response among them, which is exactly the shape a server has to use to dodge the
        // declared-length check above.
        let collector = BoundedResponseCollector(maxResponseBytes: 10)
        let (task, session) = unresolvedTaskAndSession()
        defer { task.cancel() }

        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                collector.continuation = continuation
                var disposition: URLSession.ResponseDisposition?
                collector.urlSession(session, dataTask: task,
                                     didReceive: response(expectedContentLength: -1)) { disposition = $0 }
                #expect(disposition == .allow)

                // Six blocks of six bytes: the third crosses the ten byte bound, so nothing past it
                // should ever be asked for or held.
                for _ in 0 ..< 6 {
                    collector.urlSession(session, dataTask: task, didReceive: Data(repeating: 0x41, count: 6))
                }
                collector.urlSession(session, task: task, didCompleteWithError: nil)
            }
            Issue.record("a body over the bound should not resolve")
        } catch let error as YAMLHTTPError {
            guard case .responseTooLarge(let limit) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(limit == 10)
        }
    }

    @Test("a body that never crosses the bound resolves with everything it received")
    func resolvesUnderBound() async throws {
        let collector = BoundedResponseCollector(maxResponseBytes: 1_000)
        let (task, session) = unresolvedTaskAndSession()
        defer { task.cancel() }

        let (body, response) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            collector.continuation = continuation
            var disposition: URLSession.ResponseDisposition?
            collector.urlSession(session, dataTask: task,
                                 didReceive: self.response(expectedContentLength: 12)) { disposition = $0 }
            #expect(disposition == .allow)
            collector.urlSession(session, dataTask: task, didReceive: Data("hello, ".utf8))
            collector.urlSession(session, dataTask: task, didReceive: Data("world!".utf8))
            collector.urlSession(session, task: task, didCompleteWithError: nil)
        }
        #expect(String(decoding: body, as: UTF8.self) == "hello, world!")
        #expect(response.url == url)
    }
}
