import XCTest
@testable import WispAI

// MARK: - Text streaming

final class FauxProviderTextTests: XCTestCase {

    func testSimpleTextComplete() async {
        let faux = FauxProvider()
        await faux.setResponses([.message(FauxProvider.response(text: "Hello, world!"))])

        let result = await faux.complete(context: Context())

        XCTAssertEqual(result.stopReason, .stop)
        XCTAssertEqual(result.content.count, 1)
        if case .text(let t) = result.content[0] {
            XCTAssertEqual(t.text, "Hello, world!")
        } else {
            XCTFail("Expected text content")
        }
    }

    func testTextEventSequence() async {
        let faux = FauxProvider()
        await faux.setResponses([.message(FauxProvider.response(text: "Hi"))])

        var events: [AssistantMessageEvent] = []
        for await e in await faux.stream(context: Context()) { events.append(e) }

        guard !events.isEmpty else { XCTFail("No events received"); return }
        if case .start = events.first { } else { XCTFail("First event must be .start") }
        if case .done  = events.last  { } else { XCTFail("Last event must be .done") }

        XCTAssertTrue(events.contains { if case .textStart = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .textDelta = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .textEnd   = $0 { return true }; return false })
    }

    func testDeltasReconstructFullText() async {
        let faux = FauxProvider(chunkSize: 1...2)
        await faux.setResponses([.message(FauxProvider.response(text: "Swift rocks"))])

        var reconstructed = ""
        for await event in await faux.stream(context: Context()) {
            if case .textDelta(_, let delta, _) = event { reconstructed += delta }
        }
        XCTAssertEqual(reconstructed, "Swift rocks")
    }

    func testPartialMessageGrowsDuringStream() async {
        let faux = FauxProvider(chunkSize: 1...3)
        await faux.setResponses([.message(FauxProvider.response(text: "abc"))])

        var lengths: [Int] = []
        for await event in await faux.stream(context: Context()) {
            if case .textDelta(_, _, let partial) = event {
                if case .text(let t) = partial.content.first { lengths.append(t.text.count) }
            }
        }
        // Each successive partial must be at least as long as the previous.
        for i in 1..<lengths.count {
            XCTAssertGreaterThanOrEqual(lengths[i], lengths[i - 1])
        }
    }
}

// MARK: - Thinking content

final class FauxProviderThinkingTests: XCTestCase {

    func testThinkingAndTextBlocks() async {
        let faux = FauxProvider()
        await faux.setResponses([.message(FauxProvider.response(thinking: "Hmm...", text: "Answer"))])

        let result = await faux.complete(context: Context())

        XCTAssertEqual(result.content.count, 2)
        if case .thinking(let t) = result.content[0] {
            XCTAssertEqual(t.thinking, "Hmm...")
        } else { XCTFail("Expected thinking block at index 0") }
        if case .text(let t) = result.content[1] {
            XCTAssertEqual(t.text, "Answer")
        } else { XCTFail("Expected text block at index 1") }
    }

    func testThinkingEventSequence() async {
        let faux = FauxProvider()
        await faux.setResponses([.message(FauxProvider.response(thinking: "...", text: "ok"))])

        var events: [AssistantMessageEvent] = []
        for await e in await faux.stream(context: Context()) { events.append(e) }

        XCTAssertTrue(events.contains { if case .thinkingStart = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .thinkingDelta = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .thinkingEnd   = $0 { return true }; return false })
    }

    func testThinkingDeltasReconstructContent() async {
        let faux = FauxProvider(chunkSize: 1...2)
        await faux.setResponses([.message(FauxProvider.response(thinking: "Deep thought", text: "42"))])

        var reconstructed = ""
        for await event in await faux.stream(context: Context()) {
            if case .thinkingDelta(_, let delta, _) = event { reconstructed += delta }
        }
        XCTAssertEqual(reconstructed, "Deep thought")
    }
}

// MARK: - Tool calls

final class FauxProviderToolCallTests: XCTestCase {

    func testToolCallContent() async {
        let tc = ToolCall(id: "call_1", name: "get_weather", arguments: ["city": "Paris"])
        let faux = FauxProvider()
        await faux.setResponses([.message(FauxProvider.response(toolCalls: [tc]))])

        let result = await faux.complete(context: Context())

        XCTAssertEqual(result.stopReason, .toolUse)
        XCTAssertEqual(result.content.count, 1)
        if case .toolCall(let t) = result.content[0] {
            XCTAssertEqual(t.name, "get_weather")
            XCTAssertEqual(t.id,   "call_1")
            XCTAssertEqual(t.arguments["city"] as? String, "Paris")
        } else { XCTFail("Expected toolCall content") }
    }

