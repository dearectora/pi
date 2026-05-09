import Foundation

/// Wisp — lightweight OpenAI-compatible LLM client.
///
/// Usage:
/// ```swift
/// let msg = await Wisp.complete(
///     model: .gpt4oMini,
///     context: Context(messages: [.user(UserMessage(text: "Hi!"))]),
///     options: StreamOptions(apiKey: "sk-...")
/// )
/// ```
public enum Wisp {

    private static let provider = OpenAIProvider()

    /// Returns an AsyncStream of events. Always terminates with `.done` or `.error`.
    public static func stream(
        model: Model,
        context: Context,
        options: StreamOptions? = nil
    ) -> AsyncStream<AssistantMessageEvent> {
        provider.stream(model: model, context: context, options: options)
    }

    /// Awaits the full response and returns the final AssistantMessage.
    public static func complete(
        model: Model,
        context: Context,
        options: StreamOptions? = nil
    ) async -> AssistantMessage {
        await provider.complete(model: model, context: context, options: options)
    }
}
