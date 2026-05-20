package wispai

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// ToolExecutor executes a single tool call and returns a result string.
type ToolExecutor func(ctx context.Context, arguments string) (string, error)

// RegisteredTool pairs a Tool definition with its executor.
type RegisteredTool struct {
	Tool     Tool
	Executor ToolExecutor
}

// NewToolHandler builds a Tool slice and a ToolHandler dispatcher from a list
// of RegisteredTools.
func NewToolHandler(tools []RegisteredTool) ([]Tool, ToolHandler) {
	defs := make([]Tool, len(tools))
	executors := make(map[string]ToolExecutor, len(tools))
	for i, t := range tools {
		defs[i] = t.Tool
		executors[t.Tool.Name] = t.Executor
	}
	return defs, func(ctx context.Context, id, name, arguments string) (string, error) {
		fn, ok := executors[name]
		if !ok {
			return "", fmt.Errorf("unknown tool: %s", name)
		}
		return fn(ctx, arguments)
	}
}

// DefaultTools returns the standard coding tools (bash, read, write, edit,
// grep, find, ls) and a ToolHandler that dispatches to them.
func DefaultTools() ([]Tool, ToolHandler) {
	return NewToolHandler([]RegisteredTool{
		bashTool(),
		readTool(),
		writeTool(),
		editTool(),
		grepTool(),
		findTool(),
		lsTool(),
	})
}

// --- shared constants ---

const (
	outMaxLines = 300
	outMaxBytes = 512 * 1024
)

func truncateTail(s string) string {
	if len(s) > outMaxBytes {
		return "[output truncated]\n" + s[len(s)-outMaxBytes:]
	}
	lines := strings.Split(s, "\n")
	if len(lines) > outMaxLines {
		return "[output truncated]\n" + strings.Join(lines[len(lines)-outMaxLines:], "\n")
	}
	return s
}

func truncateHead(s string, lineLimit int) string {
	if len(s) > outMaxBytes {
		return s[:outMaxBytes] + "\n[output truncated at 512KB]"
	}
	lines := strings.Split(s, "\n")
	if len(lines) > lineLimit {
		return strings.Join(lines[:lineLimit], "\n") + "\n[output truncated]"
	}
	return s
}

func rawSchema(s string) json.RawMessage { return json.RawMessage(s) }

// --- bash ---

func bashTool() RegisteredTool {
	return RegisteredTool{
		Tool: Tool{
			Name:        "bash",
			Description: "Execute a bash command in the current working directory. Returns stdout and stderr combined. Output is truncated to the last 300 lines or 512KB. Optionally provide a timeout in seconds.",
			Parameters: rawSchema(`{
  "type": "object",
  "properties": {
    "command": { "type": "string", "description": "Bash command to execute" },
    "timeout": { "type": "number", "description": "Timeout in seconds" }
  },
  "required": ["command"]
}`),
		},
		Executor: func(ctx context.Context, args string) (string, error) {
			var p struct {
				Command string  `json:"command"`
				Timeout float64 `json:"timeout"`
			}
			json.Unmarshal([]byte(args), &p) //nolint

			cmdCtx := ctx
			if p.Timeout > 0 {
				var cancel context.CancelFunc
				cmdCtx, cancel = context.WithTimeout(ctx, time.Duration(p.Timeout*float64(time.Second)))
				defer cancel()
			}

			cmd := exec.CommandContext(cmdCtx, "bash", "-c", p.Command)
			var out bytes.Buffer
			cmd.Stdout = &out
			cmd.Stderr = &out
			cmd.Run() //nolint — we return output regardless of exit code
			return truncateTail(out.String()), nil
		},
	}
}

// --- read ---

func readTool() RegisteredTool {
	return RegisteredTool{
		Tool: Tool{
			Name:        "read",
			Description: "Read the contents of a file. Output is truncated to 300 lines or 512KB. Use offset and limit to page through large files.",
			Parameters: rawSchema(`{
  "type": "object",
  "properties": {
    "path":   { "type": "string", "description": "Path to the file to read (relative or absolute)" },
    "offset": { "type": "number", "description": "Line number to start reading from (1-indexed)" },
    "limit":  { "type": "number", "description": "Maximum number of lines to read" }
  },
  "required": ["path"]
}`),
		},
		Executor: func(ctx context.Context, args string) (string, error) {
			var p struct {
				Path   string `json:"path"`
				Offset int    `json:"offset"`
				Limit  int    `json:"limit"`
			}
			json.Unmarshal([]byte(args), &p) //nolint

			data, err := os.ReadFile(p.Path)
			if err != nil {
				return "", err
			}

			lines := strings.Split(string(data), "\n")
			start := 0
			if p.Offset > 1 {
				start = p.Offset - 1
			}
			if start >= len(lines) {
				return "", nil
			}
			lines = lines[start:]

			limit := outMaxLines
			if p.Limit > 0 {
				limit = p.Limit
			}
			return truncateHead(strings.Join(lines, "\n"), limit), nil
		},
	}
}

// --- write ---

