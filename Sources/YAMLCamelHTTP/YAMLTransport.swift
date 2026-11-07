import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A request a `YAMLTransport` can send. Mirrors `URLRequest`'s shape directly, so a caller with its
/// own networking layer has nothing extra to translate.
public struct YAMLTransportRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    var originalRequest: URLRequest?

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.originalRequest = nil
    }
}

/// A response a `YAMLTransport` returns. Named apart from `YAMLHTTPResponse`, which is already the
/// namespace this module uses for its response-handling calls.
public struct YAMLTransportResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Convenience for a caller or a test that already has an `HTTPURLResponse`.
    public init(_ response: HTTPURLResponse, body: Data) {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        self.init(statusCode: response.statusCode, headers: headers, body: body)
    }

    /// Reads a header without depending on dictionary lookup being case insensitive, which HTTP
    /// header names are and a `[String: String]` is not.
    public func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        for (key, value) in headers where key.lowercased() == wanted { return value }
        return nil
    }
}

/// HTTP transport a caller can substitute, so YAML-over-HTTP can be routed through a consumer's own
/// networking layer, a game engine among them, rather than always through `URLSession`.
///
/// `maxResponseBytes` is passed in rather than left for a conformance to guess at, so the one bound
/// that matters while a body is actually arriving, how much of it to accept, is available at the
/// point where accepting it happens. `YAMLHTTPClient` checks the same bound again once a body comes
/// back, but a check made only there has already paid for whatever memory a hostile response spent.
/// A custom transport is free to ignore the bound; the default one does not.
public protocol YAMLTransport: Sendable {
    func send(_ request: YAMLTransportRequest, maxResponseBytes: Int) async throws -> YAMLTransportResponse
}

/// The default `YAMLTransport`, backed by `URLSession`.
///
/// A response is collected through a delegate rather than through `dataTask(with:completionHandler:)`,
/// which only calls a delegate back for authentication and hands the whole body to the completion
/// handler in one piece. Reading it through `urlSession(_:dataTask:didReceive:)` instead means the
/// running total is checked as each block arrives, and the task is cancelled the moment it crosses
/// `maxResponseBytes` rather than after a server has been allowed to hand over as much as it likes.
public struct URLSessionTransport: YAMLTransport {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: YAMLTransportRequest, maxResponseBytes: Int) async throws -> YAMLTransportResponse {
        var urlRequest = request.originalRequest ?? URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        if request.body != nil || request.originalRequest == nil { urlRequest.httpBody = request.body }

        let (data, response) = try await boundedBodyAndResponse(for: urlRequest, maxResponseBytes: maxResponseBytes)
        guard let http = response as? HTTPURLResponse else { throw YAMLHTTPError.notHTTP }
        return YAMLTransportResponse(http, body: data)
    }

    /// Runs the request on a session of its own, so the collector delegate answers for exactly one
    /// task and never has to tell several apart. The session carries the caller's configuration
    /// forward, proxies, timeouts and all, and is invalidated once this call is done with it.
    private func boundedBodyAndResponse(for request: URLRequest, maxResponseBytes: Int) async throws -> (Data, URLResponse) {
        let collector = BoundedResponseCollector(maxResponseBytes: maxResponseBytes, forwarding: session.delegate, originalSession: session)
        let boundedSession = URLSession(configuration: session.configuration,
                                        delegate: collector,
                                        delegateQueue: nil)
        defer { boundedSession.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            collector.continuation = continuation
            boundedSession.dataTask(with: request).resume()
        }
    }
}

