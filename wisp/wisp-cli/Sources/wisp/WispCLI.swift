import Foundation
import WispAI

let version = "0.1.0"

@main
struct WispCLI {

    static func main() async {
        let args = Args(CommandLine.arguments.dropFirst())

        // Print any parse warnings to stderr before doing anything else.
        for w in args.warnings { fputs("Warning: \(w)\n", stderr) }

        if args.help    { printHelp(); exit(0) }
        if args.version { print("wisp \(version)"); exit(0) }

        // Load settings (global ~/.pi/agent/settings.json + project .pi/settings.json).
        WispAI.reloadSettings()
        let settings = WispAI.settings

        // Resolve prompt: argument > stdin.
        let prompt: String
        if let p = args.prompt {
            prompt = p
        } else if !stdinIsTTY() {
            let stdin = readStdin()
            if stdin.isEmpty {
                fputs("Error: no prompt provided. Run `wisp --help` for usage.\n", stderr)
                exit(1)
            }
            prompt = stdin
        } else {
            fputs("Error: no prompt provided. Run `wisp --help` for usage.\n", stderr)
            exit(1)
        }

        // Resolve model.
        let model = resolveModel(args: args, settings: settings)

        // Build stream options — settings fills in missing apiKey / defaults.
        let callerOptions = StreamOptions(
            apiKey:      args.apiKey,
            temperature: args.temperature,
            maxTokens:   args.maxTokens
        )
        let options = settings.resolve(options: callerOptions, for: model)

        // Validate that we have an API key when the provider needs one.
        if options.apiKey == nil || options.apiKey!.isEmpty {
            if let envVar = SettingsManager.envVarName(for: model.provider) {
                fputs(
                    "Error: no API key found for provider \"\(model.provider)\".\n" +
                    "Set \(envVar) or add it to ~/.pi/agent/settings.json under apiKeys.\n",
                    stderr
                )
                exit(1)
            }
        }

        // Open session logger (unless --no-log).
        let logger: SessionLogger? = args.noLog ? nil : {
            do {
                return try SessionLogger.open(model: model)
            } catch {
                fputs("Warning: could not open session log: \(error)\n", stderr)
                return nil
            }
        }()

        // Log the user message.
        if let logger {
            do { try await logger.logUserMessage(text: prompt) }
            catch { fputs("Warning: session log write failed: \(error)\n", stderr) }
        }

        let ctx = Context(messages: [.user(UserMessage(text: prompt))])
        let stream = WispAI.stream(model: model, context: ctx, options: options)

        let (exitCode, finalMessage) = args.jsonMode
            ? await runJsonMode(stream: stream)
            : await runTextMode(stream: stream)

        // Log the assistant message.
        if let logger, let msg = finalMessage {
            do { try await logger.logAssistantMessage(msg) }
            catch { fputs("Warning: session log write failed: \(error)\n", stderr) }
            await logger.close()
        }

        exit(exitCode)
    }
}

// MARK: - Model resolution

/// Resolves the model to use, in priority order:
///   1. --provider + --model (exact lookup in bundled registry)
///   2. --model only          (first match by id in bundled registry)
///   3. --provider only       (first model for that provider)
///   4. settings.defaultProvider + settings.defaultModel
///   5. Fallback: gpt-4o-mini
func resolveModel(args: Args, settings: SettingsManager) -> Model {
    let effectiveProvider = args.provider ?? settings.settings.defaultProvider
    let effectiveModelId  = args.model    ?? settings.settings.defaultModel

    if let registry = try? ModelRegistry.bundled() {
        // Exact provider + id
        if let pid = effectiveProvider, let mid = effectiveModelId {
            if let m = registry.model(provider: pid, id: mid) { return m }
        }
        // Model id only (any provider)
        if let mid = effectiveModelId {
            if let m = registry.models.first(where: { $0.id == mid }) { return m }
        }
        // Provider only (first available model)
        if let pid = effectiveProvider {
            if let m = registry.models(for: pid).first { return m }
        }
    }

    return .gpt4oMini
}
