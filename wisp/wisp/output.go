package main

import (
	"encoding/json"
	"fmt"
	"os"

	"wispai"
)

// RunTextMode streams text deltas to stdout.
// Returns (exitCode, finalMessage).
func RunTextMode(ch <-chan wispai.AssistantMessageEvent) (int, *wispai.AssistantMessage) {
	hadText := false
	for event := range ch {
		switch event.Type {
		case wispai.EventTextDelta:
			fmt.Print(event.Delta)
			hadText = true
		case wispai.EventThinkingDelta:
			// Print thinking to stderr so it doesn't pollute stdout pipelines.
			fmt.Fprint(os.Stderr, event.Delta)
		case wispai.EventDone:
			if hadText {
				fmt.Println()
			}
			return 0, event.Message
		case wispai.EventError:
			msg := event.Message
			desc := "unknown error"
			if msg.ErrorMessage != "" {
				desc = msg.ErrorMessage
			}
			fmt.Fprintf(os.Stderr, "\nError: %s\n", desc)
			if len(msg.Diagnostics) > 0 {
				d := msg.Diagnostics[0]
				diagMsg := ""
				if d.Error != nil {
					diagMsg = d.Error.Message
				}
				fmt.Fprintf(os.Stderr, "  [%s] %s\n", d.Type, diagMsg)
			}
			return 1, msg
		}
	}
	return 0, nil
}

// RunJSONMode emits one JSON object per line for every event.
// Returns (exitCode, finalMessage).
func RunJSONMode(ch <-chan wispai.AssistantMessageEvent) (int, *wispai.AssistantMessage) {
	exitCode := 0
	var finalMsg *wispai.AssistantMessage
	for event := range ch {
		if line := encodeEvent(event); line != "" {
			fmt.Println(line)
		}
		switch event.Type {
		case wispai.EventDone:
			finalMsg = event.Message
		case wispai.EventError:
			exitCode = 1
			finalMsg = event.Message
		}
	}
	return exitCode, finalMsg
}

func encodeEvent(e wispai.AssistantMessageEvent) string {
	var d map[string]any
	switch e.Type {
	case wispai.EventStart:
		d = map[string]any{"type": "start", "model": e.Partial.Model, "provider": e.Partial.Provider}
	case wispai.EventTextStart:
		d = map[string]any{"type": "textStart", "index": e.Index}
	case wispai.EventTextDelta:
		d = map[string]any{"type": "textDelta", "index": e.Index, "delta": e.Delta}
	case wispai.EventTextEnd:
		d = map[string]any{"type": "textEnd", "index": e.Index, "content": e.Content}
	case wispai.EventThinkingStart:
		d = map[string]any{"type": "thinkingStart", "index": e.Index}
	case wispai.EventThinkingDelta:
		d = map[string]any{"type": "thinkingDelta", "index": e.Index, "delta": e.Delta}
	case wispai.EventThinkingEnd:
		d = map[string]any{"type": "thinkingEnd", "index": e.Index, "content": e.Content}
	case wispai.EventToolCallStart:
		d = map[string]any{"type": "toolCallStart", "index": e.Index}
	case wispai.EventToolCallDelta:
		d = map[string]any{"type": "toolCallDelta", "index": e.Index, "delta": e.Delta}
	case wispai.EventToolCallEnd:
		d = map[string]any{
			"type": "toolCallEnd", "index": e.Index,
			"id": e.Part.ID, "name": e.Part.Name, "arguments": e.Part.Arguments,
		}
	case wispai.EventDone:
		d = encodeMessage("done", e.Message)
	case wispai.EventError:
		d = encodeMessage("error", e.Message)
	default:
		return ""
	}
	b, _ := json.Marshal(d)
	return string(b)
}

func encodeMessage(typ string, msg *wispai.AssistantMessage) map[string]any {
	d := map[string]any{
		"type":       typ,
		"model":      msg.Model,
		"provider":   msg.Provider,
		"stopReason": string(msg.StopReason),
		"usage": map[string]any{
			"input":  msg.Usage.Input,
			"output": msg.Usage.Output,
			"cost":   msg.Usage.Cost.Total,
		},
	}
	if msg.ErrorMessage != "" {
		d["errorMessage"] = msg.ErrorMessage
	}
	if len(msg.Diagnostics) > 0 {
		diags := make([]map[string]any, 0, len(msg.Diagnostics))
		for _, diag := range msg.Diagnostics {
			de := map[string]any{"type": diag.Type}
			if diag.Error != nil {
				e := map[string]any{"message": diag.Error.Message}
				if diag.Error.Name != "" {
					e["name"] = diag.Error.Name
				}
				if diag.Error.Code != "" {
					e["code"] = diag.Error.Code
				}
				de["error"] = e
			}
			if len(diag.Details) > 0 {
				de["details"] = diag.Details
			}
			diags = append(diags, de)
		}
		d["diagnostics"] = diags
	}
	return d
}
