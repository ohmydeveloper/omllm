import LLMCore
import Testing

@Suite("Core models")
struct CoreModelTests {
    @Test("message text joins only text blocks")
    func messageText() {
        let message = LLMMessage(role: .assistant, content: [
            .text("one"),
            .toolCall(.init(id: "call", name: "lookup", arguments: .object([:]))),
            .text("two"),
        ])

        #expect(message.text == "onetwo")
    }

    @Test("response text delegates to message")
    func responseText() {
        let response = LLMResponse(message: .assistant("result"), finishReason: .completed)
        #expect(response.text == "result")
    }

    @Test("message convenience constructors preserve roles and content")
    func messageConstructors() {
        let user = LLMMessage.user("question")
        let assistant = LLMMessage.assistant("answer")
        let tool = LLMMessage.toolResult(toolCallID: "call-1", content: "sunny", isError: true)

        #expect(user == LLMMessage(role: .user, content: [.text("question")]))
        #expect(assistant == LLMMessage(role: .assistant, content: [.text("answer")]))
        #expect(tool.role == .tool)
        #expect(tool.content == [
            .toolResult(.init(toolCallID: "call-1", content: "sunny", isError: true)),
        ])
    }

    @Test("response preserves canonical fields")
    func responseFields() {
        let response = LLMResponse(
            id: "response-1",
            model: "model-1",
            message: .assistant("result"),
            finishReason: .maxOutputTokens,
            usage: .init(inputTokens: 4, outputTokens: 5),
            providerMetadata: .init(["status": .string("incomplete")])
        )

        #expect(response.id == "response-1")
        #expect(response.model == "model-1")
        #expect(response.finishReason == .maxOutputTokens)
        #expect(response.usage?.totalTokens == 9)
        #expect(response.providerMetadata["status"] == .string("incomplete"))
    }

    @Test("model identifiers and catalog metadata preserve values")
    func models() {
        let model: LLMModel = "gpt-test"
        let info = LLMModelInfo(
            model: model,
            displayName: "Test model",
            ownedBy: "openai",
            metadata: .init(["object": .string("model")])
        )

        #expect(model.id == "gpt-test")
        #expect(model.rawValue == "gpt-test")
        #expect(info.model == model)
        #expect(info.displayName == "Test model")
        #expect(info.ownedBy == "openai")
        #expect(info.metadata["object"] == .string("model"))
    }

    @Test(
        "token totals include available values",
        arguments: [
            (TokenUsage(inputTokens: 2, outputTokens: 3), 5),
            (TokenUsage(inputTokens: 2), 2),
            (TokenUsage(outputTokens: 3), 3),
        ]
    )
    func tokenTotal(usage: TokenUsage, expected: Int) {
        #expect(usage.totalTokens == expected)
    }

    @Test("token total is absent when usage is unknown")
    func absentTokenTotal() {
        #expect(TokenUsage().totalTokens == nil)
    }
}
