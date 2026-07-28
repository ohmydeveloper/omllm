import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LLMCore
import Testing

@Suite("URLSessionTransport", .serialized)
struct URLSessionTransportTests {
    @Test("returns successful response data and headers")
    func successfulResponse() async throws {
        let session = makeSession(status: 200, headers: ["x-request-id": "request-1"], body: Data("ok".utf8))
        let transport = URLSessionTransport(session: session)
        let url = try #require(URL(string: "https://example.test/resource"))

        let response = try await transport.send(URLRequest(url: url))

        #expect(response.statusCode == 200)
        #expect(response.data == Data("ok".utf8))
        #expect(response.headers.contains { $0.key.caseInsensitiveCompare("x-request-id") == .orderedSame && $0.value == "request-1" })
    }

    @Test("preserves non-success status, body, and headers")
    func errorResponse() async throws {
        let body = Data(#"{"error":{"message":"limited"}}"#.utf8)
        let session = makeSession(status: 429, headers: ["retry-after": "2"], body: body)
        let transport = URLSessionTransport(session: session)
        let url = try #require(URL(string: "https://example.test/resource"))

        do {
            _ = try await transport.send(URLRequest(url: url))
            Issue.record("Expected a transport status error")
        } catch let LLMTransportError.httpStatus(response) {
            #expect(response.statusCode == 429)
            #expect(response.data == body)
            #expect(response.headers.contains { $0.key.caseInsensitiveCompare("retry-after") == .orderedSame && $0.value == "2" })
        }
    }

    private func makeSession(status: Int, headers: [String: String], body: Data) -> URLSession {
        StubURLProtocol.response = .init(status: status, headers: headers, body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class StubURLProtocol: URLProtocol {
    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    nonisolated(unsafe) static var response = Response(status: 200, headers: [:], body: Data())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: Self.response.status,
                httpVersion: "HTTP/1.1",
                headerFields: Self.response.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
