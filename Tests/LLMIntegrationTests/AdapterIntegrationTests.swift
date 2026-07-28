import Foundation
import LLMCore
import LLMOpenAICompatible
import LLMTestSupport
import Testing

@Suite("Adapter integration")
struct AdapterIntegrationTests {
    @Test("client remains independent of concrete provider")
    func mockIntegration() async throws {
        let response = LLMResponse(message: .assistant("portable"), finishReason: .completed)
        let client = LLMClient(driver: MockLLMDriver(response: response))

        let request = LLMRequest(messages: [.user("test")])
        #expect(try await client.generate(request).text == "portable")
    }

    @Test("compatible capabilities follow configuration")
    func compatibleCapabilities() async throws {
        let configuration = OpenAICompatibleConfiguration(
            baseURL: try #require(URL(string: "http://localhost:11434/v1")),
            compatibility: .init(supportsTools: false, supportsJSONSchema: true)
        )
        let capabilities = try await OpenAICompatibleDriver(configuration: configuration)
            .capabilities(for: nil)

        #expect(!capabilities.supportsToolCalling)
        #expect(capabilities.supportsJSONSchemaOutput)
    }

    @Test("compatible driver rejects unsupported tools")
    func rejectsUnsupportedTools() async throws {
        let configuration = OpenAICompatibleConfiguration(
            baseURL: try #require(URL(string: "http://localhost:11434/v1")),
            defaultModel: "test-model",
            compatibility: .init(supportsTools: false)
        )
        let request = LLMRequest(
            messages: [.user("test")],
            tools: [.init(name: "lookup", inputSchema: .object([:]))]
        )

        await #expect(throws: LLMError.unsupportedFeature("This endpoint does not support tools")) {
            try await OpenAICompatibleDriver(configuration: configuration).generate(request)
        }
    }
}
