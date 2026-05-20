package wispai

import (
	"context"
	"fmt"
	"time"
)

// ToolHandler is called by the agent to execute a tool call.
// Returns the result string to send back to the model, or an error.
type ToolHandler func(ctx context.Context, id, name, arguments string) (string, error)

// AgentOptions configures the agent loop.
type AgentOptions struct {
	MaxSteps int // maximum number of model calls before giving up (default: 10)
}

// RunAgent runs the agent loop: it calls the model repeatedly, executing tool
// calls via handler until the model stops or MaxSteps is reached.
// All events from every step are forwarded to the returned channel.
func RunAgent(
	ctx context.Context,
	config *Config,
	model Model,
	msgCtx *Context,
	opts *StreamOptions,
	handler ToolHandler,
	agentOpts *AgentOptions,
) <-chan AssistantMessageEvent {
	ch := make(chan AssistantMessageEvent, 64)
	go func() {
		defer close(ch)
		runAgentLoop(ctx, config, model, msgCtx, opts, handler, agentOpts, ch)
	}()
	return ch
}

func runAgentLoop(
	ctx context.Context,
	config *Config,
	model Model,
	msgCtx *Context,
	opts *StreamOptions,
	handler ToolHandler,
	agentOpts *AgentOptions,
	ch chan<- AssistantMessageEvent,
) {
	maxSteps := 10
	if agentOpts != nil && agentOpts.MaxSteps > 0 {
		maxSteps = agentOpts.MaxSteps
	}

	// Work on a copy so we don't mutate the caller's context.
	cur := &Context{
		SystemPrompt: msgCtx.SystemPrompt,
		Messages:     append([]ContextMessage{}, msgCtx.Messages...),
		Tools:        msgCtx.Tools,
	}

	for step := 0; step < maxSteps; step++ {
		var finalMsg *AssistantMessage

		for e := range Stream(ctx, config, model, cur, opts) {
			if e.Type == EventDone || e.Type == EventError {
				finalMsg = e.Message
			}
			select {
			case ch <- e:
			case <-ctx.Done():
				return
			}
		}

		if ctx.Err() != nil {
			return
		}
		if finalMsg == nil || finalMsg.StopReason != StopReasonToolUse {
			return
		}

		// Add assistant message with tool calls to history.
		cur.Messages = append(cur.Messages, AssistantMsg(finalMsg))

		// Execute each tool call and append its result.
		for _, part := range finalMsg.Content {
			if part.Type != "toolCall" {
				continue
			}
			result, err := handler(ctx, part.ID, part.Name, part.Arguments)
			if err != nil {
				result = "error: " + err.Error()
			}
			cur.Messages = append(cur.Messages, ToolResultMsg(part.ID, result))
		}
	}

	// Exceeded max steps.
	errMsg := &AssistantMessage{
		Role:         "assistant",
		Model:        model.ID,
		Provider:     model.Provider,
		StopReason:   StopReasonError,
		ErrorMessage: fmt.Sprintf("agent exceeded maximum steps (%d)", maxSteps),
		Timestamp:    time.Now(),
	}
	select {
	case ch <- AssistantMessageEvent{Type: EventError, Message: errMsg}:
	case <-ctx.Done():
	}
}
