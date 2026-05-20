import Foundation

// MARK: - Tool executor

public typealias ToolExecutor = @Sendable (String) async throws -> String

public struct RegisteredTool {
    public let tool: Tool
    public let executor: ToolExecutor

    public init(tool: Tool, executor: @escaping ToolExecutor) {
        self.tool = tool; self.executor = executor
    }
}

public func newToolHandler(_ tools: [RegisteredTool]) -> ([Tool], ToolHandler) {
    let defs = tools.map(\.tool)
    let map: [String: ToolExecutor] = Dictionary(uniqueKeysWithValues: tools.map { ($0.tool.name, $0.executor) })
    let handler: ToolHandler = { _, name, arguments in
        guard let fn = map[name] else { throw ToolError.unknown(name) }
        return try await fn(arguments)
    }
    return (defs, handler)
}

public func defaultTools() -> ([Tool], ToolHandler) {
    newToolHandler([bashTool(), readTool(), writeTool(), editTool(), grepTool(), findTool(), lsTool()])
}

enum ToolError: Error, LocalizedError {
    case unknown(String)
    var errorDescription: String? {
        if case .unknown(let n) = self { return "unknown tool: \(n)" }
        return nil
    }
}

// MARK: - Helpers

private let outMaxLines = 300
private let outMaxBytes = 512 * 1024

private func truncateTail(_ s: String) -> String {
    var s = s
    if s.utf8.count > outMaxBytes {
        let start = s.utf8.index(s.utf8.endIndex, offsetBy: -outMaxBytes)
        s = "[output truncated]\n" + String(s.utf8[start...])!
        return s
    }
    let lines = s.components(separatedBy: "\n")
    if lines.count > outMaxLines {
        return "[output truncated]\n" + lines.suffix(outMaxLines).joined(separator: "\n")
    }
    return s
}

private func truncateHead(_ s: String, lineLimit: Int = outMaxLines) -> String {
    if s.utf8.count > outMaxBytes {
        return String(s.prefix(outMaxBytes)) + "\n[output truncated at 512KB]"
    }
    let lines = s.components(separatedBy: "\n")
    if lines.count > lineLimit {
        return lines.prefix(lineLimit).joined(separator: "\n") + "\n[output truncated]"
    }
    return s
}

private func schema(_ s: String) -> Data { Data(s.utf8) }

// MARK: - bash

private func bashTool() -> RegisteredTool {
    RegisteredTool(
        tool: Tool(
            name: "bash",
            description: "Execute a bash command in the current working directory. Returns stdout and stderr combined. Output truncated to last 300 lines or 512KB. Optionally provide a timeout in seconds.",
            parameters: schema("""
{
  "type": "object",
  "properties": {
    "command": { "type": "string", "description": "Bash command to execute" },
    "timeout": { "type": "number", "description": "Timeout in seconds" }
  },
  "required": ["command"]
}
""")
        ),
        executor: { args in
            struct P: Decodable { var command: String; var timeout: Double? }
            let p = (try? JSONDecoder().decode(P.self, from: Data(args.utf8))) ?? P(command: args)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", p.command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()

            if let timeout = p.timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
            }
            let output: String = await withCheckedContinuation { cont in
                process.terminationHandler = { _ in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
                }
            }
            return truncateTail(output)
        }
    )
}

// MARK: - read

private func readTool() -> RegisteredTool {
    RegisteredTool(
        tool: Tool(
            name: "read",
            description: "Read the contents of a file. Output truncated to 300 lines or 512KB. Use offset and limit to page through large files.",
            parameters: schema("""
{
  "type": "object",
  "properties": {
    "path":   { "type": "string", "description": "Path to the file to read" },
    "offset": { "type": "number", "description": "Line number to start reading from (1-indexed)" },
    "limit":  { "type": "number", "description": "Maximum number of lines to read" }
  },
  "required": ["path"]
}
""")
        ),
        executor: { args in
            struct P: Decodable { var path: String; var offset: Int?; var limit: Int? }
            let p = try JSONDecoder().decode(P.self, from: Data(args.utf8))
            let text = try String(contentsOfFile: p.path, encoding: .utf8)
            var lines = text.components(separatedBy: "\n")
            let start = max(0, (p.offset ?? 1) - 1)
            guard start < lines.count else { return "" }
            lines = Array(lines[start...])
            let limit = p.limit ?? outMaxLines
            return truncateHead(lines.joined(separator: "\n"), lineLimit: limit)
        }
    )
}

// MARK: - write

