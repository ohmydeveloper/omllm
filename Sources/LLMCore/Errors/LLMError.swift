import Foundation

/// Provider-independent failures exposed by the library.
public enum LLMError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case unsupportedFeature(String)
    case authenticationFailed(String)
    case permissionDenied(String)
    case modelNotFound(String)
    case rateLimited(retryAfterSeconds: Double?)
    case contextLengthExceeded(String)
    case networkError(String)
    case invalidResponse(String)
    case serverError(statusCode: Int?, message: String)
    case notImplemented(String)
    case cancelled
}
