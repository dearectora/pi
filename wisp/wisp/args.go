package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Args holds parsed command-line arguments.
type Args struct {
	Help        bool
	Version     bool
	Model       string
	Provider    string
	Temperature *float64
	MaxTokens   *int
	JSONMode    bool
	NoLog       bool
	Prompt      string // empty means "read from stdin"
	Warnings    []string
}

func parseArgs(argv []string) Args {
	var a Args
	var promptParts []string

	for i := 0; i < len(argv); i++ {
		arg := argv[i]

		// --flag=value form
		if strings.HasPrefix(arg, "--") {
			if eq := strings.IndexByte(arg, '='); eq != -1 {
				consumeFlag(&a, arg[:eq], arg[eq+1:])
				continue
			}
		}

		switch arg {
		case "-h", "--help":
			a.Help = true
		case "-v", "--version":
			a.Version = true
		case "--json":
			a.JSONMode = true
		case "--no-log":
			a.NoLog = true
		case "-m", "--model",
			"-p", "--provider",
			"--temperature", "--max-tokens",
			"--mode":
			if i+1 < len(argv) {
				i++
				consumeFlag(&a, arg, argv[i])
			} else {
				a.Warnings = append(a.Warnings, "flag "+arg+" requires a value")
			}
		default:
			if strings.HasPrefix(arg, "-") {
				a.Warnings = append(a.Warnings, "unknown flag: "+arg)
			} else {
				promptParts = append(promptParts, arg)
			}
		}
	}

	if len(promptParts) > 0 {
		a.Prompt = strings.Join(promptParts, " ")
	}
	return a
}

func consumeFlag(a *Args, flag, value string) {
	switch flag {
	case "-m", "--model":
		a.Model = value
	case "-p", "--provider":
		a.Provider = value
	case "--temperature":
		if v, err := strconv.ParseFloat(value, 64); err == nil {
			a.Temperature = &v
		} else {
			a.Warnings = append(a.Warnings, "invalid temperature: "+value)
		}
	case "--max-tokens":
		if v, err := strconv.Atoi(value); err == nil {
			a.MaxTokens = &v
		} else {
			a.Warnings = append(a.Warnings, "invalid max-tokens: "+value)
		}
	case "--mode":
		switch value {
		case "json":
			a.JSONMode = true
		case "text":
			// default, nothing to do
		default:
			a.Warnings = append(a.Warnings, "unknown mode: "+value+" (use text or json)")
		}
	}
}

func printHelp() {
	fmt.Fprint(os.Stdout, `Usage: wisp [options] [prompt]

Options:
  -m, --model <id>         Model id (e.g. gpt-4o-mini, deepseek-reasoner)
  -p, --provider <name>    Provider (e.g. openai, deepseek, groq)
      --temperature <n>    Sampling temperature 0.0–2.0
      --max-tokens <n>     Maximum output tokens
      --mode <text|json>   Output mode (default: text)
      --json               Shorthand for --mode json
      --no-log             Disable JSONL session logging
  -h, --help               Show this help
  -v, --version            Show version

Input:
  Pass the prompt as a positional argument, or pipe it via stdin.

Settings:
  ~/.pi/agent/settings.json   Global (defaultModel, defaultProvider, apiKeys…)
  ~/.pi/agent/models.json     Model definitions and provider API keys
  .pi/settings.json           Project-local overrides

Examples:
  wisp "What is the capital of France?"
  wisp -m deepseek-reasoner "Solve: x² + 5x + 6 = 0"
  wisp -p groq -m llama-3.3-70b-versatile "Explain monads"
  echo "Summarise this text" | wisp
  wisp --mode json "Tell me a joke"
  wisp --temperature 0.2 --max-tokens 256 "Write a haiku"
`)
}
