import XCTest
@testable import WispAI

final class StopReasonTests: XCTestCase {

    func testStop() {
        XCTAssertEqual(mapStopReason("stop"),    .stop)
        XCTAssertEqual(mapStopReason("end"),     .stop)
        XCTAssertEqual(mapStopReason(nil),       .stop)
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
        // $0.55/M input, $2.19/M output → $2.74 total
        let cost = calculateCost(model: .deepSeekReasoner, input: 1_000_000, output: 1_000_000)
        XCTAssertEqual(cost, 2.74, accuracy: 0.001)
    }
}
