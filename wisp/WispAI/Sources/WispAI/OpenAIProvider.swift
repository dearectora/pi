import Foundation

// MARK: - Internal OpenAI SSE chunk types

private struct ChatCompletionChunk: Decodable {
    let id: String?
    let model: String?
    let choices: [Choice]?
    let usage: ChunkUsage?

    struct Choice: Decodable {
        let index: Int
        let delta: Delta
        let finishReason: String?
        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable {
        let role: String?
        let content: String?
        // DeepSeek R1 and llama.cpp use reasoning_content;
        // some other endpoints use reasoning or reasoning_text
        let reasoningContent: String?
        let reasoning: String?
        let reasoningText: String?
        let toolCalls: [ToolCallDelta]?
        enum CodingKeys: String, CodingKey {
            case role, content, reasoning
            case reasoningContent = "reasoning_content"
            case reasoningText    = "reasoning_text"
            case toolCalls        = "tool_calls"
        }
    }

    struct ToolCallDelta: Decodable {
        let index: Int
        let id: String?
        let type: String?
        let function: FunctionDelta?
        struct FunctionDelta: Decodable {
            let name: String?
            let arguments: String?
        }
    }

    struct ChunkUsage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        enum CodingKeys: String, CodingKey {
            case promptTokens    = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
}

// MARK: - Internal accumulation helper

private struct ToolCallAccum {
    var id: String
    var name: String
    var partialArgs: String = ""
}

// MARK: - Message conversion

/// Converts unified Context into the OpenAI Chat Completions messages array.
/// Internal so unit tests can reach it via @testable import.
func convertMessages(_ context: Context) -> [[String: Any]] {
    var result: [[String: Any]] = []

    if let sys = context.systemPrompt {
        result.append(["role": "system", "content": sys])
    }

    for message in context.messages {
        switch message {

        case .user(let msg):
            switch msg.content {
            case .text(let text):
                result.append(["role": "user", "content": text])
            case .parts(let parts):
                let content: [[String: Any]] = parts.map { part in
                    switch part {
                    case .text(let t):
                        return ["type": "text", "text": t.text]
                    case .image(let img):
                        return [
                            "type": "image_url",
                            "image_url": ["url": "data:\(img.mimeType);base64,\(img.data)"]
                        ]
                    }
                }
                result.append(["role": "user", "content": content])
            }

        case .assistant(let msg):
            var entry: [String: Any] = ["role": "assistant"]

            // Collect text parts
            let textParts: [String] = msg.content.compactMap {
                if case .text(let t) = $0 { return t.text }; return nil
            }
            let combined = textParts.joined()
            entry["content"] = combined.isEmpty ? NSNull() : combined

            // Collect tool calls
            let toolCalls: [ToolCall] = msg.content.compactMap {
                if case .toolCall(let tc) = $0 { return tc }; return nil
            }
            if !toolCalls.isEmpty {
                entry["tool_calls"] = toolCalls.map { tc -> [String: Any] in
                    let argsData = (try? JSONSerialization.data(withJSONObject: tc.arguments)) ?? Data()
                    let argsStr  = String(data: argsData, encoding: .utf8) ?? "{}"
                    return [
                        "id": tc.id,
                        "type": "function",
                        "function": ["name": tc.name, "arguments": argsStr]
                    ]
                }
            }

            result.append(entry)

        case .toolResult(let msg):
            let text = msg.content.compactMap { c -> String? in
                if case .text(let t) = c { return t.text }; return nil
            }.joined(separator: "\n")

            result.append([
                "role": "tool",
                "tool_call_id": msg.toolCallId,
                "content": text
            ])
        }
    }

    return result
}

// MARK: - Helpers

/// Maps OpenAI finish_reason strings to unified StopReason.
func mapStopReason(_ finishReason: String?) -> StopReason {
    switch finishReason {
    case "stop", "end": return .stop
    case "length":       return .length
    case "tool_calls", "function_call": return .toolUse
    default:             return .stop
    }
}

/// Calculates total cost in USD.
func calculateCost(model: Model, input: Int, output: Int) -> Double {
    Double(input)  / 1_000_000 * model.cost.input
  + Double(output) / 1_000_000 * model.cost.output
}

// MARK: - Provider

public struct OpenAIProvider: Sendable {

    public init() {}