/// Accumulates one task's response while refusing to hold more than `maxResponseBytes` of it.
///
/// Every mutable property here is touched only from delegate callbacks, which a session with its own
/// delegate queue (the `delegateQueue: nil` default builds a private serial one) always runs one at a
/// time, so nothing further guards them. `@unchecked` because the compiler has no way to see that
/// serial-queue guarantee; swift-corelibs-foundation's `URLSessionDataDelegate` asks for `Sendable`
/// conformance where Apple's Foundation does not, so this only shows up building on Linux.
///
/// Internal rather than private so a test can drive its delegate methods directly, the same way
/// `URLSession` would, without a real socket in the way.
final class BoundedResponseCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxResponseBytes: Int
    private var body = Data()
    private var response: URLResponse?
    private var overLimit = false
    private let forwardedDelegate: URLSessionDelegate?
    private let originalSession: URLSession?

    var continuation: CheckedContinuation<(Data, URLResponse), Error>?

    init(maxResponseBytes: Int, forwarding delegate: URLSessionDelegate? = nil, originalSession: URLSession? = nil) {
        self.maxResponseBytes = maxResponseBytes
        self.forwardedDelegate = delegate
        self.originalSession = originalSession
    }

    // Keep the caller's authentication and redirect policies when collecting a bounded body on
    // a dedicated session. These callbacks include certificate pinning and client authentication.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        #if canImport(FoundationNetworking)
        if let delegate = forwardedDelegate {
            delegate.urlSession(originalSession ?? session, didReceive: challenge, completionHandler: completionHandler)
            return
        }
        #else
        if let callback = forwardedDelegate?.urlSession(_:didReceive:completionHandler:) {
            callback(originalSession ?? session, challenge, completionHandler)
            return
        }
        #endif
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        #if canImport(FoundationNetworking)
        if let delegate = forwardedDelegate as? URLSessionTaskDelegate {
            delegate.urlSession(originalSession ?? session, task: task, didReceive: challenge, completionHandler: completionHandler)
            return
        }
        #else
        if let callback = (forwardedDelegate as? URLSessionTaskDelegate)?.urlSession(_:task:didReceive:completionHandler:) {
            callback(originalSession ?? session, task, challenge, completionHandler)
            return
        }
        #endif
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        #if canImport(FoundationNetworking)
        if let delegate = forwardedDelegate as? URLSessionTaskDelegate {
            delegate.urlSession(originalSession ?? session, task: task, willPerformHTTPRedirection: response,
                                newRequest: request, completionHandler: completionHandler)
            return
        }
        #else
        if let callback = (forwardedDelegate as? URLSessionTaskDelegate)?.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:) {
            callback(originalSession ?? session, task, response, request, completionHandler)
            return
        }
        #endif
        completionHandler(request)
    }

    /// Refuses before the first byte arrives when the server admits up front that the body is too
    /// big, so a truthful `Content-Length` saves downloading anything at all.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        if response.expectedContentLength >= 0, response.expectedContentLength > Int64(maxResponseBytes) {
            overLimit = true
            completionHandler(.cancel)
            session.invalidateAndCancel()
            return
        }
        completionHandler(.allow)
    }

    /// Checked as each block arrives rather than once the task finishes, so a body that never
    /// declared its length, or lied about it, is still cut off close to the bound instead of being
    /// held whole first and measured after.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !overLimit else { return }
        body.append(data)
        if body.count > maxResponseBytes {
            overLimit = true
            body = Data()
            // `dataTask.cancel()` alone leaves swift-corelibs-foundation's libcurl-backed transport
            // running: the connection keeps reading off the wire in the background and every later
            // block is simply dropped here, so the bytes are never held, but the server is left free
            // to keep sending for as long as it likes. Invalidating the session this task's own is
            // what actually tears the connection down on that backend, and does so safely, since this
            // session was built for exactly one task and answers to no one else.
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        if overLimit {
            continuation.resume(throwing: YAMLHTTPError.responseTooLarge(limit: maxResponseBytes))
        } else if let error = error {
            continuation.resume(throwing: error)
        } else if let response = response {
            continuation.resume(returning: (body, response))
        } else {
            continuation.resume(throwing: YAMLHTTPError.notHTTP)
        }
    }
}