    func testToolCallEventSequence() async {
        let tc = ToolCall(id: "x", name: "fn", arguments: [:])
        let faux = FauxProvider()
        await faux.setResponses([.message(FauxProvider.response(toolCalls: [tc]))])

        var events: [AssistantMessageEvent] = []
        for await e in await faux.stream(context: Context()) { events.append(e) }

        XCTAssertTrue(events.contains { if case .toolCallStart = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .toolCallEnd   = $0 { return true }; return false })
        if case .done = events.last { } else { XCTFail("Last event must be .done") }
    }

    func testMultipleToolCalls() async {
        let tc1 = ToolCall(id: "a", name: "search",  arguments: ["q": "swift"])
        let tc2 = ToolCall(id: "b", name: "weather", arguments: ["city": "Berlin"])
        let faux = FauxProvider()
        await faux.setResponses([.message(FauxProvider.response(toolCalls: [tc1, tc2]))])

        let result = await faux.complete(context: Context())
        XCTAssertEqual(result.content.count, 2)
    }
}

// MARK: - Error scenarios

final class FauxProviderErrorTests: XCTestCase {

    func testNoResponsesQueuedReturnsError() async {
        let faux = FauxProvider()
        let result = await faux.complete(context: Context())
        XCTAssertEqual(result.stopReason, .error)
        XCTAssertTrue(result.errorMessage?.contains("No more faux responses") == true)
    }

    func testErrorStopReasonPreserved() async {
        let faux = FauxProvider()
        await faux.setResponses([.message(
            FauxProvider.response(text: "", stopReason: .error, errorMessage: "Upstream timeout")
        )])
        let result = await faux.complete(context: Context())
        XCTAssertEqual(result.stopReason, .error)
        XCTAssertEqual(result.errorMessage, "Upstream timeout")
    }

    func testErrorStopReasonEmitsErrorEvent() async {
        let faux = FauxProvider()
        await faux.setResponses([.message(
            FauxProvider.response(text: "", stopReason: .error, errorMessage: "oops")
        )])

        var lastEvent: AssistantMessageEvent?
        for await e in await faux.stream(context: Context()) { lastEvent = e }

        if case .error(let msg) = lastEvent {
            XCTAssertEqual(msg.stopReason, .error)
            XCTAssertEqual(msg.errorMessage, "oops")
        } else {
            XCTFail("Expected .error event, got \(String(describing: lastEvent))")
        }
    }

    func testErrorEventNotFollowedByDone() async {
        let faux = FauxProvider()
        await faux.setResponses([.message(
            FauxProvider.response(text: "", stopReason: .error, errorMessage: "fail")
        )])

        var doneCount = 0
        for await event in await faux.stream(context: Context()) {
            if case .done = event { doneCount += 1 }
        }
        XCTAssertEqual(doneCount, 0)
    }
}

// MARK: - State management

final class FauxProviderStateTests: XCTestCase {

    func testCallCountIncrements() async {
        let faux = FauxProvider()
        await faux.setResponses([
            .message(FauxProvider.response(text: "one")),
            .message(FauxProvider.response(text: "two")),
        ])
        _ = await faux.complete(context: Context())
        _ = await faux.complete(context: Context())
        let count = await faux.callCount
        XCTAssertEqual(count, 2)
    }

    func testPendingCountDecreases() async {
        let faux = FauxProvider()
        await faux.setResponses([
            .message(FauxProvider.response(text: "a")),
            .message(FauxProvider.response(text: "b")),
        ])
        var pending = await faux.pendingCount
        XCTAssertEqual(pending, 2)
        _ = await faux.complete(context: Context())
        pending = await faux.pendingCount
        XCTAssertEqual(pending, 1)
    }

    func testAppendResponseAddsToQueue() async {
        let faux = FauxProvider()
        await faux.appendResponse(.message(FauxProvider.response(text: "x")))
        let pending = await faux.pendingCount
        XCTAssertEqual(pending, 1)
    }

    func testSetResponsesReplacesExisting() async {
        let faux = FauxProvider()
        await faux.setResponses([.message(FauxProvider.response(text: "old"))])
        await faux.setResponses([
            .message(FauxProvider.response(text: "new1")),
            .message(FauxProvider.response(text: "new2")),
        ])
        let pending = await faux.pendingCount
        XCTAssertEqual(pending, 2)
    }

