import XCTest
@testable import WispAI

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
