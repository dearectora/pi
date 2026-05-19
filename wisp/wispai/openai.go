package wispai

// OpenAI-compatible Chat Completions streaming (SSE).
// Works with OpenAI, DeepSeek, Groq, xAI, MiniMax, Cerebras, and any
// other provider that implements the OpenAI Chat Completions API.

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// StreamOpenAI opens a streaming Chat Completions request and emits events on
// the returned channel. The channel is closed after the done or error event.
func StreamOpenAI(ctx context.Context, model Model, msgCtx *Context, opts StreamOptions) <-chan AssistantMessageEvent {
	ch := make(chan AssistantMessageEvent, 64)
	go func() {
		defer close(ch)
		doStream(ctx, model, msgCtx, opts, ch)
	}()
	return ch
}

// emit sends an event, returning false if the context was cancelled.
func emit(ctx context.Context, ch chan<- AssistantMessageEvent, e AssistantMessageEvent) bool {
	select {
	case ch <- e:
		return true
	case <-ctx.Done():
		return false
	}
}

func doStream(ctx context.Context, model Model, msgCtx *Context, opts StreamOptions, ch chan<- AssistantMessageEvent) {
	msg := &AssistantMessage{
		Role:       "assistant",
		Model:      model.ID,
		Provider:   model.Provider,
		StopReason: StopReasonStop,
		Timestamp:  time.Now(),
	}

	if !emit(ctx, ch, AssistantMessageEvent{Type: EventStart, Partial: msg}) {
		return
	}

	// Build request body.
	body, err := buildChatRequest(model, msgCtx, opts)
	if err != nil {
		msg.StopReason = StopReasonError
		msg.AppendDiagnosticErr("build_request", err, nil)
		emit(ctx, ch, AssistantMessageEvent{Type: EventError, Message: msg})
		return
	}

	// Create HTTP request.
	url := strings.TrimRight(model.BaseURL, "/") + "/chat/completions"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		msg.StopReason = StopReasonError
		msg.AppendDiagnosticErr("invalid_url", err, nil)
		emit(ctx, ch, AssistantMessageEvent{Type: EventError, Message: msg})
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+opts.APIKey)
	req.Header.Set("Accept", "text/event-stream")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			msg.StopReason = StopReasonAborted
		} else {
			msg.StopReason = StopReasonError
			msg.AppendDiagnosticErr("network_error", err, nil)
		}
		emit(ctx, ch, AssistantMessageEvent{Type: EventError, Message: msg})
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		errMsg := fmt.Sprintf("HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(respBody)))
		msg.StopReason = StopReasonError
		msg.ErrorMessage = errMsg
		msg.AppendDiagnostic("http_error", errMsg, map[string]string{
			"statusCode": fmt.Sprintf("%d", resp.StatusCode),
			"url":        url,
		})
		emit(ctx, ch, AssistantMessageEvent{Type: EventError, Message: msg})
		return
	}

	// --- SSE parsing state ---

	type textBlock struct {
		idx     int
		started bool
		buf     strings.Builder
	}
	type thinkingBlock struct {
		idx     int
		started bool
		buf     strings.Builder
	}
	type toolBlock struct {
		idx    int  // index in msg.Content
		id     string
		name   string
		argBuf strings.Builder
	}

	var text     textBlock
	var thinking thinkingBlock
	toolBlocks := map[int]*toolBlock{} // keyed by SSE delta tool_calls[].index

	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		data := line[6:]
		if data == "[DONE]" {
			break
		}

		var chunk sseChunk
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			continue
		}
		if chunk.Model != "" {
			msg.Model = chunk.Model
		}
		if chunk.Usage != nil {
			msg.Usage.Input = chunk.Usage.PromptTokens
			msg.Usage.Output = chunk.Usage.CompletionTokens
			msg.Usage.Cost = computeCost(model, chunk.Usage.PromptTokens, chunk.Usage.CompletionTokens)
		}

		for _, choice := range chunk.Choices {
			d := choice.Delta

			// Thinking (DeepSeek reasoning_content field)
			if d.ReasoningContent != nil && *d.ReasoningContent != "" {
				if !thinking.started {
					thinking.started = true
					thinking.idx = len(msg.Content)
					msg.Content = append(msg.Content, ContentPart{Type: "thinking"})
					if !emit(ctx, ch, AssistantMessageEvent{Type: EventThinkingStart, Index: thinking.idx}) {
						return
					}
				}
				thinking.buf.WriteString(*d.ReasoningContent)
				msg.Content[thinking.idx].Thinking = thinking.buf.String()
				if !emit(ctx, ch, AssistantMessageEvent{
					Type:  EventThinkingDelta,
					Index: thinking.idx,
					Delta: *d.ReasoningContent,
				}) {
					return
				}
			}

			// Text content
			if d.Content != nil && *d.Content != "" {
				if !text.started {
					text.started = true
					text.idx = len(msg.Content)
					msg.Content = append(msg.Content, ContentPart{Type: "text"})
					if !emit(ctx, ch, AssistantMessageEvent{Type: EventTextStart, Index: text.idx}) {
						return
					}
				}
				text.buf.WriteString(*d.Content)
				msg.Content[text.idx].Text = text.buf.String()
				if !emit(ctx, ch, AssistantMessageEvent{
					Type:  EventTextDelta,
					Index: text.idx,
					Delta: *d.Content,
				}) {
					return
				}
			}

			// Tool calls
			for _, tc := range d.ToolCalls {
				blk, exists := toolBlocks[tc.Index]
				if !exists {
					blk = &toolBlock{
						idx:  len(msg.Content),
						id:   tc.ID,
						name: tc.Function.Name,
					}
					toolBlocks[tc.Index] = blk
					msg.Content = append(msg.Content, ContentPart{
						Type: "toolCall", ID: tc.ID, Name: tc.Function.Name,
					})
					if !emit(ctx, ch, AssistantMessageEvent{Type: EventToolCallStart, Index: tc.Index}) {
						return
					}
				}
				if tc.ID != "" {
					blk.id = tc.ID
					msg.Content[blk.idx].ID = tc.ID
				}
				if tc.Function.Name != "" {
					blk.name = tc.Function.Name
					msg.Content[blk.idx].Name = tc.Function.Name
				}
				if tc.Function.Arguments != "" {
					blk.argBuf.WriteString(tc.Function.Arguments)
					msg.Content[blk.idx].Arguments = blk.argBuf.String()
					if !emit(ctx, ch, AssistantMessageEvent{
						Type:  EventToolCallDelta,
						Index: tc.Index,
						Delta: tc.Function.Arguments,
					}) {
						return
					}
				}
			}

			// Finish reason
			if choice.FinishReason != nil {
				switch *choice.FinishReason {
				case "stop":
					msg.StopReason = StopReasonStop
				case "length":
					msg.StopReason = StopReasonLength
				case "tool_calls":
					msg.StopReason = StopReasonToolUse
				}
			}
		}
	}

	if err := scanner.Err(); err != nil && ctx.Err() == nil {
		msg.StopReason = StopReasonError
		msg.AppendDiagnosticErr("network_error", err, nil)
		emit(ctx, ch, AssistantMessageEvent{Type: EventError, Message: msg})
		return
	}

	if ctx.Err() != nil {
		msg.StopReason = StopReasonAborted
		emit(ctx, ch, AssistantMessageEvent{Type: EventError, Message: msg})
		return
	}

	// Emit *End events.
	if text.started {
		content := text.buf.String()
		if !emit(ctx, ch, AssistantMessageEvent{Type: EventTextEnd, Index: text.idx, Content: content}) {
			return
		}
	}
	if thinking.started {
		content := thinking.buf.String()
		if !emit(ctx, ch, AssistantMessageEvent{Type: EventThinkingEnd, Index: thinking.idx, Content: content}) {
			return
		}
	}
	for sseIdx, blk := range toolBlocks {
		args := blk.argBuf.String()
		part := ToolCallPart(blk.id, blk.name, args)
		if !emit(ctx, ch, AssistantMessageEvent{Type: EventToolCallEnd, Index: sseIdx, Part: &part}) {
			return
		}
	}

	emit(ctx, ch, AssistantMessageEvent{Type: EventDone, Message: msg})
}

