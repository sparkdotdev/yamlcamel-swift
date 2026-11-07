import Foundation
import XCTest
@testable import YAMLCamelHTTP
import YAMLCamel
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class AuditChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

private final class AuditPolicyDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var sessions: [URLSession] = []
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        sessions.append(session)
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        sessions.append(session)
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        sessions.append(session)
        completionHandler(nil)
    }
}

private final class AuditRequestProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var received: URLRequest?
    static func snapshot() -> URLRequest? {
        lock.lock(); defer { lock.unlock() }; return received
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.received = request; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/yaml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("true".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AuditTransportRegressionTests: XCTestCase {
    func testCallerAuthenticationAndRedirectPoliciesAreForwarded() {
        let delegate = AuditPolicyDelegate()
        let original = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let collecting = URLSession(configuration: .ephemeral)
        defer { original.invalidateAndCancel(); collecting.invalidateAndCancel() }
        let url = URL(string: "https://example.invalid/a")!
        let task = collecting.dataTask(with: url)
        let collector = BoundedResponseCollector(maxResponseBytes: 100, forwarding: delegate, originalSession: original)
        let space = URLProtectionSpace(host: "example.invalid", port: 443, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: AuditChallengeSender())
        var answers = 0
        collector.urlSession(collecting, didReceive: challenge) { disposition, _ in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge); answers += 1
        }
        collector.urlSession(collecting, task: task, didReceive: challenge) { disposition, _ in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge); answers += 1
        }
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: [:])!
        collector.urlSession(collecting, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: url)) { request in
            XCTAssertNil(request); answers += 1
        }
        XCTAssertEqual(answers, 3)
        XCTAssertEqual(delegate.sessions.count, 3)
        XCTAssertTrue(delegate.sessions.allSatisfy { $0 === original })
    }

    func testURLRequestOptionsSurviveTheConvenienceAPI() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuditRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://example.invalid/a")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 7)
        request.httpShouldHandleCookies = false
        let value = try await session.yaml(Bool.self, for: request)
        XCTAssertTrue(value)
        let received = AuditRequestProtocol.snapshot()
        XCTAssertEqual(received?.timeoutInterval, 7)
        XCTAssertEqual(received?.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(received?.httpShouldHandleCookies, false)
    }
    func testSequenceResponseRejectsUnsupportedEncoding() async throws {
        struct Transport: YAMLTransport {
            func send(_ request: YAMLTransportRequest, maxResponseBytes: Int) async throws -> YAMLTransportResponse {
                YAMLTransportResponse(statusCode: 200, headers: ["Content-Type": "application/yaml", "Content-Encoding": "br"], body: Data("- value\n".utf8))
            }
        }
        do {
            _ = try await YAMLHTTPClient(transport: Transport()).getSequence(String.self, from: URL(string: "https://example.invalid/a")!)
            XCTFail("unsupported encoding should be refused")
        } catch let error as YAMLHTTPError {
            guard case .unsupportedContentEncoding("br") = error else { return XCTFail("wrong error: \(error)") }
        }
    }

}
