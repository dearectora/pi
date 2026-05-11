import Foundation

// MARK: - Usage estimation helpers

private func estimateTokens(_ text: String) -> Int {
    max(1, (text.utf8.count + 3) / 4)
}

private func estimateContextTokens(_ context: Context) -> Int {
    var total = 0
    if let sys = context.systemPrompt { total += estimateTokens(sys) }
    for message in context.messages {
        switch message {
        case .user(let m):
            switch m.content {
            case .text(let t): total += estimateTokens(t)
            case .parts(let ps):
                for p in ps {
                    switch p {
                    case .text(let t): total += estimateTokens(t.text)
                    case .image: total += 85
                    }
                }
            }
        case .assistant(let m):
            for c in m.content {
                switch c {
                case .text(let t):     total += estimateTokens(t.text)
                case .thinking(let t): total += estimateTokens(t.thinking)
                case .toolCall(let tc):
                    total += estimateTokens(tc.name)
                    if let d = try? JSONSerialization.data(withJSONObject: tc.arguments),
                       let s = String(data: d, encoding: .utf8) { total += estimateTokens(s) }
                }
            }
        case .toolResult(let m):
            for c in m.content {
                switch c {
                case .text(let t): total += estimateTokens(t.text)
                case .image: total += 85
                }
            }
        }
    }
    return max(1, total)
}

private func estimateOutputTokens(_ message: AssistantMessage) -> Int {
    var total = 0
    for c in message.content {
        switch c {
        case .text(let t):     total += estimateTokens(t.text)
        case .thinking(let t): total += estimateTokens(t.thinking)
        case .toolCall(let tc):
            total += estimateTokens(tc.name)
            if let d = try? JSONSerialization.data(withJSONObject: tc.arguments),
               let s = String(data: d, encoding: .utf8) { total += estimateTokens(s) }
        }
    }
    return max(1, total)
}

// MARK: - Chunk splitting

private func splitIntoChunks(_ text: String, minSize: Int, maxSize: Int) -> [String] {
    guard !text.isEmpty else { return [""] }
    var chunks: [String] = []
    var index = text.startIndex
    let range = max(0, maxSize - minSize)
    while index < text.endIndex {
        let count = minSize + (range > 0 ? Int.random(in: 0...range) : 0)
        let end = text.index(index, offsetBy: count, limitedBy: text.endIndex) ?? text.endIndex
        chunks.append(String(text[index..<end]))
        index = end
    }
    return chunks
}

// MARK: - FauxProvider

