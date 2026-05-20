import Foundation
import WispAI

final class SessionLogger {
    private let fileHandle: FileHandle
    private let encoder: JSONEncoder

    init?(model: Model) {
        let dir = (agentDir() as NSString).appendingPathComponent("sessions")
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            fputs("Warning: could not create sessions directory: \(error.localizedDescription)\n", stderr)
            return nil
        }

        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let uuid = UUID().uuidString.lowercased()
        let path = (dir as NSString).appendingPathComponent("\(ts)_\(uuid).jsonl")

        FileManager.default.createFile(atPath: path, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: path) else {
            fputs("Warning: could not open session log at \(path)\n", stderr)
            return nil
        }
        self.fileHandle = fh
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    func logUserMessage(_ text: String) {
        let entry: [String: Any] = [
            "role": "user",
            "content": text,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        writeLine(entry)
    }

    func logAssistantMessage(_ msg: AssistantMessage) {
        guard let data = try? encoder.encode(msg),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        writeLine(obj)
    }

    func close() {
        try? fileHandle.close()
    }

    private func writeLine(_ obj: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var line = data
        line.append(contentsOf: [UInt8(ascii: "\n")])
        fileHandle.write(line)
    }
}
