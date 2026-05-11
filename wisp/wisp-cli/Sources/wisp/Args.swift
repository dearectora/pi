// Argument parser — hand-crafted, no external dependencies.
// Mirrors the approach used in packages/coding-agent/src/cli/args.ts.

struct Args {
    var help: Bool = false
    var version: Bool = false

    /// Model id, e.g. "gpt-4o-mini" (--model / -m)
    var model: String?
    /// Provider id, e.g. "deepseek" (--provider / -p)
    var provider: String?
    /// API key override (--api-key / -k)
    var apiKey: String?
    /// Sampling temperature 0.0–2.0 (--temperature)
    var temperature: Double?
    /// Max output tokens (--max-tokens)
    var maxTokens: Int?

    /// Output mode: text (default) or json (--mode json / --json)
    var jsonMode: Bool = false

    /// Prompt collected from positional arguments.
    /// nil means "read from stdin".
    var prompt: String?

    /// Warnings produced during parsing (unknown flags etc.)
    var warnings: [String] = []

    init(_ argv: some Collection<String>) {
        var promptParts: [String] = []
        var i = argv.startIndex

        while i < argv.endIndex {
            let arg = argv[i]

            // Check for --flag=value form first
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                let flag = String(arg[arg.startIndex ..< eq])
                let val  = String(arg[arg.index(after: eq)...])
                consume(flag: flag, value: val, promptParts: &promptParts)
                i = argv.index(after: i)
                continue
            }

            switch arg {
            case "-h", "--help":
                help = true

            case "-v", "--version":
                version = true

            case "--json":
                jsonMode = true

            case "-m", "--model",
                 "-p", "--provider",
                 "-k", "--api-key",
                 "--temperature", "--max-tokens",
                 "--mode":
                let next = argv.index(after: i)
                if next < argv.endIndex {
                    consume(flag: arg, value: String(argv[next]), promptParts: &promptParts)
                    i = argv.index(after: next)
                    continue
                } else {
                    warnings.append("Flag \(arg) requires a value")
                }

            default:
                if arg.hasPrefix("-") {
                    warnings.append("Unknown flag: \(arg)")
                } else {
                    promptParts.append(arg)
                }
            }

            i = argv.index(after: i)
        }

        if !promptParts.isEmpty {
            prompt = promptParts.joined(separator: " ")
        }
    }

    private mutating func consume(flag: String, value: String, promptParts: inout [String]) {
        switch flag {
        case "-m", "--model":    model    = value
        case "-p", "--provider": provider = value
        case "-k", "--api-key":  apiKey   = value
        case "--temperature":
            if let d = Double(value) { temperature = d }
            else { warnings.append("Invalid temperature: \(value)") }
        case "--max-tokens":
            if let n = Int(value) { maxTokens = n }
            else { warnings.append("Invalid max-tokens: \(value)") }
        case "--mode":
            if value == "json" { jsonMode = true }
            else if value != "text" { warnings.append("Unknown mode: \(value) (use text or json)") }
        default:
            break
        }
    }
}

// MARK: - Help text

func printHelp() {
    print("""
    Usage: wisp [options] [prompt]

    Options:
      -m, --model <id>         Model id (e.g. gpt-4o-mini, deepseek-reasoner)
      -p, --provider <name>    Provider (e.g. openai, deepseek, groq)
      -k, --api-key <key>      API key (overrides settings and env var)
          --temperature <n>    Sampling temperature 0.0–2.0
          --max-tokens <n>     Maximum output tokens
          --mode <text|json>   Output mode (default: text)
          --json               Shorthand for --mode json
      -h, --help               Show this help
      -v, --version            Show version

    Input:
      Pass the prompt as a positional argument, or pipe it via stdin.

    Settings:
      ~/.pi/agent/settings.json   Global (defaultModel, defaultProvider, apiKeys…)
      .pi/settings.json           Project-local overrides

    Environment variables:
      OPENAI_API_KEY, DEEPSEEK_API_KEY, GROQ_API_KEY, XAI_API_KEY,
      MINIMAX_API_KEY, CEREBRAS_API_KEY, OPENROUTER_API_KEY, …

    Examples:
      wisp "What is the capital of France?"
      wisp -m deepseek-reasoner "Solve: x² + 5x + 6 = 0"
      wisp -p groq -m llama-3.3-70b-versatile "Explain monads"
      echo "Summarise this text" | wisp
      wisp --mode json "Tell me a joke"
      wisp --temperature 0.2 --max-tokens 256 "Write a haiku"
    """)
}
