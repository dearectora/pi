// Package wispai is an OpenAI-compatible LLM streaming client.
// It mirrors the structure of packages/ai from the pi TypeScript monorepo.
package wispai

import (
	"context"
	"sync"
)

var (
	mu        sync.RWMutex
	_settings *SettingsManager
	_registry *ModelRegistry
	_loadErr  error
)

func init() {
	reloadAll("", "")
}

// reloadAll loads both settings and models, merging models.json provider API
// keys into the settings key map so that Resolve() can find them.
func reloadAll(globalPath, projectPath string) {
	s := LoadSettings(globalPath, projectPath)

	data, err := loadModelsFile(ModelsPath())

	// Merge provider API keys from models.json into settings (settings.json wins).
	for provider, key := range data.ProviderKeys {
		if s.Settings.APIKeys == nil {
			s.Settings.APIKeys = make(map[string]string)
		}
		if existing := s.Settings.APIKeys[provider]; existing == "" {
			s.Settings.APIKeys[provider] = key
		}
	}

	mu.Lock()
	_settings = s
	_registry = newRegistry(data.Models)
	_loadErr = err
	mu.Unlock()
}

// GetSettings returns the current global SettingsManager.
func GetSettings() *SettingsManager {
	mu.RLock()
	defer mu.RUnlock()
	return _settings
}

// GetRegistry returns the current model registry (loaded from models.json).
func GetRegistry() *ModelRegistry {
	mu.RLock()
	defer mu.RUnlock()
	return _registry
}

// GetLoadError returns any error encountered while loading models.json.
func GetLoadError() error {
	mu.RLock()
	defer mu.RUnlock()
	return _loadErr
}

// ReloadSettings re-reads settings and models from disk.
// Pass empty strings to use the default paths.
func ReloadSettings(globalPath, projectPath string) {
	reloadAll(globalPath, projectPath)
}

// Stream starts a streaming request using the global settings to fill in
// any missing options. The returned channel is closed after the done or error event.
func Stream(ctx context.Context, model Model, msgCtx *Context, opts *StreamOptions) <-chan AssistantMessageEvent {
	s := GetSettings()
	resolved := s.Resolve(opts, model)
	return StreamOpenAI(ctx, model, msgCtx, resolved)
}
