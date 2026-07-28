import LLMCore
import LLMTestSupport
import Testing

@Suite("LLMClient")
struct LLMClientTests {
    private let request = LLMRequest(messages: [.user("Hello")])

    @Test("delegates generation")
    func delegatesGeneration() async throws {
        let expected = LLMResponse(
            id: "response-1",
            message: .assistant("Hello back"),
            finishReason: .completed
        )
        let client = LLMClient(driver: MockLLMDriver(response: expected))

        #expect(try await client.generate(request) == expected)
    }

    @Test("delegates capabilities")
    func delegatesCapabilities() async throws {
        let expected = LLMCapabilities(
            supportsStreaming: true,
            supportsToolCalling: true,
            supportsJSONSchemaOutput: true
        )
        let client = LLMClient(driver: MockLLMDriver(capabilities: expected))

        #expect(try await client.capabilities() == expected)
    }

    @Test("forwards streaming events")
    func forwardsStreamingEvents() async throws {
        let expected: [LLMEvent] = [
            .started(id: "1", model: .init(rawValue: "model")),
            .textDelta("Hi"),
            .usage(.init(inputTokens: 1, outputTokens: 1)),
        ]
        let client = LLMClient(driver: MockLLMDriver(events: expected))
        var received: [LLMEvent] = []

        for try await event in client.stream(request) {
            received.append(event)
        }

        #expect(received == expected)
    }

    @Test("propagates driver errors")
    func propagatesErrors() async {
        let expected = LLMError.authenticationFailed("Invalid test key")
        let client = LLMClient(driver: MockLLMDriver(generationError: expected))

        await #expect(throws: expected) {
            try await client.generate(request)
        }
    }

    @Test("delegates model listing")
    func delegatesModelListing() async throws {
        let expected = [
            LLMModelInfo(model: "model-1", displayName: "First"),
            LLMModelInfo(model: "model-2", ownedBy: "provider"),
        ]
        let client = LLMClient(driver: MockLLMDriver(models: expected))

        #expect(try await client.listModels() == expected)
    }

    @Test("propagates model listing errors")
    func propagatesModelListingErrors() async {
        let expected = LLMError.networkError("catalog unavailable")
        let client = LLMClient(driver: MockLLMDriver(modelListError: expected))

        await #expect(throws: expected) {
            try await client.listModels()
        }
    }
}
