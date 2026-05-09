import XCTest
@testable import WispAI

final class ConvertMessagesTests: XCTestCase {

    // MARK: System prompt

    func testSystemPromptAppearsFirst() {
        let ctx = Context(systemPrompt: "You are helpful", messages: [])
        let msgs = convertMessages(ctx)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0]["role"] as? String, "system")
        XCTAssertEqual(msgs[0]["content"] as? String, "You are helpful")
    }

    func testNoSystemPromptWhenNil() {
        let ctx = Context(messages: [.user(UserMessage(text: "hi"))])
        let msgs = convertMessages(ctx)
        XCTAssertFalse(msgs.contains(where: { $0["role"] as? String == "system" }))
    }

    // MARK: User messages

    func testUserTextMessage() {
        let ctx = Context(messages: [.user(UserMessage(text: "Hello"))])
        let msgs = convertMessages(ctx)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0]["role"] as? String, "user")
        XCTAssertEqual(msgs[0]["content"] as? String, "Hello")
    }

    func testUserMultipartTextOnly() {
        let ctx = Context(messages: [
            .user(UserMessage(parts: [
                .text(TextContent(text: "Part A")),
                .text(TextContent(text: "Part B"))
            ]))
        ])
        let msgs = convertMessages(ctx)
        let content = msgs[0]["content"] as? [[String: Any]]
        XCTAssertEqual(content?.count, 2)
        XCTAssertEqual(content?[0]["type"] as? String, "text")
        XCTAssertEqual(content?[0]["text"] as? String, "Part A")
    }

    func testUserMultipartWithImage() {
        let ctx = Context(messages: [
            .user(UserMessage(parts: [
                .text(TextContent(text: "Describe this")),
                .image(ImageContent(data: "abc123", mimeType: "image/jpeg"))
            ]))
        ])
        let msgs = convertMessages(ctx)
        let content = msgs[0]["content"] as? [[String: Any]]
        XCTAssertEqual(content?.count, 2)
        XCTAssertEqual(content?[1]["type"] as? String, "image_url")
        let imgUrl = (content?[1]["image_url"] as? [String: String])?["url"]
        XCTAssertEqual(imgUrl, "data:image/jpeg;base64,abc123")
    }

    // MARK: Assistant messages

    func testAssistantTextMessage() {
        let assistant = AssistantMessage(
            content: [.text(TextContent(text: "Sure!"))],
            model: "gpt-4o", provider: "openai"
        )
        let ctx = Context(messages: [.assistant(assistant)])
        let msgs = convertMessages(ctx)
        XCTAssertEqual(msgs[0]["role"] as? String, "assistant")
        XCTAssertEqual(msgs[0]["content"] as? String, "Sure!")
    }

    func testAssistantEmptyContentIsNull() {
        let assistant = AssistantMessage(model: "gpt-4o", provider: "openai")
        let ctx = Context(messages: [.assistant(assistant)])
        let msgs = convertMessages(ctx)
        XCTAssertTrue(msgs[0]["content"] is NSNull)
    }

    func testAssistantWithToolCall() {
        let tc = ToolCall(id: "call_abc", name: "search", arguments: ["q": "swift"])
        let assistant = AssistantMessage(
            content: [.toolCall(tc)],
            model: "gpt-4o", provider: "openai"
        )
        let ctx = Context(messages: [.assistant(assistant)])
        let msgs = convertMessages(ctx)

        let toolCalls = msgs[0]["tool_calls"] as? [[String: Any]]
        XCTAssertNotNil(toolCalls)
        XCTAssertEqual(toolCalls?.count, 1)
        XCTAssertEqual(toolCalls?.first?["id"] as? String, "call_abc")
        let fn = toolCalls?.first?["function"] as? [String: String]
        XCTAssertEqual(fn?["name"], "search")
        XCTAssertNotNil(fn?["arguments"]) // JSON string
    }

    func testAssistantTextAndToolCall() {
        let tc = ToolCall(id: "call_xyz", name: "calc", arguments: [:])
        let assistant = AssistantMessage(
            content: [.text(TextContent(text: "Let me check")), .toolCall(tc)],
            model: "gpt-4o", provider: "openai"
        )
        let ctx = Context(messages: [.assistant(assistant)])
        let msgs = convertMessages(ctx)
        XCTAssertEqual(msgs[0]["content"] as? String, "Let me check")
        XCTAssertNotNil(msgs[0]["tool_calls"])
    }

    // MARK: Tool result messages

    func testToolResultMessage() {
        let ctx = Context(messages: [
            .toolResult(ToolResultMessage(toolCallId: "call_abc", text: "42"))
        ])
        let msgs = convertMessages(ctx)
        XCTAssertEqual(msgs[0]["role"] as? String, "tool")
        XCTAssertEqual(msgs[0]["tool_call_id"] as? String, "call_abc")
        XCTAssertEqual(msgs[0]["content"] as? String, "42")
    }

    func testToolResultMultiContent() {
        let result = ToolResultMessage(toolCallId: "call_1", content: [
            .text(TextContent(text: "Line 1")),
            .text(TextContent(text: "Line 2"))
        ])
        let ctx = Context(messages: [.toolResult(result)])
        let msgs = convertMessages(ctx)
        XCTAssertEqual(msgs[0]["content"] as? String, "Line 1\nLine 2")
    }

    // MARK: Full conversation ordering

    func testFullConversation() {
        let ctx = Context(
            systemPrompt: "Be helpful",
            messages: [
                .user(UserMessage(text: "What is 2+2?")),
                .assistant(AssistantMessage(
                    content: [.text(TextContent(text: "4"))],
                    model: "gpt-4o", provider: "openai"
                )),
                .user(UserMessage(text: "Thanks"))
            ]
        )
        let msgs = convertMessages(ctx)
        XCTAssertEqual(msgs.count, 4)
        XCTAssertEqual(msgs[0]["role"] as? String, "system")
        XCTAssertEqual(msgs[1]["role"] as? String, "user")
        XCTAssertEqual(msgs[2]["role"] as? String, "assistant")
        XCTAssertEqual(msgs[3]["role"] as? String, "user")
    }

    func testEmptyContextProducesNoMessages() {
        let msgs = convertMessages(Context())
        XCTAssertTrue(msgs.isEmpty)
    }
}

