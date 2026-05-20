import Foundation
import WispAI

let version = "0.1.0"

let sema = DispatchSemaphore(value: 0)
Task {
    await WispMain.run()
    sema.signal()
}
sema.wait()

// MARK: -

enum WispMain {
    static func run() async {
        let argv = Array(CommandLine.arguments.dropFirst())
        let args = parseArgs(argv)

        for w in args.warnings { fputs("Warning: \(w)\n", stderr) }

        if args.help    { printHelp(); exit(0) }
        if args.version { print("wisp \(version)"); exit(0) }

        let config = getConfig()

        if let err = config.loadError {
            fputs("Error loading models.json: \(err.localizedDescription)\n", stderr)
            exit(1)
        }

        // Resolve model
        guard let model = resolveModel(args: args, config: config) else {
            let example = """
{
  "defaultProvider": "openai",
  "defaultModel": "gpt-4o-mini",
  "providers": {
    "openai": {
      "apiKey": "sk-...",
      "models": [{ "id": "gpt-4o-mini", "name": "GPT-4o Mini" }]
    }
  }
}
"""
            fputs("Error: no models loaded.\n\nCreate \(modelsPath()) with your model configuration, for example:\n\n\(example)\n", stderr)
            exit(1)
        }

        // Resolve stream options
        let callerOpts = StreamOptions(
            temperature: args.temperature,
            maxTokens: args.maxTokens
        )
        let opts = config.resolve(callerOpts, for: model)

        guard !opts.apiKey.isEmpty else {
            fputs("Error: no API key found for provider \"\(model.provider)\".\n" +
                  "Add it to ~/.pi/agent/models.json under the provider's \"apiKey\" field.\n", stderr)
            exit(1)
        }

        // RPC mode
        if args.rpcMode {
            let (tools, handler) = defaultTools()
            await runRPC(
                config: config, model: model, options: opts,
                tools: tools, handler: handler,
                initialSystemPrompt: buildSystemPrompt()
            )
            exit(0)
        }

        // Resolve prompt
        let prompt: String
        if !args.prompt.isEmpty {
            prompt = args.prompt
        } else if isatty(STDIN_FILENO) == 0 {
            prompt = readStdin()
        } else {
            fputs("Error: no prompt provided. Run `wisp --help` for usage.\n", stderr)
            exit(1)
        }

        if prompt.isEmpty {
            fputs("Error: no prompt provided. Run `wisp --help` for usage.\n", stderr)
            exit(1)
        }

        // Session logger
        var logger: SessionLogger?
        if !args.noLog {
            logger = SessionLogger(model: model)
            if logger == nil {
                fputs("Warning: could not open session log\n", stderr)
            }
        }
        logger?.logUserMessage(prompt)

        // Stream
        let ctx = Context(messages: [.user(prompt)])
        let events = stream(config: config, model: model, context: ctx, options: opts)

        let (exitCode, finalMsg): (Int, AssistantMessage?)
        if args.jsonMode {
            (exitCode, finalMsg) = await runJSONMode(events)
        } else {
            (exitCode, finalMsg) = await runTextMode(events)
        }

        if let msg = finalMsg { logger?.logAssistantMessage(msg) }
        logger?.close()

        exit(Int32(exitCode))
    }
}

// MARK: - Helpers

func resolveModel(args: Args, config: Config) -> Model? {
    let registry = config.registry
    guard !registry.all().isEmpty else { return nil }

    let provider = args.provider.isEmpty ? config.defaultProvider : args.provider
    let modelID  = args.model.isEmpty    ? config.defaultModel    : args.model

    if !provider.isEmpty && !modelID.isEmpty,
       let m = registry.find(provider: provider, id: modelID) { return m }
    if !modelID.isEmpty,
       let m = registry.findByID(modelID) { return m }
    if !provider.isEmpty,
       let m = registry.forProvider(provider).first { return m }
    return registry.all().first
}

func readStdin() -> String {
    var lines: [String] = []
    while let line = readLine(strippingNewline: false) {
        lines.append(line)
    }
    return lines.joined().trimmingCharacters(in: .newlines)
}
