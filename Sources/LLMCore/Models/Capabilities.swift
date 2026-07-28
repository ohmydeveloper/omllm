import Foundation

/// Features supported by a driver for a specific model.
public struct LLMCapabilities: Hashable, Codable, Sendable {
    public var supportsStreaming: Bool
    public var supportsVision: Bool
    public var supportsDocuments: Bool
    public var supportsToolCalling: Bool
    public var supportsJSONObjectOutput: Bool
    public var supportsJSONSchemaOutput: Bool
    public var supportsSeed: Bool

    public init(
        supportsStreaming: Bool = false,
        supportsVision: Bool = false,
        supportsDocuments: Bool = false,
        supportsToolCalling: Bool = false,
        supportsJSONObjectOutput: Bool = false,
        supportsJSONSchemaOutput: Bool = false,
        supportsSeed: Bool = false
    ) {
        self.supportsStreaming = supportsStreaming
        self.supportsVision = supportsVision
        self.supportsDocuments = supportsDocuments
        self.supportsToolCalling = supportsToolCalling
        self.supportsJSONObjectOutput = supportsJSONObjectOutput
        self.supportsJSONSchemaOutput = supportsJSONSchemaOutput
        self.supportsSeed = supportsSeed
    }
}
