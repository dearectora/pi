import XCTest
@testable import WispAI

final class EventStreamTests: XCTestCase {

    // Raw AsyncStream ordering — independent of any provider.
    func testEventsDeliveredInOrder() async {
        var received: [Int] = []
        let stream = AsyncStream<Int> { cont in
            for i in 1...5 { cont.yield(i) }
            cont.finish()
        }
        for await v in stream { received.append(v) }
        XCTAssertEqual(received, [1, 2, 3, 4, 5])
    }

    // The last event from FauxProvider must always be .done for a successful response.
    func testDoneEventIsLast() async {
        let faux = FauxProvider()
        await faux.setResponses([.message(FauxProvider.response(text: "Hi"))])

        var events: [AssistantMessageEvent] = []
        for await e in await faux.stream(context: Context()) { events.append(e) }

        XCTAssertFalse(events.isEmpty)
        if case .done(let msg) = events.last {
            XCTAssertEqual(msg.provider, Model.faux.provider)
        } else {
            XCTFail("Last event should be .done, got \(String(describing: events.last))")
        }
    }

    // An error response must produce a terminal .error event (not .done).
    func testErrorEventCarriesMessage() async {
        let faux = FauxProvider()
        await faux.setResponses([.message(
            FauxProvider.response(text: "", stopReason: .error, errorMessage: "Network timeout")
        )])

        var lastEvent: AssistantMessageEvent?
        for await e in await faux.stream(context: Context()) { lastEvent = e }

        if case .error(let msg) = lastEvent {
            XCTAssertEqual(msg.stopReason, .error)
            XCTAssertEqual(msg.errorMessage, "Network timeout")
        } else {
            XCTFail("Expected .error event, got \(String(describing: lastEvent))")
        }
    }

    // Events arrive in the canonical order: start → content events → done.
    func testEventOrderIsCanonical() async {
        let faux = FauxProvider()
        await faux.setResponses([.message(FauxProvider.response(thinking: "think", text: "answer"))])

        var kinds: [String] = []
        for await event in await faux.stream(context: Context()) {
            switch event {
            case .start:         kinds.append("start")
            case .thinkingStart: kinds.append("thinkingStart")
            case .thinkingDelta: kinds.append("thinkingDelta")
            case .thinkingEnd:   kinds.append("thinkingEnd")
            case .textStart:     kinds.append("textStart")
            case .textDelta:     kinds.append("textDelta")
            case .textEnd:       kinds.append("textEnd")
            case .done:          kinds.append("done")
            default:             kinds.append("other")
            }
        }

        XCTAssertEqual(kinds.first, "start")
        XCTAssertEqual(kinds.last,  "done")

        let startIdx     = kinds.firstIndex(of: "start")!
        let tStartIdx    = kinds.firstIndex(of: "thinkingStart")!
        let tEndIdx      = kinds.firstIndex(of: "thinkingEnd")!
        let textStartIdx = kinds.firstIndex(of: "textStart")!
        let textEndIdx   = kinds.firstIndex(of: "textEnd")!
        let doneIdx      = kinds.firstIndex(of: "done")!

        XCTAssertLessThan(startIdx,      tStartIdx)
        XCTAssertLessThan(tStartIdx,     tEndIdx)
        XCTAssertLessThan(tEndIdx,       textStartIdx)
        XCTAssertLessThan(textStartIdx,  textEndIdx)
        XCTAssertLessThan(textEndIdx,    doneIdx)
    }

    // Raw AsyncStream cancellation — breaking early stops iteration.
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
