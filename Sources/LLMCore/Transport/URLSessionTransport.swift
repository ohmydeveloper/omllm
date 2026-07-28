import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A URLSession-backed HTTP transport.
public struct URLSessionTransport: LLMTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> LLMTransportResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw LLMError.invalidResponse("Transport received a non-HTTP response")
            }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                result[String(describing: pair.key)] = String(describing: pair.value)
            }
            let result = LLMTransportResponse(
                data: data,
                statusCode: response.statusCode,
                headers: headers
            )
            guard (200..<300).contains(response.statusCode) else {
                throw LLMTransportError.httpStatus(result)
            }
            return result
        } catch is CancellationError {
            throw LLMError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw LLMError.cancelled
        } catch let error as LLMTransportError {
            throw error
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.networkError(String(describing: error))
        }
    }

    public func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let delegate = StreamingDelegate(continuation: continuation)
            let streamingSession = URLSession(
                configuration: session.configuration,
                delegate: delegate,
                delegateQueue: nil
            )
            let task = streamingSession.dataTask(with: request)
            delegate.completion = { streamingSession.finishTasksAndInvalidate() }
            continuation.onTermination = { @Sendable _ in task.cancel() }
            task.resume()
        }
    }
}

private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    var completion: (@Sendable () -> Void)?
    private var errorResponse: LLMTransportResponse?
    private var errorBody = Data()

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            continuation.finish(throwing: LLMError.invalidResponse("Stream received a non-HTTP response"))
            completionHandler(.cancel)
            return
        }
        if !(200..<300).contains(http.statusCode) {
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                result[String(describing: pair.key)] = String(describing: pair.value)
            }
            errorResponse = .init(data: Data(), statusCode: http.statusCode, headers: headers)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if errorResponse != nil { errorBody.append(data) } else { continuation.yield(data) }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        defer { completion?() }
        if var response = errorResponse {
            response.data = errorBody
            continuation.finish(throwing: LLMTransportError.httpStatus(response))
        } else if let error = error as? URLError, error.code == .cancelled {
            continuation.finish(throwing: LLMError.cancelled)
        } else if let error {
            continuation.finish(throwing: LLMError.networkError(String(describing: error)))
        } else {
            continuation.finish()
        }
    }
}