// MARK: -

final class StopReasonTests: XCTestCase {

    func testStop() {
        XCTAssertEqual(mapStopReason("stop"),   .stop)
        XCTAssertEqual(mapStopReason("end"),    .stop)
        XCTAssertEqual(mapStopReason(nil),      .stop)
        XCTAssertEqual(mapStopReason("unknown"), .stop)
    }

    func testLength() {
        XCTAssertEqual(mapStopReason("length"), .length)
    }

    func testToolUse() {
        XCTAssertEqual(mapStopReason("tool_calls"),    .toolUse)
        XCTAssertEqual(mapStopReason("function_call"), .toolUse)
    }
}

// MARK: -

final class CostCalculationTests: XCTestCase {

    func testZeroCostForFreeModel() {
        XCTAssertEqual(calculateCost(model: .ollama(modelId: "llama3"), input: 10_000, output: 5_000), 0.0)
    }

    func testGPT4oCostOneMillion() {
        // $2.50 input + $10.00 output = $12.50 for 1M+1M tokens
        let cost = calculateCost(model: .gpt4o, input: 1_000_000, output: 1_000_000)
        XCTAssertEqual(cost, 12.50, accuracy: 0.0001)
    }

    func testGPT4oMiniSmallRequest() {
        // 100 input @ $0.15/M = $0.000015
        // 50 output @ $0.60/M = $0.000030 → total $0.000045
        let cost = calculateCost(model: .gpt4oMini, input: 100, output: 50)
        XCTAssertEqual(cost, 0.000045, accuracy: 1e-9)
    }

    func testDeepSeekReasoner() {
        // $0.55/M input, $2.19/M output
        let cost = calculateCost(model: .deepSeekReasoner, input: 1_000_000, output: 1_000_000)
        XCTAssertEqual(cost, 2.74, accuracy: 0.001)
    }
}

// MARK: -

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

// MARK: -

final class TypeSystemTests: XCTestCase {

    func testUsageZero() {
        let u = Usage.zero
        XCTAssertEqual(u.input, 0)
        XCTAssertEqual(u.output, 0)
        XCTAssertEqual(u.cost.total, 0)
    }

    func testUsageValues() {
        let u = Usage(input: 500, output: 200, cost: .init(total: 0.005))
        XCTAssertEqual(u.input, 500)
        XCTAssertEqual(u.output, 200)
        XCTAssertEqual(u.cost.total, 0.005, accuracy: 1e-10)
    }

    func testAssistantMessageDefaults() {
        let msg = AssistantMessage(model: "gpt-4o", provider: "openai")
        XCTAssertTrue(msg.content.isEmpty)
        XCTAssertEqual(msg.stopReason, .stop)
        XCTAssertNil(msg.errorMessage)
    }