    func testMultipleResponsesConsumedInOrder() async {
        let faux = FauxProvider()
        await faux.setResponses([
            .message(FauxProvider.response(text: "first")),
            .message(FauxProvider.response(text: "second")),
        ])
        let r1 = await faux.complete(context: Context())
        let r2 = await faux.complete(context: Context())

        if case .text(let t) = r1.content.first { XCTAssertEqual(t.text, "first")  } else { XCTFail() }
        if case .text(let t) = r2.content.first { XCTAssertEqual(t.text, "second") } else { XCTFail() }
    }
}

// MARK: - Response factory

final class FauxProviderFactoryTests: XCTestCase {

    func testFactoryReceivesContext() async {
        let faux = FauxProvider()
        await faux.setResponses([.factory { context, _, _ in
            let userText: String
            if case .user(let m) = context.messages.first, case .text(let t) = m.content {
                userText = t
            } else {
                userText = "?"
            }
            return FauxProvider.response(text: "Echo: \(userText)")
        }])

        let ctx = Context(messages: [.user(UserMessage(text: "hello"))])
        let result = await faux.complete(context: ctx)

        if case .text(let t) = result.content.first {
            XCTAssertEqual(t.text, "Echo: hello")
        } else { XCTFail("Expected text content") }
    }

    func testFactoryReceivesCallCount() async {
        let faux = FauxProvider()
        await faux.setResponses([
            .factory { _, _, count in FauxProvider.response(text: "call \(count)") },
            .factory { _, _, count in FauxProvider.response(text: "call \(count)") },
        ])
        let r1 = await faux.complete(context: Context())
        let r2 = await faux.complete(context: Context())

        if case .text(let t) = r1.content.first { XCTAssertEqual(t.text, "call 1") } else { XCTFail() }
        if case .text(let t) = r2.content.first { XCTAssertEqual(t.text, "call 2") } else { XCTFail() }
    }

    func testFactoryCanReturnToolCall() async {
        let faux = FauxProvider()
        await faux.setResponses([.factory { _, _, _ in
            FauxProvider.response(toolCalls: [ToolCall(id: "tc", name: "lookup", arguments: [:])])
        }])
        let result = await faux.complete(context: Context())
        XCTAssertEqual(result.stopReason, .toolUse)
        if case .toolCall(let tc) = result.content.first {
            XCTAssertEqual(tc.name, "lookup")
        } else { XCTFail("Expected toolCall") }
    }
}

// MARK: - Usage estimation

final class FauxProviderUsageTests: XCTestCase {

    func testUsageIsEstimatedFromContext() async {
        let faux = FauxProvider()
        let ctx = Context(messages: [.user(UserMessage(text: "What is the capital of France?"))])
        await faux.setResponses([.message(FauxProvider.response(text: "Paris"))])

        let result = await faux.complete(context: ctx)
        XCTAssertGreaterThan(result.usage.input,  0)
        XCTAssertGreaterThan(result.usage.output, 0)
    }

    func testExplicitUsageIsPreserved() async {
        let faux = FauxProvider()
        var msg = FauxProvider.response(text: "hi")
        msg.usage = Usage(input: 42, output: 7)
        await faux.setResponses([.message(msg)])

        let result = await faux.complete(context: Context())
        XCTAssertEqual(result.usage.input,  42)
        XCTAssertEqual(result.usage.output, 7)
    }

    func testLongerContextProducesMoreInputTokens() async {
        let faux1 = FauxProvider()
        let faux2 = FauxProvider()
        await faux1.setResponses([.message(FauxProvider.response(text: "ok"))])
        await faux2.setResponses([.message(FauxProvider.response(text: "ok"))])

        let shortCtx = Context(messages: [.user(UserMessage(text: "Hi"))])
        let longCtx  = Context(messages: [.user(UserMessage(text: String(repeating: "word ", count: 200)))])

        let r1 = await faux1.complete(context: shortCtx)
        let r2 = await faux2.complete(context: longCtx)
        XCTAssertGreaterThan(r2.usage.input, r1.usage.input)
    }
}

// MARK: - Model stamping

final class FauxProviderModelTests: XCTestCase {

    func testDefaultModelIsStamped() async {
        let faux = FauxProvider()
        await faux.setResponses([.message(FauxProvider.response(text: "x"))])

        let result = await faux.complete(context: Context())
        XCTAssertEqual(result.model,    Model.faux.id)
        XCTAssertEqual(result.provider, Model.faux.provider)
    }

    func testCustomModelIsStamped() async {
        let custom = Model.groqLlama33_70b
        let faux = FauxProvider(model: custom)
        await faux.setResponses([.message(FauxProvider.response(text: "x"))])

        let result = await faux.complete(context: Context())
        XCTAssertEqual(result.model,    custom.id)
        XCTAssertEqual(result.provider, custom.provider)
    }
}
