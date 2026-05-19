package main

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"wispai"
)

// SessionLogger appends JSONL entries to a session log file under
// ~/.pi/agent/sessions/.
type SessionLogger struct {
	file          *os.File
	lastMessageID string
}

// NewSessionLogger creates the sessions directory if needed, opens a new
// JSONL file, and writes the session header entry.
func NewSessionLogger(model wispai.Model) (*SessionLogger, error) {
	sessionsDir := wispai.AgentDir() + "/sessions"
	if err := os.MkdirAll(sessionsDir, 0o755); err != nil {
		return nil, err
	}

	sessionID := newUUID()
	now := time.Now().UTC()
	ts := now.Format("2006-01-02T15:04:05.000Z")
	safe := strings.NewReplacer(":", "-", ".", "-").Replace(ts)
	path := fmt.Sprintf("%s/%s_%s.jsonl", sessionsDir, safe, sessionID)

	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}

	cwd, _ := os.Getwd()
	lg := &SessionLogger{file: f}
	if err := lg.appendEntry(map[string]any{
		"type":      "session",
		"version":   1,
		"id":        sessionID,
		"timestamp": now.Format(time.RFC3339Nano),
		"cwd":       cwd,
		"tool":      "wisp",
		"model":     model.ID,
		"provider":  model.Provider,
	}); err != nil {
		f.Close()
		return nil, err
	}
	return lg, nil
}

// LogUserMessage appends a user message entry.
func (lg *SessionLogger) LogUserMessage(text string) error {
	id := newUUID()
	err := lg.appendEntry(map[string]any{
		"type":      "message",
		"id":        id,
		"parentId":  nil,
		"timestamp": time.Now().UTC().Format(time.RFC3339Nano),
		"message": map[string]any{
			"role":    "user",
			"content": text,
		},
	})
	if err == nil {
		lg.lastMessageID = id
	}
	return err
}

// LogAssistantMessage appends an assistant message entry.
func (lg *SessionLogger) LogAssistantMessage(msg *wispai.AssistantMessage) error {
	content := make([]map[string]any, 0, len(msg.Content))
	for _, p := range msg.Content {
		switch p.Type {
		case "text":
			content = append(content, map[string]any{"type": "text", "text": p.Text})
		case "thinking":
			content = append(content, map[string]any{"type": "thinking", "thinking": p.Thinking})
		case "toolCall":
			content = append(content, map[string]any{
				"type": "tool_call", "id": p.ID, "name": p.Name, "arguments": p.Arguments,
			})
		}
	}

	msgDict := map[string]any{
		"role":       "assistant",
		"model":      msg.Model,
		"provider":   msg.Provider,
		"stopReason": string(msg.StopReason),
		"usage": map[string]any{
			"input":  msg.Usage.Input,
			"output": msg.Usage.Output,
			"cost":   msg.Usage.Cost.Total,
		},
		"content": content,
	}
	if msg.ErrorMessage != "" {
		msgDict["errorMessage"] = msg.ErrorMessage
	}
	if len(msg.Diagnostics) > 0 {
		diags := make([]map[string]any, 0, len(msg.Diagnostics))
		for _, d := range msg.Diagnostics {
			de := map[string]any{
				"type":      d.Type,
				"timestamp": d.Timestamp.UTC().Format(time.RFC3339Nano),
			}
			if d.Error != nil {
				e := map[string]any{"message": d.Error.Message}
				if d.Error.Name != "" {
					e["name"] = d.Error.Name
				}
				if d.Error.Code != "" {
					e["code"] = d.Error.Code
				}
				de["error"] = e
			}
			if len(d.Details) > 0 {
				de["details"] = d.Details
			}
			diags = append(diags, de)
		}
		msgDict["diagnostics"] = diags
	}

	var parentID any
	if lg.lastMessageID != "" {
		parentID = lg.lastMessageID
	}

	id := newUUID()
	err := lg.appendEntry(map[string]any{
		"type":      "message",
		"id":        id,
		"parentId":  parentID,
		"timestamp": time.Now().UTC().Format(time.RFC3339Nano),
		"message":   msgDict,
	})
	if err == nil {
		lg.lastMessageID = id
	}
	return err
}

// Close flushes and closes the underlying file.
func (lg *SessionLogger) Close() error { return lg.file.Close() }

func (lg *SessionLogger) appendEntry(d map[string]any) error {
	b, err := json.Marshal(d)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	_, err = lg.file.Write(b)
	return err
}

func newUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant RFC 4122
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
