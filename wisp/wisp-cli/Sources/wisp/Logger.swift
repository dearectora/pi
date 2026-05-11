import Foundation
import WispAI

// MARK: - Session Logger

/// Writes a JSONL session log to ~/.pi/agent/sessions/<timestamp>_<uuid>.jsonl
/// Format mirrors the original pi session-manager output (version 1 for wisp-cli).
actor SessionLogger {

    private let fileHandle: FileHandle
    private var lastMessageId: String?

    private init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    // MARK: - Factory

    static func open(model: Model) throws -> SessionLogger {
        let sessionsDir = SettingsManager.agentDir + "/sessions"
        try FileManager.default.createDirectory(
            atPath: sessionsDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let sessionId  = UUID().uuidString.lowercased()
        let timestamp  = ISO8601DateFormatter().string(from: Date())
        let safestamp  = timestamp.replacing(":", with: "-").replacing(".", with: "-")
        let filename   = "\(safestamp)_\(sessionId).jsonl"
        let path       = sessionsDir + "/" + filename

        FileManager.default.createFile(atPath: path, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: path) else {
            throw LoggerError.cannotOpenFile(path)
        }

        let logger = SessionLogger(fileHandle: fh)

        let header: [String: Any] = [
            "type":      "session",
            "version":   1,
            "id":        sessionId,
            "timestamp": timestamp,
            "cwd":       FileManager.default.currentDirectoryPath,
            "tool":      "wisp",
            "model":     model.id,
            "provider":  model.provider,
        ]
        try logger.appendEntry(header)
        return logger
    }

    // MARK: - Public API

    func logUserMessage(text: String) throws {
        let id = UUID().uuidString.lowercased()
        let entry: [String: Any] = [
            "type":      "message",
            "id":        id,
            "parentId":  NSNull(),
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "message": [
                "role":    "user",
                "content": text,
            ] as [String: Any],
        ]
        try appendEntry(entry)
        lastMessageId = id
    }

    func logAssistantMessage(_ msg: AssistantMessage) throws {
        let id = UUID().uuidString.lowercased()
        var contentArray: [[String: Any]] = []
        for part in msg.content {
            switch part {
            case .text(let t):
                contentArray.append(["type": "text", "text": t.text])
            case .thinking(let t):
                contentArray.append(["type": "thinking", "thinking": t.thinking])
            case .toolCall(let tc):
                contentArray.append([
                    "type":      "tool_call",
                    "id":        tc.id,
                    "name":      tc.name,
                    "arguments": tc.arguments,
                ])
            }
        }

        var msgDict: [String: Any] = [
            "role":       "assistant",
            "model":      msg.model,
            "provider":   msg.provider,
            "stopReason": msg.stopReason.rawValue,
            "usage": [
                "input":  msg.usage.input,
                "output": msg.usage.output,
                "cost":   msg.usage.cost.total,
            ] as [String: Any],
            "content": contentArray,
        ]
        if let err = msg.errorMessage { msgDict["errorMessage"] = err }
        if !msg.diagnostics.isEmpty {
            msgDict["diagnostics"] = msg.diagnostics.map { d -> [String: Any] in
                var de: [String: Any] = [
                    "type":      d.type,
                    "timestamp": ISO8601DateFormatter().string(from: d.timestamp),
                ]
                if let e = d.error {
                    var errDict: [String: Any] = ["message": e.message]
                    if let n = e.name { errDict["name"] = n }
                    if let c = e.code { errDict["code"] = c }
                    de["error"] = errDict
                }
                if !d.details.isEmpty { de["details"] = d.details }
                return de
            }
        }

        let parentId: Any = lastMessageId as Any? ?? NSNull()
        let entry: [String: Any] = [
            "type":      "message",
            "id":        id,
            "parentId":  parentId,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "message":   msgDict,
        ]
        try appendEntry(entry)
        lastMessageId = id
    }

    func close() {
        try? fileHandle.close()
    }

    // MARK: - Private

    private func appendEntry(_ dict: [String: Any]) throws {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.sortedKeys]
        ) else { throw LoggerError.serializationFailed }

        var line = data
        line.append(0x0A) // newline
        try fileHandle.write(contentsOf: line)
    }
}

enum LoggerError: Error {
    case cannotOpenFile(String)
    case serializationFailed
}

// String helper — available on Linux/macOS 13+.
private extension String {
    func replacing(_ target: Character, with replacement: Character) -> String {
        map { $0 == target ? replacement : $0 }.reduce("") { $0 + String($1) }
    }
}
