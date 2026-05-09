import Foundation

// Pre-defined models for common OpenAI-compatible providers.
// All prices are USD per million tokens as of mid-2025.

public extension Model {

    // MARK: - OpenAI

    static let gpt4o = Model(
        id: "gpt-4o",
        name: "GPT-4o",
        provider: "openai",
        baseUrl: "https://api.openai.com/v1",
        contextWindow: 128_000,
        maxTokens: 16_384,
        cost: .init(input: 2.50, output: 10.00)
    )

    static let gpt4oMini = Model(
        id: "gpt-4o-mini",
        name: "GPT-4o Mini",
        provider: "openai",
        baseUrl: "https://api.openai.com/v1",
        contextWindow: 128_000,
        maxTokens: 16_384,
        cost: .init(input: 0.15, output: 0.60)
    )

    static let o4Mini = Model(
        id: "o4-mini",
        name: "o4-mini",
        provider: "openai",
        baseUrl: "https://api.openai.com/v1",
        contextWindow: 128_000,
        maxTokens: 65_536,
        cost: .init(input: 1.10, output: 4.40),
        supportsThinking: true
    )

    // MARK: - DeepSeek

    static let deepSeekChat = Model(
        id: "deepseek-chat",
        name: "DeepSeek V3",
        provider: "deepseek",
        baseUrl: "https://api.deepseek.com/v1",
        contextWindow: 64_000,
        maxTokens: 8_000,
        cost: .init(input: 0.27, output: 1.10)
    )

    /// DeepSeek R1 — emits reasoning via reasoning_content field
    static let deepSeekReasoner = Model(
        id: "deepseek-reasoner",
        name: "DeepSeek R1",
        provider: "deepseek",
        baseUrl: "https://api.deepseek.com/v1",
        contextWindow: 64_000,
        maxTokens: 8_000,
        cost: .init(input: 0.55, output: 2.19),
        supportsThinking: true
    )

    // MARK: - MiniMax

    static let miniMaxText01 = Model(
        id: "MiniMax-Text-01",
        name: "MiniMax Text-01",
        provider: "minimax",
        baseUrl: "https://api.minimaxi.chat/v1",
        contextWindow: 1_000_000,
        maxTokens: 4_096,
        cost: .init(input: 0.80, output: 3.50)
    )

    static let miniMaxM1 = Model(
        id: "MiniMax-M1",
        name: "MiniMax M1",
        provider: "minimax",
        baseUrl: "https://api.minimaxi.chat/v1",
        contextWindow: 1_000_000,
        maxTokens: 40_960,
        cost: .init(input: 0.30, output: 1.10),
        supportsThinking: true
    )

    // MARK: - Groq

    static let groqLlama33_70b = Model(
        id: "llama-3.3-70b-versatile",
        name: "Llama 3.3 70B",
        provider: "groq",
        baseUrl: "https://api.groq.com/openai/v1",
        contextWindow: 128_000,
        maxTokens: 32_768,
        cost: .init(input: 0.59, output: 0.79)
    )

    static let groqQwen3_32b = Model(
        id: "qwen-qwq-32b",
        name: "Qwen QwQ 32B",
        provider: "groq",
        baseUrl: "https://api.groq.com/openai/v1",
        contextWindow: 32_768,
        maxTokens: 16_000,
        cost: .init(input: 0.29, output: 0.39),
        supportsThinking: true
    )

    // MARK: - xAI

    static let grok3 = Model(
        id: "grok-3",
        name: "Grok 3",
        provider: "xai",
        baseUrl: "https://api.x.ai/v1",
        contextWindow: 131_072,
        maxTokens: 8_192,
        cost: .init(input: 3.00, output: 15.00)
    )

    static let grok3Mini = Model(
        id: "grok-3-mini",
        name: "Grok 3 Mini",
        provider: "xai",
        baseUrl: "https://api.x.ai/v1",
        contextWindow: 131_072,
        maxTokens: 8_192,
        cost: .init(input: 0.30, output: 0.50),
        supportsThinking: true
    )

    // MARK: - Cerebras

    static let cerebrasLlama4Scout = Model(
        id: "llama-4-scout-17b-16e-instruct",
        name: "Llama 4 Scout",
        provider: "cerebras",
        baseUrl: "https://api.cerebras.ai/v1",
        contextWindow: 131_072,
        maxTokens: 16_384,
        cost: .init(input: 0.10, output: 0.10)
    )

    // MARK: - Faux (testing)

    /// In-memory mock model for use with FauxProvider in tests.
    static let faux = Model(
        id: "faux-1",
        name: "Faux Model",
        provider: "faux",
        baseUrl: "http://localhost:0",
        contextWindow: 128_000,
        maxTokens: 16_384,
        cost: .init(input: 0, output: 0),
        supportsThinking: true
    )

    // MARK: - OpenRouter (gateway to many providers)

    static func openRouter(
        modelId: String,
        contextWindow: Int = 128_000,
        cost: Cost = .init(input: 0, output: 0)
    ) -> Model {
        Model(
            id: modelId, name: modelId,
            provider: "openrouter",
            baseUrl: "https://openrouter.ai/api/v1",
            contextWindow: contextWindow, maxTokens: 8_000,
            cost: cost
        )
    }

    // MARK: - Local inference

    static func ollama(modelId: String, contextWindow: Int = 8_000) -> Model {
        Model(
            id: modelId, name: modelId,
            provider: "ollama",
            baseUrl: "http://localhost:11434/v1",
            contextWindow: contextWindow, maxTokens: 4_000,
            cost: .init(input: 0, output: 0)
        )
    }

    static func lmStudio(modelId: String, contextWindow: Int = 8_000) -> Model {
        Model(
            id: modelId, name: modelId,
            provider: "lm-studio",
            baseUrl: "http://localhost:1234/v1",
            contextWindow: contextWindow, maxTokens: 4_000,
            cost: .init(input: 0, output: 0)
        )
    }
}
