import Foundation

// MARK: - Content blocks

public struct TextContent: Equatable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct ImageContent: Equatable, Sendable {
    public var data: String   // base64
    public var mimeType: String
    public init(data: String, mimeType: String) { self.data = data; self.mimeType = mimeType }
}

public struct ThinkingContent: Equatable, Sendable {
    public var thinking: String
    public init(thinking: String) { self.thinking = thinking }
}

public struct ToolCall: Sendable {
    public var id: String
    public var name: String
    public var arguments: [String: Any]
    public init(id: String, name: String, arguments: [String: Any] = [:]) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

// MARK: - Messages

public struct UserMessage: Sendable {
    public enum Content: Sendable {
        case text(String)
        case parts([Part])
    }
    public enum Part: Sendable {
        case text(TextContent)
        case image(ImageContent)
    }

    public var content: Content
    public var timestamp: Date

    public init(text: String, timestamp: Date = Date()) {
        self.content = .text(text); self.timestamp = timestamp
    }
    public init(parts: [Part], timestamp: Date = Date()) {
        self.content = .parts(parts); self.timestamp = timestamp
    }
}

public struct AssistantMessage: Sendable {
    public enum Content: Sendable {
        case text(TextContent)
        case thinking(ThinkingContent)
        case toolCall(ToolCall)
    }

    public var content: [Content]
    public var model: String
    public var provider: String
    public var usage: Usage
    public var stopReason: StopReason
    public var errorMessage: String?
    public var timestamp: Date

    public init(
        content: [Content] = [],
        model: String,
        provider: String,
        usage: Usage = .zero,
        stopReason: StopReason = .stop,
        errorMessage: String? = nil,
        timestamp: Date = Date()
    ) {
        self.content = content
        self.model = model
        self.provider = provider
        self.usage = usage
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.timestamp = timestamp
    }
}

public struct ToolResultMessage: Sendable {
    public enum Content: Sendable {
        case text(TextContent)
        case image(ImageContent)
    }

    public var toolCallId: String
    public var content: [Content]
    public var isError: Bool
    public var timestamp: Date

    public init(toolCallId: String, text: String, isError: Bool = false, timestamp: Date = Date()) {
        self.toolCallId = toolCallId
        self.content = [.text(TextContent(text: text))]
        self.isError = isError
        self.timestamp = timestamp
    }

    public init(toolCallId: String, content: [Content], isError: Bool = false, timestamp: Date = Date()) {
        self.toolCallId = toolCallId
        self.content = content
        self.isError = isError
        self.timestamp = timestamp
    }
}

public enum Message: Sendable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)
}

// MARK: - Tool

public struct Tool: Sendable {
    public var name: String
    public var description: String
    /// JSON Schema as a dictionary (e.g. ["type": "object", "properties": [...]])
    public var parameters: [String: Any]

    public init(name: String, description: String, parameters: [String: Any]) {
        self.name = name; self.description = description; self.parameters = parameters
    }
}

// MARK: - Context

public struct Context: Sendable {
    public var systemPrompt: String?
    public var messages: [Message]
    public var tools: [Tool]

    public init(systemPrompt: String? = nil, messages: [Message] = [], tools: [Tool] = []) {
        self.systemPrompt = systemPrompt; self.messages = messages; self.tools = tools
    }
}

// MARK: - Model

public struct Model: Sendable {
    public struct Cost: Sendable {
        /// USD per million tokens
        public var input: Double
        public var output: Double
        public init(input: Double, output: Double) { self.input = input; self.output = output }
    }

    public var id: String
    public var name: String
    public var provider: String
    public var baseUrl: String
    public var contextWindow: Int
    public var maxTokens: Int
    public var cost: Cost
    /// Whether the model returns reasoning/thinking content (e.g. DeepSeek R1)
    public var supportsThinking: Bool

    public init(
        id: String,
        name: String,
        provider: String,
        baseUrl: String,
        contextWindow: Int,
        maxTokens: Int,
        cost: Cost,
        supportsThinking: Bool = false
    ) {
        self.id = id; self.name = name; self.provider = provider
        self.baseUrl = baseUrl; self.contextWindow = contextWindow
        self.maxTokens = maxTokens; self.cost = cost
        self.supportsThinking = supportsThinking
    }
}

// MARK: - Usage

public struct Usage: Sendable {
    public struct CostBreakdown: Sendable {
        public var total: Double
        public init(total: Double = 0) { self.total = total }
        public static let zero = CostBreakdown(total: 0)
    }

    public var input: Int
    public var output: Int
    public var cost: CostBreakdown

    public init(input: Int = 0, output: Int = 0, cost: CostBreakdown = .zero) {
        self.input = input; self.output = output; self.cost = cost
    }

    public static let zero = Usage()
}

// MARK: - StopReason

public enum StopReason: String, Equatable, Sendable {
    case stop
    case length
    case toolUse
    case error
    case aborted
}

// MARK: - StreamOptions

public struct StreamOptions: Sendable {
    public var apiKey: String?
    public var temperature: Double?
    public var maxTokens: Int?

    public init(apiKey: String? = nil, temperature: Double? = nil, maxTokens: Int? = nil) {
        self.apiKey = apiKey; self.temperature = temperature; self.maxTokens = maxTokens
    }
}

// MARK: - Events

public enum AssistantMessageEvent: Sendable {
    case start(partial: AssistantMessage)
    case textStart(contentIndex: Int, partial: AssistantMessage)
    case textDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case textEnd(contentIndex: Int, content: String, partial: AssistantMessage)
    case thinkingStart(contentIndex: Int, partial: AssistantMessage)
    case thinkingDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case thinkingEnd(contentIndex: Int, content: String, partial: AssistantMessage)
    case toolCallStart(contentIndex: Int, partial: AssistantMessage)
    case toolCallDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case toolCallEnd(contentIndex: Int, toolCall: ToolCall, partial: AssistantMessage)
    case done(message: AssistantMessage)
    case error(message: AssistantMessage)
}

// MARK: - Errors

public enum WispError: Error, LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):            return "Invalid URL: \(url)"
        case .invalidResponse:                return "Invalid HTTP response"
        case .httpError(let code, let body):  return "HTTP \(code): \(body)"
        case .cancelled:                      return "Request cancelled"
        }
    }
}
