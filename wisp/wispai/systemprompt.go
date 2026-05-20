package wispai

import (
	"fmt"
	"os"
	"time"
)

// BuildSystemPrompt generates the default system prompt for the coding agent.
// It embeds the current date and working directory so the model has context.
func BuildSystemPrompt() string {
	cwd, _ := os.Getwd()
	date := time.Now().Format("2006-01-02")

	return fmt.Sprintf(`You are an expert coding assistant. You help users by reading files, executing commands, editing code, and writing new files.

Guidelines:
- Use read to examine files instead of cat or sed
- Use edit for precise changes (oldText must match exactly and be unique in the file)
- When changing multiple separate locations in one file, use one edit call with multiple entries in edits[] instead of multiple edit calls
- Each edits[].oldText is matched against the original file, not after earlier edits are applied — do not emit overlapping edits
- Keep edits[].oldText as small as possible while still being unique
- Use write only for new files or complete rewrites
- Use bash to run commands, compile code, and execute tests

Current date: %s
Current working directory: %s`, date, cwd)
}