private func writeTool() -> RegisteredTool {
    RegisteredTool(
        tool: Tool(
            name: "write",
            description: "Write content to a file, creating it (and parent directories) if needed. Overwrites existing files.",
            parameters: schema("""
{
  "type": "object",
  "properties": {
    "path":    { "type": "string", "description": "Path to the file to write" },
    "content": { "type": "string", "description": "Content to write" }
  },
  "required": ["path", "content"]
}
""")
        ),
        executor: { args in
            struct P: Decodable { var path: String; var content: String }
            let p = try JSONDecoder().decode(P.self, from: Data(args.utf8))
            let url = URL(fileURLWithPath: p.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try p.content.write(to: url, atomically: true, encoding: .utf8)
            return "Written \(p.content.utf8.count) bytes to \(p.path)"
        }
    )
}

// MARK: - edit

private func editTool() -> RegisteredTool {
    RegisteredTool(
        tool: Tool(
            name: "edit",
            description: "Edit a file using exact text replacement. Each oldText must be unique in the file. All edits are matched against the original file simultaneously — do not emit overlapping edits. Merge nearby changes into one call.",
            parameters: schema("""
{
  "type": "object",
  "properties": {
    "path": { "type": "string", "description": "Path to the file to edit" },
    "edits": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "oldText": { "type": "string", "description": "Exact text to replace (must be unique)" },
          "newText": { "type": "string", "description": "Replacement text" }
        },
        "required": ["oldText", "newText"]
      }
    }
  },
  "required": ["path", "edits"]
}
""")
        ),
        executor: { args in
            struct Edit: Decodable { var oldText: String; var newText: String }
            struct P: Decodable { var path: String; var edits: [Edit] }
            let p = try JSONDecoder().decode(P.self, from: Data(args.utf8))
            var original = try String(contentsOfFile: p.path, encoding: .utf8)

            struct Range { var start: String.Index; var end: String.Index; var newText: String }
            var ranges: [Range] = []
            for (i, edit) in p.edits.enumerated() {
                guard let r = original.range(of: edit.oldText) else {
                    throw EditError.notFound(i + 1)
                }
                let count = original.components(separatedBy: edit.oldText).count - 1
                if count > 1 { throw EditError.notUnique(i + 1, count) }
                ranges.append(Range(start: r.lowerBound, end: r.upperBound, newText: edit.newText))
            }

            // Sort by position and check overlaps
            ranges.sort { $0.start < $1.start }
            for i in 1..<ranges.count {
                if ranges[i].start < ranges[i-1].end { throw EditError.overlap(i, i+1) }
            }

            // Apply from end to beginning
            for r in ranges.reversed() {
                original.replaceSubrange(r.start..<r.end, with: r.newText)
            }
            try original.write(toFile: p.path, atomically: true, encoding: .utf8)
            return "Applied \(p.edits.count) edit(s) to \(p.path)"
        }
    )
}

enum EditError: Error, LocalizedError {
    case notFound(Int)
    case notUnique(Int, Int)
    case overlap(Int, Int)
    var errorDescription: String? {
        switch self {
        case .notFound(let i): return "edit \(i): oldText not found in file"
        case .notUnique(let i, let c): return "edit \(i): oldText matches \(c) locations (must be unique)"
        case .overlap(let i, let j): return "edits \(i) and \(j) overlap — merge them"
        }
    }
}

// MARK: - grep

private func grepTool() -> RegisteredTool {
    RegisteredTool(
        tool: Tool(
            name: "grep",
            description: "Search file contents for a pattern. Returns path:line:content. Output truncated to 100 matches or 512KB.",
            parameters: schema("""
{
  "type": "object",
  "properties": {
    "pattern":    { "type": "string", "description": "Search pattern (regex by default)" },
    "path":       { "type": "string", "description": "Directory or file to search (default: current directory)" },
    "glob":       { "type": "string", "description": "Filter files by glob, e.g. '*.swift'" },
    "ignoreCase": { "type": "boolean", "description": "Case-insensitive search" },
    "literal":    { "type": "boolean", "description": "Treat pattern as literal string, not regex" },
    "limit":      { "type": "number", "description": "Maximum matches to return (default: 100)" }
  },
  "required": ["pattern"]
}
""")
        ),
        executor: { args in
            struct P: Decodable {
                var pattern: String; var path: String?; var glob: String?
                var ignoreCase: Bool?; var literal: Bool?; var limit: Int?
            }
            let p = try JSONDecoder().decode(P.self, from: Data(args.utf8))
            let limit = p.limit ?? 100
            let searchPath = p.path ?? FileManager.default.currentDirectoryPath

            var options: NSRegularExpression.Options = []
            if p.ignoreCase == true { options.insert(.caseInsensitive) }
            let rawPattern = p.literal == true ? NSRegularExpression.escapedPattern(for: p.pattern) : p.pattern
            let re = try NSRegularExpression(pattern: rawPattern, options: options)

            var results: [String] = []
            let enumerator = FileManager.default.enumerator(atPath: searchPath)
            while let relPath = enumerator?.nextObject() as? String {
                guard results.count < limit else { break }
                let fullPath = (searchPath as NSString).appendingPathComponent(relPath)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
                guard !isDir.boolValue else { continue }
                guard !relPath.components(separatedBy: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
                if let glob = p.glob {
                    guard fnmatch(glob, (relPath as NSString).lastPathComponent, 0) == 0 else { continue }
                }
                guard let text = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
                for (i, line) in text.components(separatedBy: "\n").enumerated() {
                    guard results.count < limit else { break }
                    let range = NSRange(line.startIndex..., in: line)
                    if re.firstMatch(in: line, range: range) != nil {
                        let truncLine = line.count > 512 ? String(line.prefix(512)) + "..." : line
                        results.append("\(relPath):\(i + 1):\(truncLine)")
                    }
                }
            }
            return results.isEmpty ? "No matches found" : results.joined(separator: "\n")
        }
    )
}

// MARK: - find

private func findTool() -> RegisteredTool {
    RegisteredTool(
        tool: Tool(
            name: "find",
            description: "Search for files by glob pattern. Supports ** for recursive matching (e.g. '**/*.swift', 'src/**/*.ts').",
            parameters: schema("""
{
  "type": "object",
  "properties": {
    "pattern": { "type": "string", "description": "Glob pattern, e.g. '*.swift', '**/*.json'" },
    "path":    { "type": "string", "description": "Directory to search in (default: current directory)" },
    "limit":   { "type": "number", "description": "Maximum number of results (default: 1000)" }
  },
  "required": ["pattern"]
}
""")
        ),
        executor: { args in
            struct P: Decodable { var pattern: String; var path: String?; var limit: Int? }
            let p = try JSONDecoder().decode(P.self, from: Data(args.utf8))
            let limit = p.limit ?? 1000
            let searchPath = p.path ?? FileManager.default.currentDirectoryPath

            var results: [String] = []
            let enumerator = FileManager.default.enumerator(atPath: searchPath)
            while let relPath = enumerator?.nextObject() as? String {
                guard results.count < limit else { break }
                let fullPath = (searchPath as NSString).appendingPathComponent(relPath)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
                guard !isDir.boolValue else { continue }
                if globMatch(pattern: p.pattern, path: relPath) {
                    results.append(relPath)
                }
            }
            if results.isEmpty { return "No files found" }
            return results.sorted().joined(separator: "\n")
        }
    )
}

private func globMatch(pattern: String, path: String) -> Bool {
    if !pattern.contains("**") {
        return fnmatch(pattern, path, 0) == 0 || fnmatch(pattern, (path as NSString).lastPathComponent, 0) == 0
    }
    let parts = pattern.components(separatedBy: "**")
    let prefix = parts[0]
    var rest = parts.dropFirst().joined(separator: "**")
    if rest.hasPrefix("/") { rest = String(rest.dropFirst()) }

    var remaining = path
    if !prefix.isEmpty {
        guard remaining.hasPrefix(prefix) else { return false }
        remaining = String(remaining.dropFirst(prefix.count))
    }
    guard !rest.isEmpty else { return true }

    while true {
        if fnmatch(rest, remaining, 0) == 0 { return true }
        guard let slash = remaining.firstIndex(of: "/") else { return false }
        remaining = String(remaining[remaining.index(after: slash)...])
    }
}

// MARK: - ls

private func lsTool() -> RegisteredTool {
    RegisteredTool(
        tool: Tool(
            name: "ls",
            description: "List directory contents, sorted alphabetically. Directories are suffixed with '/'.",
            parameters: schema("""
{
  "type": "object",
  "properties": {
    "path":  { "type": "string", "description": "Directory to list (default: current directory)" },
    "limit": { "type": "number", "description": "Maximum number of entries (default: 500)" }
  }
}
""")
        ),
        executor: { args in
            struct P: Decodable { var path: String?; var limit: Int? }
            let p = (try? JSONDecoder().decode(P.self, from: Data(args.utf8))) ?? P()
            let limit = p.limit ?? 500
            let dir = p.path ?? FileManager.default.currentDirectoryPath
            let url = URL(fileURLWithPath: dir)
            let entries = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []
            )
            let names: [String] = entries.prefix(limit).map { entry in
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                return entry.lastPathComponent + (isDir ? "/" : "")
            }.sorted()
            return names.joined(separator: "\n")
        }
    )
}
