import Foundation

// MARK: - Stop reason

public enum StopReason: String, Codable {
    case stop
    case length
    case toolUse
    case error
    case aborted
}

// MARK: - Cost and usage

public struct ModelCost: Codable {
    public let input: Double
    public let output: Double
    public init(input: Double = 0, output: Double = 0) {
        self.input = input; self.output = output
    }
}

public struct Cost: Codable {
    public let input: Double
    public let output: Double
    public let total: Double
    public init(input: Double = 0, output: Double = 0, total: Double = 0) {
        self.input = input; self.output = output; self.total = total
    }
}

public struct Usage: Codable {
    public let input: Int
    public let output: Int
    public let cost: Cost
    public init(input: Int = 0, output: Int = 0, cost: Cost = Cost()) {
        self.input = input; self.output = output; self.cost = cost
    }
}

// MARK: - Content parts

public struct ContentPart: Codable {
    public let type: String
    public let text: String?
    public let thinking: String?
    public let id: String?
    public let name: String?
    public let arguments: String?

    public init(type: String, text: String? = nil, thinking: String? = nil,
                id: String? = nil, name: String? = nil, arguments: String? = nil) {
        self.type = type; self.text = text; self.thinking = thinking
        self.id = id; self.name = name; self.arguments = arguments
    }

    public static func text(_ t: String) -> ContentPart { ContentPart(type: "text", text: t) }
    public static func thinking(_ t: String) -> ContentPart { ContentPart(type: "thinking", thinking: t) }
    public static func toolCall(id: String, name: String, arguments: String) -> ContentPart {
        ContentPart(type: "toolCall", id: id, name: name, arguments: arguments)
    }
}

// MARK: - Diagnostics

public struct DiagnosticError: Codable {
    public let name: String
    public let message: String
    public let code: String?
}

public struct AssistantMessageDiagnostic: Codable {
    public let type: String
    public let timestamp: Date
    public let error: DiagnosticError?
    public let details: [String: String]?
}

// MARK: - Assistant message

public struct AssistantMessage: Codable {
    public let role: String
    public var model: String
    public let provider: String
    public var content: [ContentPart]
    public var stopReason: StopReason
    public var usage: Usage
    public var errorMessage: String?
    public var diagnostics: [AssistantMessageDiagnostic]
    public let timestamp: Date

    public init(role: String = "assistant", model: String, provider: String,
                content: [ContentPart] = [], stopReason: StopReason = .stop,
                usage: Usage = Usage(), errorMessage: String? = nil,
                diagnostics: [AssistantMessageDiagnostic] = [], timestamp: Date = Date()) {
        self.role = role; self.model = model; self.provider = provider
        self.content = content; self.stopReason = stopReason; self.usage = usage
        self.errorMessage = errorMessage; self.diagnostics = diagnostics; self.timestamp = timestamp
    }

    mutating func appendDiagnostic(type diagType: String, message: String, details: [String: String]? = nil) {
        let d = AssistantMessageDiagnostic(
            type: diagType,
            timestamp: Date(),
            error: DiagnosticError(name: diagType, message: message, code: nil),
            details: details
        )
        diagnostics.append(d)
    }
}

// MARK: - Context

public struct ContextMessage: Codable {
    public let role: String
    public let content: String
    public let parts: [ContentPart]
    public let toolCallID: String?

    public init(role: String, content: String = "", parts: [ContentPart] = [], toolCallID: String? = nil) {
        self.role = role; self.content = content; self.parts = parts; self.toolCallID = toolCallID
    }

    public static func user(_ text: String) -> ContextMessage {
        ContextMessage(role: "user", content: text)
    }
    public static func assistant(_ msg: AssistantMessage) -> ContextMessage {
        ContextMessage(role: "assistant", parts: msg.content)
    }
    public static func toolResult(id: String, content: String) -> ContextMessage {
        ContextMessage(role: "tool", content: content, toolCallID: id)
    }
}

public struct Context {
    public var systemPrompt: String
    public var messages: [ContextMessage]
    public var tools: [Tool]

    public init(systemPrompt: String = "", messages: [ContextMessage] = [], tools: [Tool] = []) {
        self.systemPrompt = systemPrompt; self.messages = messages; self.tools = tools
    }
}

// MARK: - Tool

public struct Tool {
    public let name: String
    public let description: String
    public let parameters: Data

    public init(name: String, description: String, parameters: Data) {
        self.name = name; self.description = description; self.parameters = parameters
    }
}

// MARK: - Stream options

public struct StreamOptions {
    public var apiKey: String
    public var temperature: Double?
    public var maxTokens: Int?

    public init(apiKey: String = "", temperature: Double? = nil, maxTokens: Int? = nil) {
        self.apiKey = apiKey; self.temperature = temperature; self.maxTokens = maxTokens
    }
}

public struct StreamDefaults: Codable {
    public let temperature: Double?
    public let maxTokens: Int?
}

public struct RetrySettings: Codable {
    public let enabled: Bool?
    public let maxRetries: Int?
    public let baseDelayMs: Int?
    public let timeoutMs: Int?
}

// MARK: - Events

public enum EventType: String, Codable {
    case start
    case textStart
    case textDelta
    case textEnd
    case thinkingStart
    case thinkingDelta
    case thinkingEnd
    case toolCallStart
    case toolCallDelta
    case toolCallEnd
    case done
    case error
}

public struct AssistantMessageEvent {
    public let type: EventType
    public let index: Int
    public let delta: String
    public let content: String
    public let part: ContentPart?
    public let message: AssistantMessage?
    public let partial: AssistantMessage?

    public init(type: EventType, index: Int = 0, delta: String = "", content: String = "",
                part: ContentPart? = nil, message: AssistantMessage? = nil, partial: AssistantMessage? = nil) {
        self.type = type; self.index = index; self.delta = delta; self.content = content
        self.part = part; self.message = message; self.partial = partial
    }
}

extension AssistantMessageEvent: Encodable {
    enum CodingKeys: String, CodingKey {
        case type, index, delta, content, part, message, partial
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        if index != 0  { try c.encode(index, forKey: .index) }
        if !delta.isEmpty   { try c.encode(delta, forKey: .delta) }
        if !content.isEmpty { try c.encode(content, forKey: .content) }
        try c.encodeIfPresent(part, forKey: .part)
        try c.encodeIfPresent(message, forKey: .message)
        try c.encodeIfPresent(partial, forKey: .partial)
    }
}

// MARK: - Agent options

public struct AgentOptions {
    public var maxSteps: Int
    public var onStep: (@Sendable ([ContextMessage]) -> Void)?

    public init(maxSteps: Int = 10, onStep: (@Sendable ([ContextMessage]) -> Void)? = nil) {
        self.maxSteps = maxSteps; self.onStep = onStep
    }
}
