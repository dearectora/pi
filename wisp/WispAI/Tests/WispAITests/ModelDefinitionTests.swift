import XCTest
@testable import WispAI

final class ModelDefinitionTests: XCTestCase {

    func testOpenAIModels() {
        XCTAssertEqual(Model.gpt4o.provider, "openai")
        XCTAssertEqual(Model.gpt4o.contextWindow, 128_000)
        XCTAssertFalse(Model.gpt4o.supportsThinking)

        XCTAssertEqual(Model.o4Mini.provider, "openai")
        XCTAssertTrue(Model.o4Mini.supportsThinking)
    }

    func testDeepSeekModels() {
        XCTAssertEqual(Model.deepSeekChat.provider, "deepseek")
        XCTAssertTrue(Model.deepSeekChat.baseUrl.contains("deepseek.com"))
        XCTAssertFalse(Model.deepSeekChat.supportsThinking)

        XCTAssertTrue(Model.deepSeekReasoner.supportsThinking)
        XCTAssertEqual(Model.deepSeekReasoner.id, "deepseek-reasoner")
    }

    func testMiniMaxModels() {
        XCTAssertEqual(Model.miniMaxText01.provider, "minimax")
        XCTAssertEqual(Model.miniMaxText01.contextWindow, 1_000_000)
        XCTAssertFalse(Model.miniMaxText01.supportsThinking)

        XCTAssertTrue(Model.miniMaxM1.supportsThinking)
    }

    func testGroqModels() {
        XCTAssertEqual(Model.groqLlama33_70b.provider, "groq")
        XCTAssertTrue(Model.groqLlama33_70b.baseUrl.contains("groq.com"))

        XCTAssertTrue(Model.groqQwen3_32b.supportsThinking)
    }

    func testXAIModels() {
        XCTAssertEqual(Model.grok3.provider, "xai")
        XCTAssertTrue(Model.grok3.baseUrl.contains("x.ai"))
        XCTAssertFalse(Model.grok3.supportsThinking)

        XCTAssertTrue(Model.grok3Mini.supportsThinking)
    }

    func testLocalModels() {
        let ollama = Model.ollama(modelId: "llama3.2")
        XCTAssertEqual(ollama.baseUrl, "http://localhost:11434/v1")
        XCTAssertEqual(ollama.cost.input,  0)
        XCTAssertEqual(ollama.cost.output, 0)

        let lmStudio = Model.lmStudio(modelId: "phi-4")
        XCTAssertEqual(lmStudio.baseUrl, "http://localhost:1234/v1")
        XCTAssertEqual(lmStudio.provider, "lm-studio")
    }

    func testOpenRouterFactory() {
        let model = Model.openRouter(modelId: "anthropic/claude-3-haiku", contextWindow: 200_000)
        XCTAssertEqual(model.provider, "openrouter")
        XCTAssertTrue(model.baseUrl.contains("openrouter.ai"))
        XCTAssertEqual(model.contextWindow, 200_000)
    }
}