func computeCost(model Model, inputTokens, outputTokens int) Cost {
	in := float64(inputTokens) / 1_000_000 * model.Cost.Input
	out := float64(outputTokens) / 1_000_000 * model.Cost.Output
	return Cost{Input: in, Output: out, Total: in + out}
}

// --- SSE wire types ---

type sseChunk struct {
	ID      string      `json:"id"`
	Model   string      `json:"model"`
	Choices []sseChoice `json:"choices"`
	Usage   *sseUsage   `json:"usage"`
}

type sseChoice struct {
	Index        int      `json:"index"`
	Delta        sseDelta `json:"delta"`
	FinishReason *string  `json:"finish_reason"`
}

type sseDelta struct {
	Role             string       `json:"role"`
	Content          *string      `json:"content"`
	ReasoningContent *string      `json:"reasoning_content"` // DeepSeek R1
	ToolCalls        []sseToolCall `json:"tool_calls"`
}

type sseToolCall struct {
	Index    int    `json:"index"`
	ID       string `json:"id"`
	Function struct {
		Name      string `json:"name"`
		Arguments string `json:"arguments"`
	} `json:"function"`
}

type sseUsage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
}

// --- Request builder ---

func buildChatRequest(model Model, msgCtx *Context, opts StreamOptions) ([]byte, error) {
	type msg struct {
		Role    string `json:"role"`
		Content string `json:"content"`
	}

	var messages []msg
	if msgCtx.SystemPrompt != "" {
		messages = append(messages, msg{Role: "system", Content: msgCtx.SystemPrompt})
	}
	for _, m := range msgCtx.Messages {
		switch m.Role {
		case "user":
			messages = append(messages, msg{Role: "user", Content: m.Content})
		case "assistant":
			var sb strings.Builder
			for _, p := range m.Parts {
				if p.Type == "text" {
					sb.WriteString(p.Text)
				}
			}
			messages = append(messages, msg{Role: "assistant", Content: sb.String()})
		}
	}

	req := map[string]any{
		"model":    model.ID,
		"messages": messages,
		"stream":   true,
		"stream_options": map[string]any{
			"include_usage": true,
		},
	}
	if opts.Temperature != nil {
		req["temperature"] = *opts.Temperature
	}
	if opts.MaxTokens != nil {
		req["max_tokens"] = *opts.MaxTokens
	}

	return json.Marshal(req)
}
