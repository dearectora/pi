import XCTest
@testable import WispAI

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