/// A mock provider for use in tests. Delivers pre-queued AssistantMessage responses
/// as a realistic stream of AssistantMessageEvents — no HTTP calls involved.
public actor FauxProvider {

    /// A closure that produces a response given context, options, and the current call count.
    public typealias ResponseFactory = @Sendable (Context, StreamOptions?, Int) async -> AssistantMessage

    public enum ResponseStep: Sendable {
        case message(AssistantMessage)
        case factory(ResponseFactory)
    }

    private let fauxModel: Model
    private let minChunkSize: Int
    private let maxChunkSize: Int
    private let tokensPerSecond: Double?

    /// Number of times `stream()` or `complete()` has been called.
    public private(set) var callCount = 0
    private var pendingResponses: [ResponseStep] = []

    public init(
        model: Model = .faux,
        chunkSize: ClosedRange<Int> = 3...5,
        tokensPerSecond: Double? = nil
    ) {
        self.fauxModel = model
        self.minChunkSize = chunkSize.lowerBound
        self.maxChunkSize = max(chunkSize.lowerBound, chunkSize.upperBound)
        self.tokensPerSecond = tokensPerSecond
    }

    // MARK: - Queue management

    public func setResponses(_ steps: [ResponseStep]) {
        pendingResponses = steps
    }

    public func appendResponse(_ step: ResponseStep) {
        pendingResponses.append(step)
    }

    public var pendingCount: Int { pendingResponses.count }

    // MARK: - Public API

    public func stream(
        context: Context,
        options: StreamOptions? = nil
    ) -> AsyncStream<AssistantMessageEvent> {
        callCount += 1
        let currentCallCount = callCount
        let step = pendingResponses.isEmpty ? nil : pendingResponses.removeFirst()
        // Capture value types so the Task below requires no actor isolation.
        let model        = fauxModel
        let minChunk     = minChunkSize
        let maxChunk     = maxChunkSize
        let tps          = tokensPerSecond

        return AsyncStream { continuation in
            Task {
                await FauxProvider.run(
                    step: step,
                    model: model,
                    context: context,
                    options: options,
                    callCount: currentCallCount,
                    minChunkSize: minChunk,
                    maxChunkSize: maxChunk,
                    tokensPerSecond: tps,
                    continuation: continuation
                )
            }
        }
    }

    public func complete(
        context: Context,
        options: StreamOptions? = nil
    ) async -> AssistantMessage {
        var result: AssistantMessage?
        for await event in stream(context: context, options: options) {
            switch event {
            case .done(let msg):  result = msg
            case .error(let msg): result = msg
            default: break
            }
        }
        return result ?? AssistantMessage(
            model: fauxModel.id, provider: fauxModel.provider,
            stopReason: .error, errorMessage: "Faux stream ended without result"
        )
    }

    // MARK: - Core streaming (static to avoid actor re-entrancy)

    private static func run(
        step: ResponseStep?,
        model: Model,
        context: Context,
        options: StreamOptions?,
        callCount: Int,
        minChunkSize: Int,
        maxChunkSize: Int,
        tokensPerSecond: Double?,
        continuation: AsyncStream<AssistantMessageEvent>.Continuation
    ) async {
        guard let step else {
            var err = AssistantMessage(
                model: model.id, provider: model.provider,
                stopReason: .error,
                errorMessage: "No more faux responses queued (call #\(callCount))"
            )
            err.appendDiagnostic(
                type: "no_response_queued",
                message: "FauxProvider response queue was empty",
                details: ["callCount": "\(callCount)"]
            )
            continuation.yield(.error(message: err))
            continuation.finish()
            return
        }

        var message: AssistantMessage
        switch step {
        case .message(let m):    message = m
        case .factory(let factory): message = await factory(context, options, callCount)
        }

        // Stamp model / provider from the faux model.
        message.model    = model.id
        message.provider = model.provider

        // Estimate usage when caller left it at zero.
        if message.usage.input == 0 && message.usage.output == 0 {
            message.usage = Usage(
                input:  estimateContextTokens(context),
                output: estimateOutputTokens(message)
            )
        }

        await streamEvents(
            message: message,
            minChunkSize: minChunkSize,
            maxChunkSize: maxChunkSize,
            tokensPerSecond: tokensPerSecond,
            continuation: continuation
        )
    }

    private static func streamEvents(
        message: AssistantMessage,
        minChunkSize: Int,
        maxChunkSize: Int,
        tokensPerSecond: Double?,
        continuation: AsyncStream<AssistantMessageEvent>.Continuation
    ) async {
        var partial = AssistantMessage(
            model: message.model, provider: message.provider,
            usage: message.usage, stopReason: message.stopReason
        )
        continuation.yield(.start(partial: partial))

        for (index, block) in message.content.enumerated() {
            switch block {

            case .text(let t):
                partial.content.append(.text(TextContent(text: "")))
                continuation.yield(.textStart(contentIndex: index, partial: partial))

                for chunk in splitIntoChunks(t.text, minSize: minChunkSize, maxSize: maxChunkSize) {
                    await yieldDelay(chunk: chunk, tokensPerSecond: tokensPerSecond)
                    guard !Task.isCancelled else {
                        let aborted = makeAborted(partial)
                        continuation.yield(.error(message: aborted))
                        continuation.finish(); return
                    }
                    if case .text(let existing) = partial.content[index] {
                        partial.content[index] = .text(TextContent(text: existing.text + chunk))
                    }
                    continuation.yield(.textDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                continuation.yield(.textEnd(contentIndex: index, content: t.text, partial: partial))

            case .thinking(let t):
                partial.content.append(.thinking(ThinkingContent(thinking: "")))
                continuation.yield(.thinkingStart(contentIndex: index, partial: partial))

                for chunk in splitIntoChunks(t.thinking, minSize: minChunkSize, maxSize: maxChunkSize) {
                    await yieldDelay(chunk: chunk, tokensPerSecond: tokensPerSecond)
                    guard !Task.isCancelled else {
                        let aborted = makeAborted(partial)
                        continuation.yield(.error(message: aborted))
                        continuation.finish(); return
                    }
                    if case .thinking(let existing) = partial.content[index] {
                        partial.content[index] = .thinking(ThinkingContent(thinking: existing.thinking + chunk))
                    }
                    continuation.yield(.thinkingDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                continuation.yield(.thinkingEnd(contentIndex: index, content: t.thinking, partial: partial))

            case .toolCall(let tc):
                partial.content.append(.toolCall(ToolCall(id: tc.id, name: tc.name)))
                continuation.yield(.toolCallStart(contentIndex: index, partial: partial))

                let argsJSON = (try? JSONSerialization.data(withJSONObject: tc.arguments))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

                for chunk in splitIntoChunks(argsJSON, minSize: minChunkSize, maxSize: maxChunkSize) {
                    await yieldDelay(chunk: chunk, tokensPerSecond: tokensPerSecond)
                    guard !Task.isCancelled else {
                        let aborted = makeAborted(partial)
                        continuation.yield(.error(message: aborted))
                        continuation.finish(); return
                    }
                    continuation.yield(.toolCallDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                partial.content[index] = .toolCall(tc)
                continuation.yield(.toolCallEnd(contentIndex: index, toolCall: tc, partial: partial))
            }
        }

        var final = message
        if final.stopReason == .error || final.stopReason == .aborted {
            if final.diagnostics.isEmpty {
                let diagType = final.stopReason == .aborted ? "request_cancelled" : "faux_error"
                final.appendDiagnostic(
                    type: diagType,
                    message: final.errorMessage ?? "Response had stop reason \(final.stopReason.rawValue)"
                )
            }
            continuation.yield(.error(message: final))
        } else {
            continuation.yield(.done(message: final))
        }
        continuation.finish()
    }

    private static func yieldDelay(chunk: String, tokensPerSecond: Double?) async {
        guard let tps = tokensPerSecond, tps > 0 else {
            await Task.yield(); return
        }
        let ns = UInt64(Double(max(1, chunk.utf8.count / 4)) / tps * 1_000_000_000)
        try? await Task.sleep(nanoseconds: ns)
    }

    private static func makeAborted(_ partial: AssistantMessage) -> AssistantMessage {
        var m = partial
        m.stopReason   = .aborted
        m.errorMessage = "Request was cancelled"
        return m
    }
}

// MARK: - Convenience response factories

public extension FauxProvider {

    /// Plain-text response.
    static func response(
        text: String,
        stopReason: StopReason = .stop,
        errorMessage: String? = nil
    ) -> AssistantMessage {
        AssistantMessage(
            content: text.isEmpty ? [] : [.text(TextContent(text: text))],
            model: Model.faux.id, provider: Model.faux.provider,
            stopReason: stopReason, errorMessage: errorMessage
        )
    }

    /// Thinking block followed by a text answer.
    static func response(thinking: String, text: String, stopReason: StopReason = .stop) -> AssistantMessage {
        AssistantMessage(
            content: [
                .thinking(ThinkingContent(thinking: thinking)),
                .text(TextContent(text: text))
            ],
            model: Model.faux.id, provider: Model.faux.provider,
            stopReason: stopReason
        )
    }

    /// One or more tool calls.
    static func response(toolCalls: [ToolCall], stopReason: StopReason = .toolUse) -> AssistantMessage {
        AssistantMessage(
            content: toolCalls.map { .toolCall($0) },
            model: Model.faux.id, provider: Model.faux.provider,
            stopReason: stopReason
        )
    }
}