    func testAssistantMessageError() {
        let msg = AssistantMessage(
            model: "gpt-4o", provider: "openai",
            stopReason: .error, errorMessage: "timeout"
        )
        XCTAssertEqual(msg.stopReason, .error)
        XCTAssertEqual(msg.errorMessage, "timeout")
    }

    func testContextDefaults() {
        let ctx = Context()
        XCTAssertNil(ctx.systemPrompt)
        XCTAssertTrue(ctx.messages.isEmpty)
        XCTAssertTrue(ctx.tools.isEmpty)
    }

    func testToolDefinition() {
        let tool = Tool(
            name: "get_weather",
            description: "Get current weather for a city",
            parameters: ["type": "object", "properties": ["city": ["type": "string"]]]
        )
        XCTAssertEqual(tool.name, "get_weather")
        XCTAssertFalse(tool.description.isEmpty)
    }

    func testStopReasonRawValues() {
        XCTAssertEqual(StopReason.stop.rawValue,    "stop")
        XCTAssertEqual(StopReason.length.rawValue,  "length")
        XCTAssertEqual(StopReason.toolUse.rawValue, "toolUse")
        XCTAssertEqual(StopReason.error.rawValue,   "error")
        XCTAssertEqual(StopReason.aborted.rawValue, "aborted")
    }
}

// MARK: -

final class EventStreamTests: XCTestCase {

    func testEventsDeliveredInOrder() async {
        var received: [Int] = []
        let stream = AsyncStream<Int> { cont in
            for i in 1...5 { cont.yield(i) }
            cont.finish()
        }
        for await v in stream { received.append(v) }
        XCTAssertEqual(received, [1, 2, 3, 4, 5])
    }

    func testDoneEventIsLast() async {
        let events: [AssistantMessageEvent] = [
            .start(partial: AssistantMessage(model: "m", provider: "p")),
            .textStart(contentIndex: 0, partial: AssistantMessage(model: "m", provider: "p")),
            .textDelta(contentIndex: 0, delta: "Hi", partial: AssistantMessage(model: "m", provider: "p")),
            .textEnd(contentIndex: 0, content: "Hi", partial: AssistantMessage(model: "m", provider: "p")),
            .done(message: AssistantMessage(
                content: [.text(TextContent(text: "Hi"))],
                model: "m", provider: "p"
            ))
        ]
        let stream = AsyncStream<AssistantMessageEvent> { cont in
            events.forEach { cont.yield($0) }
            cont.finish()
        }
        var collected: [AssistantMessageEvent] = []
        for await e in stream { collected.append(e) }

        XCTAssertEqual(collected.count, 5)
        if case .done(let msg) = collected.last {
            XCTAssertEqual(msg.model, "m")
        } else {
            XCTFail("Last event should be .done")
        }
    }

    func testErrorEventCarriesMessage() async {
        let errMsg = AssistantMessage(
            model: "gpt-4o", provider: "openai",
            stopReason: .error, errorMessage: "Network timeout"
        )
        let stream = AsyncStream<AssistantMessageEvent> { cont in
            cont.yield(.error(message: errMsg))
            cont.finish()
        }
        var last: AssistantMessageEvent?
        for await e in stream { last = e }

        if case .error(let msg) = last {
            XCTAssertEqual(msg.stopReason, .error)
            XCTAssertEqual(msg.errorMessage, "Network timeout")
        } else {
            XCTFail("Expected .error event")
        }
    }

    func testStreamCancellation() async {
        let stream = AsyncStream<Int> { cont in
            Task {
                for i in 0...1_000_000 {
                    guard !Task.isCancelled else { cont.finish(); return }
                    cont.yield(i)
                }
                cont.finish()
            }
        }
        var count = 0
        let task = Task {
            for await _ in stream {
                count += 1
                if count >= 3 { break }
            }
        }
        await task.value
        XCTAssertLessThanOrEqual(count, 3)
    }
}

// MARK: -

final class WispErrorTests: XCTestCase {

    func testInvalidURLDescription() {
        let err = WispError.invalidURL("not-a-url")
        XCTAssertTrue(err.errorDescription?.contains("not-a-url") == true)
    }

    func testHTTPErrorDescription() {
        let err = WispError.httpError(statusCode: 401, body: "Unauthorized")
        XCTAssertTrue(err.errorDescription?.contains("401") == true)
        XCTAssertTrue(err.errorDescription?.contains("Unauthorized") == true)
    }

    func testInvalidResponseDescription() {
        let err = WispError.invalidResponse
        XCTAssertNotNil(err.errorDescription)
    }
}

// MARK: -

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

final class ModelRegistryLoadTests: XCTestCase {

