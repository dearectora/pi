import Foundation

public typealias ToolHandler = @Sendable (String, String, String) async throws -> String

// MARK: - Agent loop

public func runAgent(
    config: Config,
    model: Model,
    context: Context,
    options: StreamOptions? = nil,
    handler: @escaping ToolHandler,
    agentOptions: AgentOptions? = nil
) -> AsyncThrowingStream<AssistantMessageEvent, Error> {
    AsyncThrowingStream { continuation in
        Task {
            await agentLoop(
                config: config, model: model, context: context,
                options: options, handler: handler,
                agentOptions: agentOptions, continuation: continuation
            )
        }
    }
}

private func agentLoop(
    config: Config,
    model: Model,
    context: Context,
    options: StreamOptions?,
    handler: @escaping ToolHandler,
    agentOptions: AgentOptions?,
    continuation: AsyncThrowingStream<AssistantMessageEvent, Error>.Continuation
) async {
    let maxSteps = agentOptions?.maxSteps ?? 10
    var current = context
    let resolved = config.resolve(options, for: model)

    for _ in 0..<maxSteps {
        if Task.isCancelled { continuation.finish(); return }

        var finalMsg: AssistantMessage?

        do {
            for try await event in streamOpenAI(model: model, context: current, options: resolved) {
                continuation.yield(event)
                if event.type == .done || event.type == .error {
                    finalMsg = event.message
                }
            }
        } catch {
            continuation.finish(throwing: error)
            return
        }

        guard let msg = finalMsg else { continuation.finish(); return }

        if msg.stopReason != .toolUse {
            // For non-tool-use responses, add assistant message to history via onStep
            if msg.stopReason == .stop || msg.stopReason == .length {
                let added = [ContextMessage.assistant(msg)]
                agentOptions?.onStep?(added)
            }
            continuation.finish()
            return
        }

        // Execute tool calls
        var added: [ContextMessage] = [.assistant(msg)]
        for part in msg.content where part.type == "toolCall" {
            let result: String
            do {
                result = try await handler(part.id ?? "", part.name ?? "", part.arguments ?? "")
            } catch {
                result = "error: \(error.localizedDescription)"
            }
            added.append(.toolResult(id: part.id ?? "", content: result))
        }

        current.messages.append(contentsOf: added)
        agentOptions?.onStep?(added)
    }

    // Exceeded max steps
    let errMsg = AssistantMessage(
        model: model.id,
        provider: model.provider,
        stopReason: .error,
        errorMessage: "agent exceeded maximum steps (\(maxSteps))"
    )
    continuation.yield(AssistantMessageEvent(type: .error, message: errMsg))
    continuation.finish()
}
