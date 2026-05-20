package wispai

// Model describes an LLM model available through a provider.
type Model struct {
	ID               string
	Name             string
	Provider         string
	BaseURL          string
	ContextWindow    int
	MaxTokens        int
	Cost             ModelCost
	SupportsThinking bool
}

