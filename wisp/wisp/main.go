package main

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"strings"

	"wispai"
)

const version = "0.1.0"

func main() {
	args := parseArgs(os.Args[1:])
	for _, w := range args.Warnings {
		fmt.Fprintf(os.Stderr, "Warning: %s\n", w)
	}
	if args.Help {
		printHelp()
		os.Exit(0)
	}
	if args.Version {
		fmt.Printf("wisp %s\n", version)
		os.Exit(0)
	}

	config := wispai.GetConfig()

	// Surface any models.json parse error early.
	if err := config.LoadError(); err != nil {
		fmt.Fprintf(os.Stderr, "Error loading models.json: %v\n", err)
		os.Exit(1)
	}

	// Resolve prompt: argument > stdin.
	prompt := args.Prompt
	if prompt == "" {
		if isTTY() {
			fmt.Fprintln(os.Stderr, "Error: no prompt provided. Run `wisp --help` for usage.")
			os.Exit(1)
		}
		prompt = readStdin()
		if prompt == "" {
			fmt.Fprintln(os.Stderr, "Error: no prompt provided. Run `wisp --help` for usage.")
			os.Exit(1)
		}
	}

	// Resolve model.
	model, err := resolveModel(args, config)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}

	// Build and resolve stream options.
	callerOpts := &wispai.StreamOptions{
		Temperature: args.Temperature,
		MaxTokens:   args.MaxTokens,
	}
	opts := config.Resolve(callerOpts, model)

	// Validate that we have an API key.
	if opts.APIKey == "" {
		fmt.Fprintf(os.Stderr,
			"Error: no API key found for provider %q.\n"+
				"Add it to ~/.pi/agent/models.json under the provider's \"apiKey\" field.\n",
			model.Provider,
		)
		os.Exit(1)
	}

	// RPC mode: read commands from stdin, write events to stdout.
	if args.RPCMode {
		tools, handler := wispai.DefaultTools()
		systemPrompt := wispai.BuildSystemPrompt()
		wispai.RunRPC(context.Background(), config, model, opts, tools, handler, systemPrompt, os.Stdin, os.Stdout)
		os.Exit(0)
	}

	// Open session logger (skipped with --no-log).
	var logger *SessionLogger
	if !args.NoLog {
		lg, err := NewSessionLogger(model)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Warning: could not open session log: %v\n", err)
		} else {
			logger = lg
			defer logger.Close()
		}
	}
	if logger != nil {
		if err := logger.LogUserMessage(prompt); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: session log write failed: %v\n", err)
		}
	}

	// Stream.
	ctx := context.Background()
	msgCtx := &wispai.Context{
		Messages: []wispai.ContextMessage{wispai.UserMsg(prompt)},
	}
	ch := wispai.Stream(ctx, config, model, msgCtx, &opts)

	var exitCode int
	var finalMsg *wispai.AssistantMessage
	if args.JSONMode {
		exitCode, finalMsg = RunJSONMode(ch)
	} else {
		exitCode, finalMsg = RunTextMode(ch)
	}

	if logger != nil && finalMsg != nil {
		if err := logger.LogAssistantMessage(finalMsg); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: session log write failed: %v\n", err)
		}
	}

	os.Exit(exitCode)
}

// resolveModel picks a model from the registry in priority order:
//  1. --provider + --model  (exact match)
//  2. --model only          (first match by id across all providers)
//  3. --provider only       (first model for that provider)
//  4. config defaultProvider + defaultModel
//  5. first model in registry
func resolveModel(args Args, config *wispai.Config) (wispai.Model, error) {
	registry := config.Registry()

	if len(registry.All()) == 0 {
		return wispai.Model{}, fmt.Errorf(
			"no models loaded.\n\n"+
				"Create %s with your model configuration, for example:\n\n"+
				"%s",
			wispai.ModelsPath(),
			modelsJSONExample(),
		)
	}

	provider := args.Provider
	modelID := args.Model
	if provider == "" {
		provider = config.DefaultProvider
	}
	if modelID == "" {
		modelID = config.DefaultModel
	}

	if provider != "" && modelID != "" {
		if m, ok := registry.Find(provider, modelID); ok {
			return m, nil
		}
	}
	if modelID != "" {
		if m, ok := registry.FindByID(modelID); ok {
			return m, nil
		}
	}
	if provider != "" {
		if models := registry.ForProvider(provider); len(models) > 0 {
			return models[0], nil
		}
	}

	// No specific model requested — use first available.
	return registry.All()[0], nil
}

func modelsJSONExample() string {
	return strings.TrimSpace(`
{
  "defaultProvider": "openai",
  "defaultModel": "gpt-4o-mini",
  "providers": {
    "openai": {
      "apiKey": "sk-...",
      "models": [
        {
          "id": "gpt-4o-mini",
          "name": "GPT-4o Mini",
          "contextWindow": 128000,
          "maxTokens": 16384,
          "cost": { "input": 0.15, "output": 0.60 }
        }
      ]
    }
  }
}
`) + "\n"
}

func isTTY() bool {
	fi, err := os.Stdin.Stat()
	if err != nil {
		return true
	}
	return (fi.Mode() & os.ModeCharDevice) != 0
}

func readStdin() string {
	var lines []string
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	return strings.TrimRight(strings.Join(lines, "\n"), "\n")
}
