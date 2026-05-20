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

// ModelCost is per-million-token pricing.
type ModelCost struct {
	Input  float64
	Output float64
}

// GPT4oMini is the default fallback model when no model is configured.
var GPT4oMini = Model{
	ID:            "gpt-4o-mini",
	Name:          "GPT-4o Mini",
	Provider:      "openai",
	BaseURL:       "https://api.openai.com/v1",
	ContextWindow: 128_000,
	MaxTokens:     16_384,
	Cost:          ModelCost{Input: 0.15, Output: 0.60},
}

// BundledModels returns all models from the built-in registry.
func BundledModels() []Model { return allModels }
