import Foundation

// MARK: - Public entry point

public func stream(
    config: Config,
    model: Model,
    context: Context,
    options: StreamOptions? = nil
) -> AsyncThrowingStream<AssistantMessageEvent, Error> {
    let resolved = config.resolve(options, for: model)
    return streamOpenAI(model: model, context: context, options: resolved)
}

// MARK: - SSE streaming

func streamOpenAI(
    model: Model,
    context: Context,
    options: StreamOptions
) -> AsyncThrowingStream<AssistantMessageEvent, Error> {
    AsyncThrowingStream { continuation in
        Task {
            do {
                try await doStream(model: model, context: context, options: options, continuation: continuation)
            } catch is CancellationError {
                var msg = makeMsg(model: model)
                msg.stopReason = .aborted
                continuation.yield(AssistantMessageEvent(type: .error, message: msg))
                continuation.finish()
            } catch {
                var msg = makeMsg(model: model)
                msg.stopReason = .error
                msg.appendDiagnostic(type: "stream_error", message: error.localizedDescription)
                continuation.yield(AssistantMessageEvent(type: .error, message: msg))
                continuation.finish()
            }
        }
    }
}

private func makeMsg(model: Model) -> AssistantMessage {
    AssistantMessage(model: model.id, provider: model.provider)
}

