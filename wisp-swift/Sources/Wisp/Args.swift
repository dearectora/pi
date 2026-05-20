import Foundation

struct Args {
    var help: Bool = false
    var version: Bool = false
    var model: String = ""
    var provider: String = ""
    var temperature: Double? = nil
    var maxTokens: Int? = nil
    var jsonMode: Bool = false
    var rpcMode: Bool = false
    var noLog: Bool = false
    var prompt: String = ""
    var warnings: [String] = []
}

func parseArgs(_ argv: [String]) -> Args {
    var a = Args()
    var promptParts: [String] = []
    var i = 0

    while i < argv.count {
        let arg = argv[i]

        // --flag=value form
        if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
            let flag = String(arg[..<eq])
            let value = String(arg[arg.index(after: eq)...])
            consumeFlag(&a, flag: flag, value: value)
            i += 1
            continue
        }

        switch arg {
        case "-h", "--help":    a.help = true
        case "-v", "--version": a.version = true
        case "--json":          a.jsonMode = true
        case "--no-log":        a.noLog = true
        case "-m", "--model", "-p", "--provider",
             "--temperature", "--max-tokens", "--mode":
            if i + 1 < argv.count {
                i += 1
                consumeFlag(&a, flag: arg, value: argv[i])
            } else {
                a.warnings.append("flag \(arg) requires a value")
            }
        default:
            if arg.hasPrefix("-") {
                a.warnings.append("unknown flag: \(arg)")
            } else {
                promptParts.append(arg)
            }
        }
        i += 1
    }

    if !promptParts.isEmpty { a.prompt = promptParts.joined(separator: " ") }
    return a
}

private func consumeFlag(_ a: inout Args, flag: String, value: String) {
    switch flag {
    case "-m", "--model":    a.model = value
    case "-p", "--provider": a.provider = value
    case "--temperature":
        if let v = Double(value) { a.temperature = v }
        else { a.warnings.append("invalid temperature: \(value)") }
    case "--max-tokens":
        if let v = Int(value) { a.maxTokens = v }
        else { a.warnings.append("invalid max-tokens: \(value)") }
    case "--mode":
        switch value {
        case "json": a.jsonMode = true
        case "rpc":  a.rpcMode = true
        case "text": break
        default:     a.warnings.append("unknown mode: \(value) (use text, json, or rpc)")
        }
    default: break
    }
}

func printHelp() {
    print("""
Usage: wisp [options] [prompt]

Options:
  -m, --model <id>         Model id (e.g. gpt-4o-mini, deepseek-reasoner)
  -p, --provider <name>    Provider (e.g. openai, deepseek, groq)
      --temperature <n>    Sampling temperature 0.0–2.0
      --max-tokens <n>     Maximum output tokens
      --mode <mode>        Output mode: text (default), json, rpc
      --json               Shorthand for --mode json
      --no-log             Disable JSONL session logging
  -h, --help               Show this help
  -v, --version            Show version

Input:
  Pass the prompt as a positional argument, or pipe it via stdin.
  In rpc mode, commands are read from stdin as JSON Lines.

Settings:
  ~/.pi/agent/models.json     Model definitions, provider API keys, defaults

Examples:
  wisp "What is the capital of France?"
  wisp -m gpt-4o "Write a haiku"
  wisp -p deepseek -m deepseek-reasoner "Solve: x² + 5x + 6 = 0"
  echo "Summarise this" | wisp
  wisp --mode json "Tell me a joke"
  wisp --mode rpc
  wisp --temperature 0.2 --max-tokens 256 "Write a formula"
""")
}
