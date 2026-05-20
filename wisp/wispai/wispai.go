// Package wispai is an OpenAI-compatible LLM streaming client.
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

// Stream starts a streaming request. The returned channel is closed after
// the done or error event.
func Stream(ctx context.Context, config *Config, model Model, msgCtx *Context, opts *StreamOptions) <-chan AssistantMessageEvent {
	resolved := config.Resolve(opts, model)
	return StreamOpenAI(ctx, model, msgCtx, resolved)
}
