package wispai

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"sync"
)

// --- Protocol types (stdin → commands, stdout → responses + events) ---

// RpcCommand is a command sent by the UI to the agent via stdin (JSON Lines).
type RpcCommand struct {
	Type         string `json:"type"`
	ID           string `json:"id,omitempty"`
	Message      string `json:"message,omitempty"`
	Provider     string `json:"provider,omitempty"`
	ModelID      string `json:"modelId,omitempty"`
	SystemPrompt string `json:"systemPrompt,omitempty"`
}

// RpcResponse is sent to stdout in reply to a command.
type RpcResponse struct {
	ID      string `json:"id,omitempty"`
	Type    string `json:"type"` // always "response"
	Command string `json:"command"`
	Success bool   `json:"success"`
	Data    any    `json:"data,omitempty"`
	Error   string `json:"error,omitempty"`
}

// RpcSessionState is returned by get_state.
type RpcSessionState struct {
	Model        *Model `json:"model"`
	IsStreaming  bool   `json:"isStreaming"`
	SessionID    string `json:"sessionId"`
	MessageCount int    `json:"messageCount"`
}

// rpcEvent is the JSON-serializable form of AssistantMessageEvent,
// emitted to stdout during streaming.
type rpcEvent struct {
	Type    EventType         `json:"type"`
	Index   int               `json:"index,omitempty"`
	Delta   string            `json:"delta,omitempty"`
	Content string            `json:"content,omitempty"`
	Part    *ContentPart      `json:"part,omitempty"`
	Message *AssistantMessage `json:"message,omitempty"`
}

// --- RPC session state ---

type rpcSession struct {
	mu           sync.Mutex
	id           string
	messages     []ContextMessage
	systemPrompt string
	model        Model
	opts         StreamOptions
	tools        []Tool
	handler      ToolHandler
	cancelStream context.CancelFunc
	isStreaming  bool
}

