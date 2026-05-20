// Package wispai is an OpenAI-compatible LLM streaming client.
package wispai

import "context"

// GetConfig loads and returns the Config from models.json.
func GetConfig() *Config {
	return loadConfig(ModelsPath())
}

// Stream starts a streaming request. The returned channel is closed after
// the done or error event.
func Stream(ctx context.Context, config *Config, model Model, msgCtx *Context, opts *StreamOptions) <-chan AssistantMessageEvent {
	resolved := config.Resolve(opts, model)
	return StreamOpenAI(ctx, model, msgCtx, resolved)
}