func writeTool() RegisteredTool {
	return RegisteredTool{
		Tool: Tool{
			Name:        "write",
			Description: "Write content to a file, creating it (and any parent directories) if needed. Overwrites existing files completely.",
			Parameters: rawSchema(`{
  "type": "object",
  "properties": {
    "path":    { "type": "string", "description": "Path to the file to write (relative or absolute)" },
    "content": { "type": "string", "description": "Content to write to the file" }
  },
  "required": ["path", "content"]
}`),
		},
		Executor: func(ctx context.Context, args string) (string, error) {
			var p struct {
				Path    string `json:"path"`
				Content string `json:"content"`
			}
			if err := json.Unmarshal([]byte(args), &p); err != nil {
				return "", err
			}
			if err := os.MkdirAll(filepath.Dir(p.Path), 0o755); err != nil {
				return "", err
			}
			if err := os.WriteFile(p.Path, []byte(p.Content), 0o644); err != nil {
				return "", err
			}
			return fmt.Sprintf("Written %d bytes to %s", len(p.Content), p.Path), nil
		},
	}
}

// --- edit ---

func editTool() RegisteredTool {
	return RegisteredTool{
		Tool: Tool{
			Name: "edit",
			Description: "Edit a file using exact text replacement. Every oldText must be unique in the file. " +
				"All edits are matched against the original file simultaneously — do not emit overlapping edits. " +
				"Merge nearby changes into one call with multiple edits[] entries instead of separate calls. " +
				"Keep oldText as small as possible while still being unique.",
			Parameters: rawSchema(`{
  "type": "object",
  "properties": {
    "path": { "type": "string", "description": "Path to the file to edit" },
    "edits": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "oldText": { "type": "string", "description": "Exact text to replace (must be unique in the original file)" },
          "newText": { "type": "string", "description": "Replacement text" }
        },
        "required": ["oldText", "newText"]
      }
    }
  },
  "required": ["path", "edits"]
}`),
		},
		Executor: func(ctx context.Context, args string) (string, error) {
			var p struct {
				Path  string `json:"path"`
				Edits []struct {
					OldText string `json:"oldText"`
					NewText string `json:"newText"`
				} `json:"edits"`
			}
			if err := json.Unmarshal([]byte(args), &p); err != nil {
				return "", err
			}

			data, err := os.ReadFile(p.Path)
			if err != nil {
				return "", err
			}
			original := string(data)

			type editRange struct {
				start, end int
				newText    string
			}
			ranges := make([]editRange, 0, len(p.Edits))
			for i, e := range p.Edits {
				idx := strings.Index(original, e.OldText)
				if idx == -1 {
					return "", fmt.Errorf("edit %d: oldText not found in file", i+1)
				}
				if strings.Count(original, e.OldText) > 1 {
					return "", fmt.Errorf("edit %d: oldText matches multiple locations (must be unique)", i+1)
				}
				ranges = append(ranges, editRange{idx, idx + len(e.OldText), e.NewText})
			}

			sort.Slice(ranges, func(i, j int) bool { return ranges[i].start < ranges[j].start })
			for i := 1; i < len(ranges); i++ {
				if ranges[i].start < ranges[i-1].end {
					return "", fmt.Errorf("edits %d and %d overlap — merge them into one edit", i, i+1)
				}
			}

			// Apply from end to beginning to preserve positions.
			result := original
			for i := len(ranges) - 1; i >= 0; i-- {
				r := ranges[i]
				result = result[:r.start] + r.newText + result[r.end:]
			}

			if err := os.WriteFile(p.Path, []byte(result), 0o644); err != nil {
				return "", err
			}
			return fmt.Sprintf("Applied %d edit(s) to %s", len(p.Edits), p.Path), nil
		},
	}
}

// --- grep ---

func grepTool() RegisteredTool {
	return RegisteredTool{
		Tool: Tool{
			Name:        "grep",
			Description: "Search file contents for a pattern. Returns matching lines as path:line:content. Output truncated to 100 matches or 512KB.",
			Parameters: rawSchema(`{
  "type": "object",
  "properties": {
    "pattern":    { "type": "string", "description": "Search pattern (regex by default)" },
    "path":       { "type": "string", "description": "Directory or file to search (default: current directory)" },
    "glob":       { "type": "string", "description": "Filter files by glob, e.g. '*.go' or '*.ts'" },
    "ignoreCase": { "type": "boolean", "description": "Case-insensitive search" },
    "literal":    { "type": "boolean", "description": "Treat pattern as literal string, not regex" },
    "limit":      { "type": "number", "description": "Maximum matches to return (default: 100)" }
  },
  "required": ["pattern"]
}`),
		},
		Executor: func(ctx context.Context, args string) (string, error) {
			var p struct {
				Pattern    string `json:"pattern"`
				Path       string `json:"path"`
				Glob       string `json:"glob"`
				IgnoreCase bool   `json:"ignoreCase"`
				Literal    bool   `json:"literal"`
				Limit      int    `json:"limit"`
			}
			json.Unmarshal([]byte(args), &p) //nolint
			if p.Limit == 0 {
				p.Limit = 100
			}
			if p.Path == "" {
				p.Path = "."
			}

			pat := p.Pattern
			if p.Literal {
				pat = regexp.QuoteMeta(pat)
			}
			if p.IgnoreCase {
				pat = "(?i)" + pat
			}
			re, err := regexp.Compile(pat)
			if err != nil {
				return "", fmt.Errorf("invalid pattern: %w", err)
			}

			var sb strings.Builder
			matchCount := 0

			filepath.Walk(p.Path, func(path string, info os.FileInfo, err error) error { //nolint
				if err != nil || info.IsDir() || matchCount >= p.Limit || sb.Len() >= outMaxBytes {
					return nil
				}
				if strings.HasPrefix(filepath.Base(path), ".") {
					if info.IsDir() {
						return filepath.SkipDir
					}
					return nil
				}
				if p.Glob != "" {
					if matched, _ := filepath.Match(p.Glob, filepath.Base(path)); !matched {
						return nil
					}
				}
				data, err := os.ReadFile(path)
				if err != nil {
					return nil
				}
				for i, line := range strings.Split(string(data), "\n") {
					if !re.MatchString(line) {
						continue
					}
					if len(line) > 512 {
						line = line[:512] + "..."
					}
					fmt.Fprintf(&sb, "%s:%d:%s\n", path, i+1, line)
					matchCount++
					if matchCount >= p.Limit {
						break
					}
				}
				return nil
			})

			if matchCount == 0 {
				return "No matches found", nil
			}
			return sb.String(), nil
		},
	}
}

