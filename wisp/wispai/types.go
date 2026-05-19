package wispai

import "time"

// StopReason describes why an assistant message ended.
type StopReason string

const (
	StopReasonStop    StopReason = "stop"
	StopReasonLength  StopReason = "length"
	StopReasonToolUse StopReason = "toolUse"
	StopReasonError   StopReason = "error"
	StopReasonAborted StopReason = "aborted"
)

// ModelCost is per-million-token pricing for a model.
type ModelCost struct {
	Input  float64 `json:"input"`
	Output float64 `json:"output"`
}

// Cost is the computed cost for a single request.
type Cost struct {
	Input  float64 `json:"input"`
	Output float64 `json:"output"`
	Total  float64 `json:"total"`
}

// Usage tracks token counts and cost for a request.
type Usage struct {
	Input  int  `json:"input"`
	Output int  `json:"output"`
	Cost   Cost `json:"cost"`
}

// ContentPart is a tagged union representing one block in an assistant's response.
// Type is one of "text", "thinking", "toolCall".
type ContentPart struct {
	Type      string `json:"type"`
	Text      string `json:"text,omitempty"`
	Thinking  string `json:"thinking,omitempty"`
	ID        string `json:"id,omitempty"`
	Name      string `json:"name,omitempty"`
	Arguments string `json:"arguments,omitempty"`
}

func TextPart(text string) ContentPart { return ContentPart{Type: "text", Text: text} }
func ThinkingPart(t string) ContentPart { return ContentPart{Type: "thinking", Thinking: t} }
func ToolCallPart(id, name, args string) ContentPart {
	return ContentPart{Type: "toolCall", ID: id, Name: name, Arguments: args}
}

// AssistantMessage is the LLM's complete response.
type AssistantMessage struct {
	Role         string                       `json:"role"`
	Model        string                       `json:"model"`
	Provider     string                       `json:"provider"`
	Content      []ContentPart                `json:"content"`
	StopReason   StopReason                   `json:"stopReason"`
	Usage        Usage                        `json:"usage"`
	ErrorMessage string                       `json:"errorMessage,omitempty"`
	Diagnostics  []AssistantMessageDiagnostic `json:"diagnostics,omitempty"`
	Timestamp    time.Time                    `json:"timestamp"`
}

// ContextMessage is one turn in the conversation sent to the LLM.
type ContextMessage struct {
	Role    string        // "user" or "assistant"
	Content string        // for user messages
	Parts   []ContentPart // for assistant messages
}

// UserMsg is a convenience constructor for a user-role ContextMessage.
func UserMsg(text string) ContextMessage {
	return ContextMessage{Role: "user", Content: text}
}

// Context is the full conversation context sent to the LLM.
type Context struct {
	SystemPrompt string
	Messages     []ContextMessage
}

// StreamOptions configures a call to the LLM.
type StreamOptions struct {
	APIKey      string
	Temperature *float64
	MaxTokens   *int
}

// EventType identifies the kind of streaming event.
type EventType string

const (
	EventStart         EventType = "start"
	EventTextStart     EventType = "textStart"
	EventTextDelta     EventType = "textDelta"
	EventTextEnd       EventType = "textEnd"
	EventThinkingStart EventType = "thinkingStart"
	EventThinkingDelta EventType = "thinkingDelta"
	EventThinkingEnd   EventType = "thinkingEnd"
	EventToolCallStart EventType = "toolCallStart"
	EventToolCallDelta EventType = "toolCallDelta"
	EventToolCallEnd   EventType = "toolCallEnd"
	EventDone          EventType = "done"
	EventError         EventType = "error"
)

// AssistantMessageEvent is one event in a streaming response.
type AssistantMessageEvent struct {
	Type    EventType
	Index   int
	Delta   string
	Content string        // for *End events
	Part    *ContentPart  // for toolCallEnd
	Message *AssistantMessage // for done/error
	Partial *AssistantMessage // for start
}
