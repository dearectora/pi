// Package wispai is an OpenAI-compatible LLM streaming client.
// It mirrors the structure of packages/ai from the pi TypeScript monorepo.
package wispai

import (
	"context"
	"sync"
)

var (
	mu       sync.RWMutex
	_settings *SettingsManager
)

func init() {
	_settings = LoadSettings("", "")
}

// GetSettings returns the current global SettingsManager.
func GetSettings() *SettingsManager {
	mu.RLock()
	defer mu.RUnlock()
	return _settings
}

// ReloadSettings re-reads the global and project settings from disk.
// Pass empty strings to use the default paths.
func ReloadSettings(globalPath, projectPath string) {
	s := LoadSettings(globalPath, projectPath)
	mu.Lock()
	_settings = s
	mu.Unlock()
}

// Stream starts a streaming request using the global settings manager to fill
// in any missing options (API key, temperature, max tokens).
// The returned channel is closed after the done or error event.
func Stream(ctx context.Context, model Model, msgCtx *Context, opts *StreamOptions) <-chan AssistantMessageEvent {
	s := GetSettings()
	resolved := s.Resolve(opts, model)
	return StreamOpenAI(ctx, model, msgCtx, resolved)
}
