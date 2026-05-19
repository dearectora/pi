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

	// Load settings (global ~/.pi/agent/settings.json + project .pi/settings.json).
	wispai.ReloadSettings("", "")
	settings := wispai.GetSettings()

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
	model := resolveModel(args, settings)

	// Build and resolve stream options.
	callerOpts := &wispai.StreamOptions{
		APIKey:      args.APIKey,
		Temperature: args.Temperature,
		MaxTokens:   args.MaxTokens,
	}
	opts := settings.Resolve(callerOpts, model)

	// Validate API key presence.
	if opts.APIKey == "" {
		if envVar := wispai.EnvVarName(model.Provider); envVar != "" {
			fmt.Fprintf(os.Stderr,
				"Error: no API key found for provider %q.\nSet %s or add it to ~/.pi/agent/settings.json under apiKeys.\n",
				model.Provider, envVar,
			)
			os.Exit(1)
		}
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
	ch := wispai.Stream(ctx, model, msgCtx, &opts)

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

// resolveModel selects a model in priority order:
//  1. --provider + --model  (exact match in registry)
//  2. --model only          (first match by id)
//  3. --provider only       (first model for that provider)
//  4. settings defaults
//  5. fallback: gpt-4o-mini
func resolveModel(args Args, settings *wispai.SettingsManager) wispai.Model {
	registry := wispai.NewRegistry()

	provider := args.Provider
	modelID := args.Model
	if provider == "" {
		provider = settings.Settings.DefaultProvider
	}
	if modelID == "" {
		modelID = settings.Settings.DefaultModel
	}

	if provider != "" && modelID != "" {
		if m, ok := registry.Find(provider, modelID); ok {
			return m
		}
	}
	if modelID != "" {
		if m, ok := registry.FindByID(modelID); ok {
			return m
		}
	}
	if provider != "" {
		if models := registry.ForProvider(provider); len(models) > 0 {
			return models[0]
		}
	}
	return wispai.GPT4oMini
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
