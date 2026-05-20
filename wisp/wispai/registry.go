package wispai

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// ModelsPath returns the default path for the models configuration file.
// It lives next to settings.json in the agent directory.
func ModelsPath() string {
	return filepath.Join(AgentDir(), "models.json")
}

// modelsFileData is the result of parsing a models.json file.
type modelsFileData struct {
	Models      []Model
	ProviderKeys map[string]string // provider id → apiKey from models.json
}

// --- models.json wire types ---

type modelsFile struct {
	Providers map[string]providerConfig `json:"providers"`
}

type providerConfig struct {
	Name    string            `json:"name,omitempty"`
	BaseURL string            `json:"baseUrl,omitempty"`
	APIKey  string            `json:"apiKey,omitempty"`
	Models  []modelDefinition `json:"models"`
}

type modelDefinition struct {
	ID               string        `json:"id"`
	Name             string        `json:"name,omitempty"`
	BaseURL          string        `json:"baseUrl,omitempty"` // overrides provider baseUrl
	ContextWindow    int           `json:"contextWindow,omitempty"`
	MaxTokens        int           `json:"maxTokens,omitempty"`
	Cost             *costJSON     `json:"cost,omitempty"`
	SupportsThinking bool          `json:"supportsThinking,omitempty"`
}

type costJSON struct {
	Input  float64 `json:"input"`
	Output float64 `json:"output"`
}

// loadModelsFile reads and parses a models.json file.
// Returns empty data without error if the file does not exist.
func loadModelsFile(path string) (modelsFileData, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return modelsFileData{}, nil
		}
		return modelsFileData{}, err
	}

	var f modelsFile
	if err := json.Unmarshal(data, &f); err != nil {
		return modelsFileData{}, fmt.Errorf("models.json: %w", err)
	}

	result := modelsFileData{
		ProviderKeys: make(map[string]string),
	}

	for providerID, prov := range f.Providers {
		pid := strings.ToLower(providerID)
		if prov.APIKey != "" {
			result.ProviderKeys[pid] = prov.APIKey
		}
		for _, def := range prov.Models {
			if def.ID == "" {
				continue
			}
			baseURL := def.BaseURL
			if baseURL == "" {
				baseURL = prov.BaseURL
			}
			name := def.Name
			if name == "" {
				name = def.ID
			}
			m := Model{
				ID:               def.ID,
				Name:             name,
				Provider:         pid,
				BaseURL:          baseURL,
				ContextWindow:    def.ContextWindow,
				MaxTokens:        def.MaxTokens,
				SupportsThinking: def.SupportsThinking,
			}
			if def.Cost != nil {
				m.Cost = ModelCost{Input: def.Cost.Input, Output: def.Cost.Output}
			}
			result.Models = append(result.Models, m)
		}
	}
	return result, nil
}

// ModelRegistry is a queryable list of models.
type ModelRegistry struct {
	models []Model
}

func newRegistry(models []Model) *ModelRegistry {
	return &ModelRegistry{models: models}
}

// All returns all registered models.
func (r *ModelRegistry) All() []Model { return r.models }

// ForProvider returns all models for a given provider (case-insensitive).
func (r *ModelRegistry) ForProvider(provider string) []Model {
	var out []Model
	for _, m := range r.models {
		if strings.EqualFold(m.Provider, provider) {
			out = append(out, m)
		}
	}
	return out
}

// Find returns the first model matching both provider and id (case-insensitive).
func (r *ModelRegistry) Find(provider, id string) (Model, bool) {
	for _, m := range r.models {
		if strings.EqualFold(m.Provider, provider) && strings.EqualFold(m.ID, id) {
			return m, true
		}
	}
	return Model{}, false
}

// FindByID returns the first model matching the given id across all providers.
func (r *ModelRegistry) FindByID(id string) (Model, bool) {
	for _, m := range r.models {
		if strings.EqualFold(m.ID, id) {
			return m, true
		}
	}
	return Model{}, false
}
