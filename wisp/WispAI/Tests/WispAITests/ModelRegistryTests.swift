import XCTest
@testable import WispAI

private let sampleJSON = """
[
  {
    "id": "gpt-4o",
    "name": "GPT-4o",
    "provider": "openai",
    "baseUrl": "https://api.openai.com/v1",
    "contextWindow": 128000,
    "maxTokens": 16384,
    "cost": { "input": 2.50, "output": 10.00 },
    "supportsThinking": false
  },
  {
    "id": "deepseek-reasoner",
    "name": "DeepSeek R1",
    "provider": "deepseek",
    "baseUrl": "https://api.deepseek.com/v1",
    "contextWindow": 64000,
    "maxTokens": 8000,
    "cost": { "input": 0.55, "output": 2.19 },
    "supportsThinking": true
  },
  {
    "id": "gpt-4o-mini",
    "name": "GPT-4o Mini",
    "provider": "openai",
    "baseUrl": "https://api.openai.com/v1",
    "contextWindow": 128000,
    "maxTokens": 16384,
    "cost": { "input": 0.15, "output": 0.60 },
    "supportsThinking": false
  }
]
"""

// MARK: - Загрузка из различных источников

final class ModelRegistryLoadTests: XCTestCase {

    func testLoadFromJSONString() throws {
        let registry = try ModelRegistry.load(from: sampleJSON)
        XCTAssertEqual(registry.models.count, 3)
    }

    func testLoadedModelFields() throws {
        let registry = try ModelRegistry.load(from: sampleJSON)
        let model = registry.models[0]
        XCTAssertEqual(model.id, "gpt-4o")
        XCTAssertEqual(model.name, "GPT-4o")
        XCTAssertEqual(model.provider, "openai")
        XCTAssertEqual(model.baseUrl, "https://api.openai.com/v1")
        XCTAssertEqual(model.contextWindow, 128_000)
        XCTAssertEqual(model.maxTokens, 16_384)
        XCTAssertEqual(model.cost.input,  2.50, accuracy: 1e-9)
        XCTAssertEqual(model.cost.output, 10.00, accuracy: 1e-9)
        XCTAssertFalse(model.supportsThinking)
    }

    func testLoadedThinkingModelFlag() throws {
        let registry = try ModelRegistry.load(from: sampleJSON)
        let r1 = registry.models.first { $0.id == "deepseek-reasoner" }
        XCTAssertNotNil(r1)
        XCTAssertTrue(r1!.supportsThinking)
    }

    func testLoadFromData() throws {
        let data = sampleJSON.data(using: .utf8)!
        let registry = try ModelRegistry.load(from: data)
        XCTAssertEqual(registry.models.count, 3)
    }
}

// MARK: - Поиск и фильтрация

final class ModelRegistryQueryTests: XCTestCase {

    private var registry: ModelRegistry!

    override func setUpWithError() throws {
        registry = try ModelRegistry.load(from: sampleJSON)
    }

    func testModelByProviderAndId() {
        let model = registry.model(provider: "openai", id: "gpt-4o")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.name, "GPT-4o")
    }

    func testModelNotFound() {
        XCTAssertNil(registry.model(provider: "openai", id: "nonexistent"))
        XCTAssertNil(registry.model(provider: "anthropic", id: "gpt-4o"))
    }

    func testModelsForProvider() {
        let openaiModels = registry.models(for: "openai")
        XCTAssertEqual(openaiModels.count, 2)
        XCTAssertTrue(openaiModels.allSatisfy { $0.provider == "openai" })
    }

    func testModelsForUnknownProvider() {
        XCTAssertTrue(registry.models(for: "anthropic").isEmpty)
    }

    func testProvidersList() {
        XCTAssertEqual(registry.providers.sorted(), ["deepseek", "openai"])
    }

    func testThinkingModels() {
        let thinking = registry.thinkingModels
        XCTAssertEqual(thinking.count, 1)
        XCTAssertEqual(thinking[0].id, "deepseek-reasoner")
    }
}

// MARK: - Ошибки парсинга

final class ModelRegistryErrorTests: XCTestCase {

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try ModelRegistry.load(from: "not json")) { error in
            if case ModelRegistryError.decodingFailed = error {
                // ожидаемая ошибка
            } else {
                XCTFail("Ожидалась ModelRegistryError.decodingFailed, получили: \(error)")
            }
        }
    }

    func testEmptyArrayIsValid() throws {
        let registry = try ModelRegistry.load(from: "[]")
        XCTAssertTrue(registry.models.isEmpty)
    }

    func testMissingRequiredField() {
        let broken = #"[{ "id": "x", "name": "X", "provider": "p" }]"#
        XCTAssertThrowsError(try ModelRegistry.load(from: broken))
    }

    func testInvalidDataThrows() {
        let badData = Data([0xFF, 0xFE])
        XCTAssertThrowsError(try ModelRegistry.load(from: badData))
    }
}

// MARK: - Codable round-trip

final class ModelCodableTests: XCTestCase {

    func testModelRoundTrip() throws {
        let original = Model(
            id: "test-model",
            name: "Test Model",
            provider: "test",
            baseUrl: "https://test.api/v1",
            contextWindow: 32_000,
            maxTokens: 4_000,
            cost: .init(input: 1.0, output: 2.0),
            supportsThinking: true
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Model.self, from: encoded)

        XCTAssertEqual(decoded.id,               original.id)
        XCTAssertEqual(decoded.name,             original.name)
        XCTAssertEqual(decoded.provider,         original.provider)
        XCTAssertEqual(decoded.baseUrl,          original.baseUrl)
        XCTAssertEqual(decoded.contextWindow,    original.contextWindow)
        XCTAssertEqual(decoded.maxTokens,        original.maxTokens)
        XCTAssertEqual(decoded.cost.input,       original.cost.input,  accuracy: 1e-9)
        XCTAssertEqual(decoded.cost.output,      original.cost.output, accuracy: 1e-9)
        XCTAssertEqual(decoded.supportsThinking, original.supportsThinking)
    }

    func testRegistryInitFromModels() {
        let models = [
            Model(id: "a", name: "A", provider: "p1", baseUrl: "http://x", contextWindow: 1000, maxTokens: 100, cost: .init(input: 0, output: 0)),
            Model(id: "b", name: "B", provider: "p2", baseUrl: "http://y", contextWindow: 2000, maxTokens: 200, cost: .init(input: 1, output: 2))
        ]
        let registry = ModelRegistry(models: models)
        XCTAssertEqual(registry.models.count, 2)
        XCTAssertEqual(registry.providers.sorted(), ["p1", "p2"])
    }
}

// MARK: - Встроенный бандл

final class ModelRegistryBundleTests: XCTestCase {

    func testBundledRegistryLoads() throws {
        let registry = try ModelRegistry.bundled()
        XCTAssertGreaterThan(registry.models.count, 0)
    }

    func testBundledContainsExpectedProviders() throws {
        let providers = try ModelRegistry.bundled().providers
        XCTAssertTrue(providers.contains("openai"))
        XCTAssertTrue(providers.contains("deepseek"))
        XCTAssertTrue(providers.contains("minimax"))
        XCTAssertTrue(providers.contains("groq"))
        XCTAssertTrue(providers.contains("xai"))
    }

    func testBundledGPT4o() throws {
        let model = try ModelRegistry.bundled().model(provider: "openai", id: "gpt-4o")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.cost.input, 2.50, accuracy: 1e-9)
    }
}
