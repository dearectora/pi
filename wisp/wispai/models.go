package wispai

import (
	_ "embed"
	"encoding/json"
)

//go:embed models.json
var modelsJSONData []byte

// Model describes an LLM model available through a provider.
type Model struct {
	ID               string    `json:"id"`
	Name             string    `json:"name"`
	Provider         string    `json:"provider"`
	BaseURL          string    `json:"baseUrl"`
	ContextWindow    int       `json:"contextWindow"`
	MaxTokens        int       `json:"maxTokens"`
	Cost             ModelCost `json:"cost"`
	SupportsThinking bool      `json:"supportsThinking"`
}

// GPT4oMini is the fallback model when no model is configured.
var GPT4oMini = Model{
	ID:            "gpt-4o-mini",
	Name:          "GPT-4o Mini",
	Provider:      "openai",
	BaseURL:       "https://api.openai.com/v1",
	ContextWindow: 128000,
	MaxTokens:     16384,
	Cost:          ModelCost{Input: 0.15, Output: 0.60},
}

// BundledModels returns all models from the embedded models.json.
func BundledModels() []Model {
	var models []Model
	_ = json.Unmarshal(modelsJSONData, &models)
	return models
}