// RunRPC reads JSON commands from in and writes JSON events/responses to out.
// Runs until in is closed or ctx is cancelled.
//
// Supported commands (stdin):
//
//	prompt / follow_up  — send a message, streams events back
//	abort               — cancel the current stream
//	new_session         — clear history and start fresh
//	get_state           — return current session state
//	get_messages        — return full message history
//	set_model           — change the active model
//	get_available_models — list all models from config
//	set_system_prompt   — set the system prompt for the session
//
// Every command produces a { type:"response", command, success, data?, error? }
// response on stdout. Streaming events are emitted as they arrive.
func RunRPC(
	ctx context.Context,
	config *Config,
	model Model,
	opts StreamOptions,
	tools []Tool,
	handler ToolHandler,
	initialSystemPrompt string,
	in io.Reader,
	out io.Writer,
) {
	s := &rpcSession{
		id:           rpcNewID(),
		model:        model,
		opts:         opts,
		tools:        tools,
		handler:      handler,
		systemPrompt: initialSystemPrompt,
	}

	var outMu sync.Mutex
	write := func(v any) {
		b, err := json.Marshal(v)
		if err != nil {
			return
		}
		outMu.Lock()
		out.Write(append(b, '\n')) //nolint
		outMu.Unlock()
	}

	respond := func(id, command string, data any, errMsg string) {
		r := RpcResponse{
			ID:      id,
			Type:    "response",
			Command: command,
			Success: errMsg == "",
		}
		if errMsg != "" {
			r.Error = errMsg
		} else {
			r.Data = data
		}
		write(r)
	}

	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 4*1024*1024), 4*1024*1024)

	for scanner.Scan() {
		if ctx.Err() != nil {
			return
		}
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var cmd RpcCommand
		if err := json.Unmarshal(line, &cmd); err != nil {
			continue
		}

		switch cmd.Type {

		case "prompt", "follow_up":
			s.mu.Lock()
			if s.isStreaming {
				s.mu.Unlock()
				respond(cmd.ID, cmd.Type, nil, "already streaming; send abort first")
				continue
			}
			s.messages = append(s.messages, UserMsg(cmd.Message))
			msgCtx := &Context{
				SystemPrompt: s.systemPrompt,
				Messages:     append([]ContextMessage{}, s.messages...),
				Tools:        s.tools,
			}
			streamCtx, cancel := context.WithCancel(ctx)
			s.cancelStream = cancel
			s.isStreaming = true
			currentModel := s.model
			currentOpts := s.opts
			s.mu.Unlock()

			respond(cmd.ID, cmd.Type, nil, "")

			go func(id string) {
				defer func() {
					cancel()
					s.mu.Lock()
					s.isStreaming = false
					s.cancelStream = nil
					s.mu.Unlock()
				}()

				agentOpts := &AgentOptions{
					OnStep: func(added []ContextMessage) {
						s.mu.Lock()
						s.messages = append(s.messages, added...)
						s.mu.Unlock()
					},
				}

				for e := range RunAgent(streamCtx, config, currentModel, msgCtx, &currentOpts, s.handler, agentOpts) {
					write(rpcEvent{
						Type:    e.Type,
						Index:   e.Index,
						Delta:   e.Delta,
						Content: e.Content,
						Part:    e.Part,
						Message: e.Message,
					})
					// For text-only responses (no tool calls), RunAgent emits
					// EventDone without calling OnStep, so append the message here.
					if e.Type == EventDone && e.Message != nil {
						s.mu.Lock()
						// Only append if the message isn't already in history
						// (OnStep handles the tool-use path).
						last := len(s.messages) - 1
						alreadyStored := last >= 0 && s.messages[last].Role == "assistant"
						if !alreadyStored {
							s.messages = append(s.messages, AssistantMsg(e.Message))
						}
						s.mu.Unlock()
					}
				}
			}(cmd.ID)

		case "abort":
			s.mu.Lock()
			if s.cancelStream != nil {
				s.cancelStream()
			}
			s.mu.Unlock()
			respond(cmd.ID, "abort", nil, "")

		case "new_session":
			s.mu.Lock()
			if s.cancelStream != nil {
				s.cancelStream()
			}
			s.messages = nil
			s.systemPrompt = ""
			s.id = rpcNewID()
			s.mu.Unlock()
			respond(cmd.ID, "new_session", nil, "")

		case "get_state":
			s.mu.Lock()
			m := s.model
			state := RpcSessionState{
				Model:        &m,
				IsStreaming:  s.isStreaming,
				SessionID:    s.id,
				MessageCount: len(s.messages),
			}
			s.mu.Unlock()
			respond(cmd.ID, "get_state", state, "")

		case "get_messages":
			s.mu.Lock()
			msgs := append([]ContextMessage{}, s.messages...)
			s.mu.Unlock()
			respond(cmd.ID, "get_messages", map[string]any{"messages": msgs}, "")

		case "set_model":
			registry := config.Registry()
			m, ok := registry.Find(cmd.Provider, cmd.ModelID)
			if !ok {
				m, ok = registry.FindByID(cmd.ModelID)
			}
			if !ok {
				respond(cmd.ID, "set_model", nil, fmt.Sprintf("model %q not found", cmd.ModelID))
			} else {
				newOpts := config.Resolve(nil, m)
				s.mu.Lock()
				s.model = m
				s.opts = newOpts
				s.mu.Unlock()
				respond(cmd.ID, "set_model", m, "")
			}

		case "get_available_models":
			models := config.Registry().All()
			respond(cmd.ID, "get_available_models", map[string]any{"models": models}, "")

		case "set_system_prompt":
			s.mu.Lock()
			s.systemPrompt = cmd.SystemPrompt
			s.mu.Unlock()
			respond(cmd.ID, "set_system_prompt", nil, "")

		default:
			respond(cmd.ID, cmd.Type, nil, fmt.Sprintf("unknown command: %s", cmd.Type))
		}
	}
}

func rpcNewID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}