    /// Returns an AsyncStream that emits AssistantMessageEvents as they arrive.
    /// The stream always terminates with either `.done` or `.error`.
    public func stream(
        model: Model,
        context: Context,
        options: StreamOptions? = nil
    ) -> AsyncStream<AssistantMessageEvent> {
        AsyncStream { continuation in
            let task = Task { await run(model: model, context: context, options: options, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Convenience: waits for the stream to finish and returns the final AssistantMessage.
    public func complete(
        model: Model,
        context: Context,
        options: StreamOptions? = nil
    ) async -> AssistantMessage {
        var result: AssistantMessage?
        for await event in stream(model: model, context: context, options: options) {
            switch event {
            case .done(let msg):  result = msg
            case .error(let msg): result = msg
            default: break
            }
        }
        return result ?? AssistantMessage(
            model: model.id, provider: model.provider,
            stopReason: .error, errorMessage: "Stream ended without a result"
        )
    }

    // MARK: - Core streaming loop

    private func run(
        model: Model,
        context: Context,
        options: StreamOptions?,
        continuation: AsyncStream<AssistantMessageEvent>.Continuation
    ) async {
        var output = AssistantMessage(model: model.id, provider: model.provider)

        do {
            let apiKey = resolveApiKey(from: options, provider: model.provider)

            let request = try buildRequest(model: model, context: context, options: options, apiKey: apiKey)
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw WispError.invalidResponse
            }

            if http.statusCode != 200 {
                var body = ""
                for try await byte in asyncBytes { body.append(Character(UnicodeScalar(byte))) }
                let httpError = WispError.httpError(statusCode: http.statusCode, body: body)
                output.appendDiagnostic(
                    type: "http_error",
                    error: httpError,
                    details: ["statusCode": "\(http.statusCode)", "url": request.url?.absoluteString ?? ""]
                )
                throw httpError
            }

            continuation.yield(.start(partial: output))

            // Per-stream accumulation state
            var textAccum: String?
            var textIdx = -1

            var thinkingAccum: String?
            var thinkingIdx = -1

            // streamIndex (from OpenAI) → accumulator + content array index
            var toolAccums:   [Int: ToolCallAccum] = [:]
            var toolIndices:  [Int: Int]            = [:]

            let decoder = JSONDecoder()

            for try await line in asyncBytes.lines {
                guard !Task.isCancelled else { break }
                guard line.hasPrefix("data: ") else { continue }

                let json = String(line.dropFirst(6))
                guard json != "[DONE]" else { break }
                guard let data = json.data(using: .utf8),
                      let chunk = try? decoder.decode(ChatCompletionChunk.self, from: data)
                else { continue }

                // Usage (arrives in the last chunk for most providers)
                if let u = chunk.usage {
                    let inp = u.promptTokens ?? 0
                    let out = u.completionTokens ?? 0
                    output.usage = Usage(
                        input: inp, output: out,
                        cost: .init(total: calculateCost(model: model, input: inp, output: out))
                    )
                }

                guard let choice = chunk.choices?.first else { continue }

                if let fr = choice.finishReason {
                    output.stopReason = mapStopReason(fr)
                }

                let delta = choice.delta

                // ── Text ──────────────────────────────────────────────────
                if let content = delta.content, !content.isEmpty {
                    if textAccum == nil {
                        textAccum = ""
                        textIdx   = output.content.count
                        output.content.append(.text(TextContent(text: "")))
                        continuation.yield(.textStart(contentIndex: textIdx, partial: output))
                    }
                    textAccum! += content
                    output.content[textIdx] = .text(TextContent(text: textAccum!))
                    continuation.yield(.textDelta(contentIndex: textIdx, delta: content, partial: output))
                }

                // ── Thinking (DeepSeek reasoning_content / reasoning / reasoning_text) ──
                let thinkingDelta = delta.reasoningContent ?? delta.reasoning ?? delta.reasoningText
                if let thinking = thinkingDelta, !thinking.isEmpty {
                    if thinkingAccum == nil {
                        thinkingAccum = ""
                        thinkingIdx   = output.content.count
                        output.content.append(.thinking(ThinkingContent(thinking: "")))
                        continuation.yield(.thinkingStart(contentIndex: thinkingIdx, partial: output))
                    }
                    thinkingAccum! += thinking
                    output.content[thinkingIdx] = .thinking(ThinkingContent(thinking: thinkingAccum!))
                    continuation.yield(.thinkingDelta(contentIndex: thinkingIdx, delta: thinking, partial: output))
                }

                // ── Tool calls ────────────────────────────────────────────
                if let tcDeltas = delta.toolCalls {
                    for tc in tcDeltas {
                        let si = tc.index

                        if toolAccums[si] == nil {
                            let accum = ToolCallAccum(id: tc.id ?? "", name: tc.function?.name ?? "")
                            toolAccums[si]  = accum
                            let ci          = output.content.count
                            toolIndices[si] = ci
                            output.content.append(.toolCall(ToolCall(id: accum.id, name: accum.name)))
                            continuation.yield(.toolCallStart(contentIndex: ci, partial: output))
                        }

                        if let id = tc.id, !id.isEmpty           { toolAccums[si]!.id   = id }
                        if let nm = tc.function?.name, !nm.isEmpty { toolAccums[si]!.name = nm }

                        if let args = tc.function?.arguments, !args.isEmpty {
                            toolAccums[si]!.partialArgs += args
                            let ci = toolIndices[si]!
                            continuation.yield(.toolCallDelta(contentIndex: ci, delta: args, partial: output))
                        }
                    }
                }
            }

            // ── Finalize blocks ───────────────────────────────────────────

            if let text = textAccum {
                continuation.yield(.textEnd(contentIndex: textIdx, content: text, partial: output))
            }

            if let thinking = thinkingAccum {
                continuation.yield(.thinkingEnd(contentIndex: thinkingIdx, content: thinking, partial: output))
            }

            for (si, accum) in toolAccums {
                let ci      = toolIndices[si]!
                let parsed  = (try? JSONSerialization.jsonObject(
                    with: Data(accum.partialArgs.utf8)
                ) as? [String: Any]) ?? [:]
                let tc = ToolCall(id: accum.id, name: accum.name, arguments: parsed)
                output.content[ci] = .toolCall(tc)
                continuation.yield(.toolCallEnd(contentIndex: ci, toolCall: tc, partial: output))
            }

            if Task.isCancelled {
                output.stopReason  = .aborted
                output.errorMessage = "Request was cancelled"
                continuation.yield(.error(message: output))
            } else {
                continuation.yield(.done(message: output))
            }

        } catch {
            let cancelled = Task.isCancelled
            output.stopReason   = cancelled ? .aborted : .error
            output.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

            // Only append a new diagnostic if one was not already recorded above (e.g. http_error).
            if output.diagnostics.isEmpty {
                let diagType: String
                var details: [String: String] = [:]
                switch error {
                case WispError.invalidURL(let url):
                    diagType = "invalid_url"
                    details["url"] = url
                case WispError.invalidResponse:
                    diagType = "invalid_response"
                case WispError.cancelled:
                    diagType = "request_cancelled"
                default:
                    diagType = cancelled ? "request_cancelled" : "network_error"
                    if let urlError = error as? URLError {
                        details["code"] = "\(urlError.code.rawValue)"
                    }
                }
                output.appendDiagnostic(type: diagType, error: error, details: details)
            }

            continuation.yield(.error(message: output))
        }

        continuation.finish()
    }

    // MARK: - API key resolution

    /// Resolves the API key using the priority:
    /// 1. Caller-supplied (options.apiKey)
    /// 2. Well-known env var for the provider (e.g. DEEPSEEK_API_KEY)
    /// 3. OPENAI_API_KEY legacy fallback
    private func resolveApiKey(from options: StreamOptions?, provider: String) -> String {
        if let key = options?.apiKey, !key.isEmpty { return key }
        if let envVar = SettingsManager.envVarName(for: provider),
           let env = ProcessInfo.processInfo.environment[envVar], !env.isEmpty { return env }
        return ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    }

    // MARK: - Request builder

    private func buildRequest(
        model: Model,
        context: Context,
        options: StreamOptions?,
        apiKey: String
    ) throws -> URLRequest {
        guard let url = URL(string: "\(model.baseUrl)/chat/completions") else {
            throw WispError.invalidURL(model.baseUrl)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json",    forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)",    forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model":          model.id,
            "messages":       convertMessages(context),
            "stream":         true,
            "stream_options": ["include_usage": true],
        ]

        if let mt = options?.maxTokens    { body["max_tokens"]  = mt }
        if let t  = options?.temperature  { body["temperature"] = t }

        if !context.tools.isEmpty {
            body["tools"] = context.tools.map { tool -> [String: Any] in
                ["type": "function",
                 "function": [
                    "name":        tool.name,
                    "description": tool.description,
                    "parameters":  tool.parameters,
                    "strict":      false
                 ]]
            }
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }
}
