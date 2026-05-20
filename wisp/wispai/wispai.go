// Package wispai is an OpenAI-compatible LLM streaming client.
// It mirrors the structure of packages/ai from the pi TypeScript monorepo.
package wispai

import (
	"context"
	"sync"
)

var (
	mu      sync.RWMutex
	_config *Config
)

func init() {
	reload()
}

func reload() {
	cfg := loadConfig(ModelsPath())
	mu.Lock()
	_config = cfg
	mu.Unlock()
}

// GetConfig returns the current global Config loaded from models.json.
func GetConfig() *Config {
	mu.RLock()
	defer mu.RUnlock()
	return _config
}

// Reload re-reads models.json from disk.
func Reload() {
	reload()
}

// Stream starts a streaming request using the global config to fill in
// any missing options. The returned channel is closed after the done or error event.
func Stream(ctx context.Context, model Model, msgCtx *Context, opts *StreamOptions) <-chan AssistantMessageEvent {
	cfg := GetConfig()
	resolved := cfg.Resolve(opts, model)
	return StreamOpenAI(ctx, model, msgCtx, resolved)
}
