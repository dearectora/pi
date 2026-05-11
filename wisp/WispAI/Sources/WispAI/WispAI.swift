import Foundation

/// WispAI — lightweight OpenAI-compatible LLM client.
///
/// Settings are loaded automatically on first use from:
/// - `~/.pi/agent/settings.json`  (global, respects `PI_CODING_AGENT_DIR`)
/// - `.pi/settings.json`           (project, relative to the working directory)
///
/// Usage:
/// ```swift
/// // Key from settings or OPENAI_API_KEY env var — no explicit apiKey needed:
/// let msg = await WispAI.complete(
///     model: .gpt4oMini,
///     context: Context(messages: [.user(UserMessage(text: "Hi!"))])
/// )
///
/// // Override with explicit key:
/// let msg = await WispAI.complete(
///     model: .gpt4oMini,
///     context: Context(messages: [.user(UserMessage(text: "Hi!"))]),
///     options: StreamOptions(apiKey: "sk-...")
/// )
/// ```
public enum WispAI {

    private static let provider = OpenAIProvider()

    /// Shared settings manager, loaded once from the pi config files.
    /// Reload by calling `WispAI.reloadSettings()`.
    public private(set) static var settings: SettingsManager = .load()

    /// Re-reads settings from disk, picking up any changes since launch.
    public static func reloadSettings(
        cwd:         String  = FileManager.default.currentDirectoryPath,
        globalPath:  String? = nil,
        projectPath: String? = nil
    ) {
        settings = .load(cwd: cwd, globalPath: globalPath, projectPath: projectPath)
    }

    /// Returns an AsyncStream of events. Always terminates with `.done` or `.error`.
    /// Missing `options.apiKey` is resolved from settings / environment.
    public static func stream(
        model:   Model,
        context: Context,
        options: StreamOptions? = nil
    ) -> AsyncStream<AssistantMessageEvent> {
        let resolved = settings.resolve(options: options, for: model)
        return provider.stream(model: model, context: context, options: resolved)
    }

    /// Awaits the full response and returns the final AssistantMessage.
    /// Missing `options.apiKey` is resolved from settings / environment.
    public static func complete(
        model:   Model,
        context: Context,
        options: StreamOptions? = nil
    ) async -> AssistantMessage {
        let resolved = settings.resolve(options: options, for: model)
        return await provider.complete(model: model, context: context, options: resolved)
    }
}