// --- find ---

func findTool() RegisteredTool {
	return RegisteredTool{
		Tool: Tool{
			Name:        "find",
			Description: "Search for files by glob pattern. Supports ** for recursive matching (e.g. '**/*.go', 'src/**/*.ts').",
			Parameters: rawSchema(`{
  "type": "object",
  "properties": {
    "pattern": { "type": "string", "description": "Glob pattern, e.g. '*.go', '**/*.ts', 'src/**/*.spec.ts'" },
    "path":    { "type": "string", "description": "Directory to search in (default: current directory)" },
    "limit":   { "type": "number", "description": "Maximum number of results (default: 1000)" }
  },
  "required": ["pattern"]
}`),
		},
		Executor: func(ctx context.Context, args string) (string, error) {
			var p struct {
				Pattern string `json:"pattern"`
				Path    string `json:"path"`
				Limit   int    `json:"limit"`
			}
			json.Unmarshal([]byte(args), &p) //nolint
			if p.Limit == 0 {
				p.Limit = 1000
			}
			if p.Path == "" {
				p.Path = "."
			}

			var results []string
			filepath.Walk(p.Path, func(path string, info os.FileInfo, err error) error { //nolint
				if err != nil || info.IsDir() || len(results) >= p.Limit {
					return nil
				}
				rel, _ := filepath.Rel(p.Path, path)
				if globMatch(p.Pattern, filepath.ToSlash(rel)) {
					results = append(results, rel)
				}
				return nil
			})

			if len(results) == 0 {
				return "No files found", nil
			}
			sort.Strings(results)
			return strings.Join(results, "\n"), nil
		},
	}
}

// globMatch matches a slash-separated relative path against a glob pattern
// that may contain ** for any number of path components.
func globMatch(pattern, relPath string) bool {
	if !strings.Contains(pattern, "**") {
		matched, _ := filepath.Match(pattern, relPath)
		return matched
	}
	i := strings.Index(pattern, "**")
	prefix := pattern[:i]
	rest := strings.TrimPrefix(pattern[i+2:], "/")

	if prefix != "" {
		if !strings.HasPrefix(relPath, prefix) {
			return false
		}
		relPath = relPath[len(prefix):]
	}
	if rest == "" {
		return true
	}
	// rest must match some suffix of relPath.
	for {
		if matched, _ := filepath.Match(rest, relPath); matched {
			return true
		}
		idx := strings.Index(relPath, "/")
		if idx == -1 {
			return false
		}
		relPath = relPath[idx+1:]
	}
}

// --- ls ---

func lsTool() RegisteredTool {
	return RegisteredTool{
		Tool: Tool{
			Name:        "ls",
			Description: "List directory contents, sorted alphabetically. Directories are suffixed with '/'.",
			Parameters: rawSchema(`{
  "type": "object",
  "properties": {
    "path":  { "type": "string", "description": "Directory to list (default: current directory)" },
    "limit": { "type": "number", "description": "Maximum number of entries (default: 500)" }
  }
}`),
		},
		Executor: func(ctx context.Context, args string) (string, error) {
			var p struct {
				Path  string `json:"path"`
				Limit int    `json:"limit"`
			}
			json.Unmarshal([]byte(args), &p) //nolint
			if p.Limit == 0 {
				p.Limit = 500
			}
			if p.Path == "" {
				p.Path = "."
			}

			entries, err := os.ReadDir(p.Path)
			if err != nil {
				return "", err
			}

			names := make([]string, 0, len(entries))
			for i, e := range entries {
				if i >= p.Limit {
					break
				}
				name := e.Name()
				if e.IsDir() {
					name += "/"
				}
				names = append(names, name)
			}
			return strings.Join(names, "\n"), nil
		},
	}
}
