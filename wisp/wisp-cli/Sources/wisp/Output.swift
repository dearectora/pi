import Foundation
import WispAI

// MARK: - Text mode (streaming)

/// Streams text deltas to stdout as they arrive.
/// Prints a trailing newline after the final token and exits with 0.
/// On error exits with 1.
func runTextMode(
    stream: AsyncStream<AssistantMessageEvent>
) async -> Int32 {
    var hadText = false
    for await event in stream {
        switch event {
        case .textDelta(_, let delta, _):
            print(delta, terminator: "")
            flushStdout()
            hadText = true
        case .thinkingDelta(_, let delta, _):
            // Print thinking to stderr so it doesn't pollute stdout pipeline.
            fputs(delta, stderr)
        case .done:
            if hadText { print() } // trailing newline
            return 0
        case .error(let msg):
            let desc = msg.errorMessage ?? "unknown error"
            fputs("\nError: \(desc)\n", stderr)
            if let diag = msg.diagnostics.first {
                fputs("  [\(diag.type)] \(diag.error?.message ?? "")\n", stderr)
            }
            return 1
        default:
            break
        }
    }
    return 0
}

// MARK: - JSON mode (newline-delimited)

/// Emits one JSON object per line to stdout for every event.
/// Mirrors the --mode json output of the original pi coding-agent.
func runJsonMode(
    stream: AsyncStream<AssistantMessageEvent>
) async -> Int32 {
    var exitCode: Int32 = 0
    for await event in stream {
        if let line = encodeEvent(event) {
            print(line)
            flushStdout()
        }
        switch event {
        case .error: exitCode = 1
        default: break
        }
    }
    return exitCode
}

// MARK: - Event → JSON

private func encodeEvent(_ event: AssistantMessageEvent) -> String? {
    var dict: [String: Any]
    switch event {
    case .start(let partial):
        dict = ["type": "start", "model": partial.model, "provider": partial.provider]

    case .textStart(let idx, _):
        dict = ["type": "textStart", "index": idx]

    case .textDelta(let idx, let delta, _):
        dict = ["type": "textDelta", "index": idx, "delta": delta]

    case .textEnd(let idx, let content, _):
        dict = ["type": "textEnd", "index": idx, "content": content]

    case .thinkingStart(let idx, _):
        dict = ["type": "thinkingStart", "index": idx]

    case .thinkingDelta(let idx, let delta, _):
        dict = ["type": "thinkingDelta", "index": idx, "delta": delta]

    case .thinkingEnd(let idx, let content, _):
        dict = ["type": "thinkingEnd", "index": idx, "content": content]

    case .toolCallStart(let idx, _):
        dict = ["type": "toolCallStart", "index": idx]

    case .toolCallDelta(let idx, let delta, _):
        dict = ["type": "toolCallDelta", "index": idx, "delta": delta]

    case .toolCallEnd(let idx, let tc, _):
        dict = [
            "type": "toolCallEnd",
            "index": idx,
            "id": tc.id,
            "name": tc.name,
            "arguments": tc.arguments,
        ]

    case .done(let msg):
        dict = encodeMessage(type: "done", msg: msg)

    case .error(let msg):
        dict = encodeMessage(type: "error", msg: msg)
    }

    return jsonLine(dict)
}

private func encodeMessage(type: String, msg: AssistantMessage) -> [String: Any] {
    var d: [String: Any] = [
        "type":       type,
        "model":      msg.model,
        "provider":   msg.provider,
        "stopReason": msg.stopReason.rawValue,
        "usage": [
            "input":  msg.usage.input,
            "output": msg.usage.output,
            "cost":   msg.usage.cost.total,
        ],
    ]
    if let err = msg.errorMessage { d["errorMessage"] = err }
    if !msg.diagnostics.isEmpty {
        d["diagnostics"] = msg.diagnostics.map { diag -> [String: Any] in
            var entry: [String: Any] = ["type": diag.type]
            if let e = diag.error {
                var errDict: [String: Any] = ["message": e.message]
                if let name = e.name { errDict["name"] = name }
                if let code = e.code { errDict["code"] = code }
                entry["error"] = errDict
            }
            if !diag.details.isEmpty { entry["details"] = diag.details }
            return entry
        }
    }
    return d
}

private func jsonLine(_ dict: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(
        withJSONObject: dict,
        options: [.sortedKeys]
    ) else { return nil }
    return String(data: data, encoding: .utf8)
}

// MARK: - Helpers

private func flushStdout() {
    fflush(stdout)
}

func stdinIsTTY() -> Bool {
    isatty(FileHandle.standardInput.fileDescriptor) != 0
}

func readStdin() -> String {
    var lines: [String] = []
    while let line = readLine(strippingNewline: false) {
        lines.append(line)
    }
    return lines.joined().trimmingCharacters(in: .newlines)
}