private func doStream(
    model: Model,
    context: Context,
    options: StreamOptions,
    continuation: AsyncThrowingStream<AssistantMessageEvent, Error>.Continuation
) async throws {
    var msg = makeMsg(model: model)
    continuation.yield(AssistantMessageEvent(type: .start, partial: msg))

    let body = try buildChatRequest(model: model, context: context, options: options)
    let baseURL = model.baseURL.hasSuffix("/") ? String(model.baseURL.dropLast()) : model.baseURL
    guard let url = URL(string: baseURL + "/chat/completions") else {
        throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(options.apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

    if http.statusCode != 200 {
        var body = ""
        for try await byte in bytes { body.append(Character(UnicodeScalar(byte))) }
        let errMsg = "HTTP \(http.statusCode): \(body.trimmingCharacters(in: .whitespacesAndNewlines))"
        msg.stopReason = .error
        msg.errorMessage = errMsg
        msg.appendDiagnostic(type: "http_error", message: errMsg, details: ["statusCode": "\(http.statusCode)"])
        continuation.yield(AssistantMessageEvent(type: .error, message: msg))
        continuation.finish()
        return
    }

    // --- SSE parse state ---
    var textIdx = -1
    var textBuf = ""
    var thinkingIdx = -1
    var thinkingBuf = ""
    var toolBlocks: [Int: ToolBlock] = [:] // keyed by SSE delta index

    for try await line in bytes.lines {
        try Task.checkCancellation()
        guard line.hasPrefix("data: ") else { continue }
        let data = String(line.dropFirst(6))
        if data == "[DONE]" { break }

        guard let chunk = try? JSONDecoder().decode(SSEChunk.self, from: Data(data.utf8)) else { continue }
        if let m = chunk.model, !m.isEmpty { msg.model = m }
        if let u = chunk.usage {
            let cost = computeCost(model: model, input: u.promptTokens, output: u.completionTokens)
            msg.usage = Usage(input: u.promptTokens, output: u.completionTokens, cost: cost)
        }

        for choice in chunk.choices ?? [] {
            let d = choice.delta

            // Thinking (DeepSeek reasoning_content)
            if let rc = d.reasoningContent, !rc.isEmpty {
                if thinkingIdx == -1 {
                    thinkingIdx = msg.content.count
                    msg.content.append(ContentPart(type: "thinking"))
                    continuation.yield(AssistantMessageEvent(type: .thinkingStart, index: thinkingIdx))
                }
                thinkingBuf += rc
                msg.content[thinkingIdx] = ContentPart(type: "thinking", thinking: thinkingBuf)
                continuation.yield(AssistantMessageEvent(type: .thinkingDelta, index: thinkingIdx, delta: rc))
            }

            // Text content
            if let tc = d.content, !tc.isEmpty {
                if textIdx == -1 {
                    textIdx = msg.content.count
                    msg.content.append(ContentPart(type: "text"))
                    continuation.yield(AssistantMessageEvent(type: .textStart, index: textIdx))
                }
                textBuf += tc
                msg.content[textIdx] = ContentPart(type: "text", text: textBuf)
                continuation.yield(AssistantMessageEvent(type: .textDelta, index: textIdx, delta: tc))
            }

            // Tool calls
            for tc in d.toolCalls ?? [] {
                if toolBlocks[tc.index] == nil {
                    let blk = ToolBlock(contentIdx: msg.content.count, id: tc.id ?? "", name: tc.function?.name ?? "")
                    toolBlocks[tc.index] = blk
                    msg.content.append(ContentPart(type: "toolCall", id: blk.id, name: blk.name))
                    continuation.yield(AssistantMessageEvent(type: .toolCallStart, index: tc.index))
                }
                guard var blk = toolBlocks[tc.index] else { continue }
                if let id = tc.id, !id.isEmpty { blk.id = id }
                if let n = tc.function?.name, !n.isEmpty { blk.name = n }
                if let args = tc.function?.arguments, !args.isEmpty {
                    blk.argBuf += args
                    continuation.yield(AssistantMessageEvent(type: .toolCallDelta, index: tc.index, delta: args))
                }
                msg.content[blk.contentIdx] = ContentPart(type: "toolCall", id: blk.id, name: blk.name, arguments: blk.argBuf)
                toolBlocks[tc.index] = blk
            }

            // Finish reason
            if let fr = choice.finishReason {
                switch fr {
                case "stop":       msg.stopReason = .stop
                case "length":     msg.stopReason = .length
                case "tool_calls": msg.stopReason = .toolUse
                default: break
                }
            }
        }
    }

    // Emit *End events
    if textIdx >= 0 {
        continuation.yield(AssistantMessageEvent(type: .textEnd, index: textIdx, content: textBuf))
    }
    if thinkingIdx >= 0 {
        continuation.yield(AssistantMessageEvent(type: .thinkingEnd, index: thinkingIdx, content: thinkingBuf))
    }
    for (sseIdx, blk) in toolBlocks {
        let part = ContentPart.toolCall(id: blk.id, name: blk.name, arguments: blk.argBuf)
        continuation.yield(AssistantMessageEvent(type: .toolCallEnd, index: sseIdx, part: part))
    }

    continuation.yield(AssistantMessageEvent(type: .done, message: msg))
    continuation.finish()
}

private struct ToolBlock {
    var contentIdx: Int
    var id: String
    var name: String
    var argBuf: String = ""
}

func computeCost(model: Model, input: Int, output: Int) -> Cost {
    let i = Double(input) / 1_000_000 * model.cost.input
    let o = Double(output) / 1_000_000 * model.cost.output
    return Cost(input: i, output: o, total: i + o)
}

// MARK: - Request builder

func buildChatRequest(model: Model, context: Context, options: StreamOptions) throws -> Data {
    var messages: [[String: Any]] = []

    if !context.systemPrompt.isEmpty {
        messages.append(["role": "system", "content": context.systemPrompt])
    }

    for m in context.messages {
        switch m.role {
        case "user":
            messages.append(["role": "user", "content": m.content])
        case "assistant":
            var msg: [String: Any] = ["role": "assistant"]
            var text = ""
            var toolCalls: [[String: Any]] = []
            for part in m.parts {
                if part.type == "text" { text += part.text ?? "" }
                if part.type == "toolCall" {
                    toolCalls.append([
                        "id": part.id ?? "",
                        "type": "function",
                        "function": ["name": part.name ?? "", "arguments": part.arguments ?? ""]
                    ])
                }
            }
            if !text.isEmpty { msg["content"] = text }
            if !toolCalls.isEmpty { msg["tool_calls"] = toolCalls }
            messages.append(msg)
        case "tool":
            messages.append([
                "role": "tool",
                "content": m.content,
                "tool_call_id": m.toolCallID ?? ""
            ])
        default: break
        }
    }

    var req: [String: Any] = [
        "model": model.id,
        "messages": messages,
        "stream": true,
        "stream_options": ["include_usage": true]
    ]
    if let t = options.temperature { req["temperature"] = t }
    if let n = options.maxTokens   { req["max_tokens"] = n }

    if !context.tools.isEmpty {
        let toolsJSON: [[String: Any]] = context.tools.compactMap { tool in
            let params = (try? JSONSerialization.jsonObject(with: tool.parameters)) ?? [String: Any]()
            return [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": params
                ]
            ]
        }
        req["tools"] = toolsJSON
    }

    return try JSONSerialization.data(withJSONObject: req)
}

// MARK: - SSE wire types

private struct SSEChunk: Decodable {
    let model: String?
    let choices: [SSEChoice]?
    let usage: SSEUsage?
}

private struct SSEChoice: Decodable {
    let delta: SSEDelta
    let finishReason: String?
    enum CodingKeys: String, CodingKey { case delta; case finishReason = "finish_reason" }
}

private struct SSEDelta: Decodable {
    let content: String?
    let reasoningContent: String?
    let toolCalls: [SSEToolCall]?
    enum CodingKeys: String, CodingKey {
        case content
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
    }
}

private struct SSEToolCall: Decodable {
    let index: Int
    let id: String?
    let function: SSEFunction?
    struct SSEFunction: Decodable { let name: String?; let arguments: String? }
}

private struct SSEUsage: Decodable {
    let promptTokens: Int
    let completionTokens: Int
    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }
}
