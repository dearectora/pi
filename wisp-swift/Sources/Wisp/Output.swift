import Foundation
import WispAI

// MARK: - Text mode

@discardableResult
func runTextMode(_ events: AsyncThrowingStream<AssistantMessageEvent, Error>) async -> (Int, AssistantMessage?) {
    var finalMsg: AssistantMessage?
    var exitCode = 0
    do {
        for try await event in events {
            switch event.type {
            case .textDelta:
                print(event.delta, terminator: "")
            case .textEnd:
                print()
            case .thinkingDelta:
                fputs(event.delta, stderr)
            case .thinkingEnd:
                fputs("\n", stderr)
            case .done:
                finalMsg = event.message
            case .error:
                finalMsg = event.message
                if let msg = event.message {
                    fputs("Error: \(msg.errorMessage ?? msg.stopReason.rawValue)\n", stderr)
                }
                exitCode = 1
            default:
                break
            }
        }
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        exitCode = 1
    }
    return (exitCode, finalMsg)
}

// MARK: - JSON mode

@discardableResult
func runJSONMode(_ events: AsyncThrowingStream<AssistantMessageEvent, Error>) async -> (Int, AssistantMessage?) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var finalMsg: AssistantMessage?
    var exitCode = 0
    do {
        for try await event in events {
            if let data = try? encoder.encode(event),
               let line = String(data: data, encoding: .utf8) {
                print(line)
            }
            if event.type == .done  { finalMsg = event.message }
            if event.type == .error { finalMsg = event.message; exitCode = 1 }
        }
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        exitCode = 1
    }
    return (exitCode, finalMsg)
}