    // MARK: Загрузка из строки

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

    // MARK: Загрузка из Data

    func testLoadFromData() throws {
        let data = sampleJSON.data(using: .utf8)!
        let registry = try ModelRegistry.load(from: data)
        XCTAssertEqual(registry.models.count, 3)
    }

    // MARK: Поиск

    func testModelByProviderAndId() throws {
        let registry = try ModelRegistry.load(from: sampleJSON)
        let model = registry.model(provider: "openai", id: "gpt-4o")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.name, "GPT-4o")
    }

    func testModelNotFound() throws {
        let registry = try ModelRegistry.load(from: sampleJSON)
        XCTAssertNil(registry.model(provider: "openai", id: "nonexistent"))
        XCTAssertNil(registry.model(provider: "anthropic", id: "gpt-4o"))
    }

    // MARK: Фильтрация

    func testModelsForProvider() throws {
        let registry = try ModelRegistry.load(from: sampleJSON)
        let openaiModels = registry.models(for: "openai")
        XCTAssertEqual(openaiModels.count, 2)
        XCTAssertTrue(openaiModels.allSatisfy { $0.provider == "openai" })
    }

    func testModelsForUnknownProvider() throws {
        let registry = try ModelRegistry.load(from: sampleJSON)
        XCTAssertTrue(registry.models(for: "anthropic").isEmpty)
    }

    func testProvidersList() throws {
        let registry = try ModelRegistry.load(from: sampleJSON)
        let providers = registry.providers
        XCTAssertEqual(providers.sorted(), ["deepseek", "openai"])
    }

    func testThinkingModels() throws {
        let registry = try ModelRegistry.load(from: sampleJSON)
        let thinking = registry.thinkingModels
        XCTAssertEqual(thinking.count, 1)
        XCTAssertEqual(thinking[0].id, "deepseek-reasoner")
    }

    // MARK: Ошибки

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
        let broken = """
        [{ "id": "x", "name": "X", "provider": "p" }]
        """
        XCTAssertThrowsError(try ModelRegistry.load(from: broken))
    }

    func testInvalidEncodingThrows() {
        // Имитируем ошибку кодировки через прямой вызов с невалидными данными
        let badData = Data([0xFF, 0xFE]) // не валидный JSON
        XCTAssertThrowsError(try ModelRegistry.load(from: badData))
    }

    // MARK: Кодируемость (Codable round-trip)

    func testModelCodableRoundTrip() throws {
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

        XCTAssertEqual(decoded.id,              original.id)
        XCTAssertEqual(decoded.name,            original.name)
        XCTAssertEqual(decoded.provider,        original.provider)
        XCTAssertEqual(decoded.baseUrl,         original.baseUrl)
        XCTAssertEqual(decoded.contextWindow,   original.contextWindow)
        XCTAssertEqual(decoded.maxTokens,       original.maxTokens)
        XCTAssertEqual(decoded.cost.input,      original.cost.input,  accuracy: 1e-9)
        XCTAssertEqual(decoded.cost.output,     original.cost.output, accuracy: 1e-9)
        XCTAssertEqual(decoded.supportsThinking, original.supportsThinking)
    }

    func testRegistryInitFromModels() throws {
        let models = [
            Model(id: "a", name: "A", provider: "p1", baseUrl: "http://x", contextWindow: 1000, maxTokens: 100, cost: .init(input: 0, output: 0)),
            Model(id: "b", name: "B", provider: "p2", baseUrl: "http://y", contextWindow: 2000, maxTokens: 200, cost: .init(input: 1, output: 2))
        ]
        let registry = ModelRegistry(models: models)
        XCTAssertEqual(registry.models.count, 2)
        XCTAssertEqual(registry.providers.sorted(), ["p1", "p2"])
    }

    // MARK: Встроенный бандл

    func testBundledRegistryLoads() throws {
        let registry = try ModelRegistry.bundled()
        XCTAssertGreaterThan(registry.models.count, 0)
    }

    func testBundledContainsExpectedProviders() throws {
        let registry = try ModelRegistry.bundled()
        let providers = registry.providers
        XCTAssertTrue(providers.contains("openai"))
        XCTAssertTrue(providers.contains("deepseek"))
        XCTAssertTrue(providers.contains("minimax"))
        XCTAssertTrue(providers.contains("groq"))
        XCTAssertTrue(providers.contains("xai"))
    }

    func testBundledGPT4o() throws {
        let registry = try ModelRegistry.bundled()
        let model = registry.model(provider: "openai", id: "gpt-4o")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.cost.input, 2.50, accuracy: 1e-9)
    }
}
