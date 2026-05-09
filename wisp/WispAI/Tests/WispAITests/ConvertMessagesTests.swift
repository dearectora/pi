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
        XCTAssertNotNil(fn?["arguments"])
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
