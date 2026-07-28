import Foundation

/// Common generation controls supported across providers.
public struct GenerationOptions: Equatable, Codable, Sendable {
    public var temperature: Double?
    public var topP: Double?
    public var maxOutputTokens: Int?
    public var stopSequences: [String]
    public var seed: Int?

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        maxOutputTokens: Int? = nil,
        stopSequences: [String] = [],
        seed: Int? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
        self.stopSequences = stopSequences
        self.seed = seed
    }
}

/// A tool that a model may invoke.
public struct LLMTool: Equatable, Codable, Sendable {
    public var name: String
    public var description: String?
    public var inputSchema: JSONValue

    public init(name: String, description: String? = nil, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Controls whether and how a model should select a tool.
public enum LLMToolChoice: Equatable, Codable, Sendable {
    case auto
    case none
    case required
    case tool(named: String)
}

/// The desired canonical output representation.
public enum OutputConfiguration: Equatable, Codable, Sendable {
    case text
    case jsonObject
    case jsonSchema(name: String, schema: JSONValue, strict: Bool)
}

/// A provider-independent generation request.
public struct LLMRequest: Equatable, Codable, Sendable {
    public var model: LLMModel?
    public var instructions: String?
    public var messages: [LLMMessage]
    public var options: GenerationOptions
    public var tools: [LLMTool]
    public var toolChoice: LLMToolChoice?
    public var output: OutputConfiguration
    /// Application-only metadata. Drivers must not send this unless explicitly designed to do so.
    public var localMetadata: [String: JSONValue]

    public init(
        model: LLMModel? = nil,
        instructions: String? = nil,
        messages: [LLMMessage],
        options: GenerationOptions = .init(),
        tools: [LLMTool] = [],
        toolChoice: LLMToolChoice? = nil,
        output: OutputConfiguration = .text,
        localMetadata: [String: JSONValue] = [:]
    ) {
        self.model = model
        self.instructions = instructions
        self.messages = messages
        self.options = options
        self.tools = tools
        self.toolChoice = toolChoice
        self.output = output
        self.localMetadata = localMetadata
    }

    /// Creates a request with a single user text message.
    public static func text(
        _ text: String,
        model: LLMModel? = nil,
        instructions: String? = nil
    ) -> Self {
        Self(model: model, instructions: instructions, messages: [.user(text)])
    }
}
