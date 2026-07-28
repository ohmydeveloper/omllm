import Foundation

/// A normalized semantic event emitted during generation.
public enum LLMEvent: Equatable, Sendable {
    case started(id: String?, model: LLMModel?)
    case textDelta(String)
    case toolCallStarted(id: String, name: String)
    case toolCallArgumentsDelta(id: String, jsonFragment: String)
    case usage(TokenUsage)
    case completed(LLMResponse)
}
