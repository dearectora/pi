package wispai

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// AgentDir returns the agent directory, respecting PI_CODING_AGENT_DIR.
func AgentDir() string {
	if d := os.Getenv("PI_CODING_AGENT_DIR"); d != "" {
		return d
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".pi", "agent")
}

// ModelsPath returns the path for the models/config file.
func ModelsPath() string {
	return filepath.Join(AgentDir(), "models.json")
}

// Config holds all configuration loaded from models.json.
type Config struct {
	DefaultProvider string
	DefaultModel    string
	Stream          *StreamDefaults
	Retry           *RetrySettings
	apiKeys         map[string]string
	registry        *ModelRegistry
	loadErr         error
}

// APIKey resolves the API key for a provider (case-insensitive).
func (c *Config) APIKey(provider string) string {
	if c.apiKeys != nil {
		if key, ok := c.apiKeys[strings.ToLower(provider)]; ok && key != "" {
			return key
		}
	}
	return ""
}

// Registry returns the model registry.
func (c *Config) Registry() *ModelRegistry { return c.registry }

// LoadError returns any error encountered while loading models.json.
func (c *Config) LoadError() error { return c.loadErr }

// Resolve fills missing fields in opts from config defaults and returns
// the complete StreamOptions to pass to a provider.
func (c *Config) Resolve(opts *StreamOptions, model Model) StreamOptions {
	var out StreamOptions
	if opts != nil {
		out = *opts
	}
	if out.APIKey == "" {
		out.APIKey = c.APIKey(model.Provider)
	}
	if c.Stream != nil {
		if out.Temperature == nil {
			out.Temperature = c.Stream.Temperature
		}
		if out.MaxTokens == nil {
			out.MaxTokens = c.Stream.MaxTokens
		}
	}
	return out
}

// --- models.json wire types ---

type modelsFile struct {
	DefaultProvider string                   `json:"defaultProvider,omitempty"`
	DefaultModel    string                   `json:"defaultModel,omitempty"`
	Stream          *StreamDefaults          `json:"stream,omitempty"`
	Retry           *RetrySettings           `json:"retry,omitempty"`
	Providers       map[string]providerConfig `json:"providers"`
}

type providerConfig struct {
	Name    string            `json:"name,omitempty"`
	BaseURL string            `json:"baseUrl,omitempty"`
	APIKey  string            `json:"apiKey,omitempty"`
	Models  []modelDefinition `json:"models"`
}

type modelDefinition struct {
	ID               string    `json:"id"`
	Name             string    `json:"name,omitempty"`
	BaseURL          string    `json:"baseUrl,omitempty"`
	ContextWindow    int       `json:"contextWindow,omitempty"`
	MaxTokens        int       `json:"maxTokens,omitempty"`
	Cost             *costJSON `json:"cost,omitempty"`
	SupportsThinking bool      `json:"supportsThinking,omitempty"`
}

type costJSON struct {
	Input  float64 `json:"input"`
	Output float64 `json:"output"`
}

// loadConfig reads and parses a models.json file, returning a Config.
// Returns an empty (but valid) Config without error if the file does not exist.
func loadConfig(path string) *Config {
	cfg := &Config{
		registry: newRegistry(nil),
		apiKeys:  make(map[string]string),
	}

	data, err := os.ReadFile(path)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			cfg.loadErr = err
		}
		return cfg
	}

	var f modelsFile
	if err := json.Unmarshal(data, &f); err != nil {
		cfg.loadErr = fmt.Errorf("models.json: %w", err)
		return cfg
	}

	cfg.DefaultProvider = f.DefaultProvider
	cfg.DefaultModel = f.DefaultModel
	cfg.Stream = f.Stream
	cfg.Retry = f.Retry

	var models []Model
	for providerID, prov := range f.Providers {
		pid := strings.ToLower(providerID)
		if prov.APIKey != "" {
			cfg.apiKeys[pid] = prov.APIKey
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
			models = append(models, m)
		}
	}
	cfg.registry = newRegistry(models)
	return cfg
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
