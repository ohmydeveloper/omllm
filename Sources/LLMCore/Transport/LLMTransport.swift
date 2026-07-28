import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The data and HTTP metadata returned by a transport request.
public struct LLMTransportResponse: Sendable {
    public var data: Data
    public var statusCode: Int
    public var headers: [String: String]

    public init(data: Data, statusCode: Int, headers: [String: String]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }
}

/// Failures produced before a provider can decode its response payload.
public enum LLMTransportError: Error, Sendable {
    case httpStatus(LLMTransportResponse)
}

/// HTTP transport used by provider drivers.
public protocol LLMTransport: Sendable {
    /// Sends a regular request and returns its unprocessed HTTP response.
    func send(_ request: URLRequest) async throws -> LLMTransportResponse

    /// Streams unprocessed response bytes. Provider drivers own protocol parsing.
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error>
}
