package wispai

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// Settings mirrors the ~/.pi/agent/settings.json schema.
type Settings struct {
	DefaultProvider string            `json:"defaultProvider,omitempty"`
	DefaultModel    string            `json:"defaultModel,omitempty"`
	APIKeys         map[string]string `json:"apiKeys,omitempty"`
	Retry           *RetrySettings    `json:"retry,omitempty"`
	Stream          *StreamDefaults   `json:"stream,omitempty"`
}

// RetrySettings controls request retry behaviour.
type RetrySettings struct {
	Enabled     *bool `json:"enabled,omitempty"`
	MaxRetries  *int  `json:"maxRetries,omitempty"`
	BaseDelayMs *int  `json:"baseDelayMs,omitempty"`
	TimeoutMs   *int  `json:"timeoutMs,omitempty"`
}

// StreamDefaults are default streaming parameters applied when the caller
// does not provide them.
type StreamDefaults struct {
	Temperature *float64 `json:"temperature,omitempty"`
	MaxTokens   *int     `json:"maxTokens,omitempty"`
}

// Merge returns a new Settings where non-zero fields in override replace
// the corresponding fields in s. API key maps are merged with override winning.
func (s Settings) Merge(override Settings) Settings {
	out := s
	if override.DefaultProvider != "" {
		out.DefaultProvider = override.DefaultProvider
	}
	if override.DefaultModel != "" {
		out.DefaultModel = override.DefaultModel
	}
	if override.APIKeys != nil {
		merged := make(map[string]string)
		for k, v := range s.APIKeys {
			merged[k] = v
		}
		for k, v := range override.APIKeys {
			merged[k] = v
		}
		out.APIKeys = merged
	}
	if override.Retry != nil {
		if s.Retry == nil {
			out.Retry = override.Retry
		} else {
			r := *s.Retry
			if override.Retry.Enabled != nil {
				r.Enabled = override.Retry.Enabled
			}
			if override.Retry.MaxRetries != nil {
				r.MaxRetries = override.Retry.MaxRetries
			}
			if override.Retry.BaseDelayMs != nil {
				r.BaseDelayMs = override.Retry.BaseDelayMs
			}
			if override.Retry.TimeoutMs != nil {
				r.TimeoutMs = override.Retry.TimeoutMs
			}
			out.Retry = &r
		}
	}
	if override.Stream != nil {
		if s.Stream == nil {
			out.Stream = override.Stream
		} else {
			sd := *s.Stream
			if override.Stream.Temperature != nil {
				sd.Temperature = override.Stream.Temperature
			}
			if override.Stream.MaxTokens != nil {
				sd.MaxTokens = override.Stream.MaxTokens
			}
			out.Stream = &sd
		}
	}
	return out
}

// SettingsLoadError records a problem reading or parsing a settings file.
type SettingsLoadError struct {
	Path string
	Err  error
}

func (e *SettingsLoadError) Error() string { return e.Path + ": " + e.Err.Error() }

// SettingsManager holds merged settings and any errors encountered while
// loading the files.
type SettingsManager struct {
	Settings Settings
	Errors   []*SettingsLoadError
}

// AgentDir returns the agent directory, respecting PI_CODING_AGENT_DIR.
func AgentDir() string {
	if d := os.Getenv("PI_CODING_AGENT_DIR"); d != "" {
		return d
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".pi", "agent")
}

// GlobalSettingsPath returns the default path for the global settings file.
func GlobalSettingsPath() string {
	return filepath.Join(AgentDir(), "settings.json")
}

// ProjectSettingsPath returns the project-local settings path for the given cwd.
func ProjectSettingsPath(cwd string) string {
	return filepath.Join(cwd, ".pi", "settings.json")
}

// LoadSettings loads and deep-merges global + project settings.
// Empty string arguments use the default paths.
func LoadSettings(globalPath, projectPath string) *SettingsManager {
	if globalPath == "" {
		globalPath = GlobalSettingsPath()
	}
	if projectPath == "" {
		cwd, _ := os.Getwd()
		projectPath = ProjectSettingsPath(cwd)
	}

	mgr := &SettingsManager{}
	global, err := loadSettingsFile(globalPath)
	if err != nil {
		mgr.Errors = append(mgr.Errors, &SettingsLoadError{Path: globalPath, Err: err})
	}
	project, err := loadSettingsFile(projectPath)
	if err != nil {
		mgr.Errors = append(mgr.Errors, &SettingsLoadError{Path: projectPath, Err: err})
	}
	mgr.Settings = global.Merge(project)
	return mgr
}

func loadSettingsFile(path string) (Settings, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return Settings{}, nil
		}
		return Settings{}, err
	}
	var s Settings
	if err := json.Unmarshal(data, &s); err != nil {
		return Settings{}, err
	}
	return s, nil
}

// APIKey resolves the API key for a provider from settings files only.
// Priority: settings.json apiKeys > models.json provider apiKey.
func (m *SettingsManager) APIKey(provider string) string {
	if m.Settings.APIKeys != nil {
		if key, ok := m.Settings.APIKeys[strings.ToLower(provider)]; ok && key != "" {
			return key
		}
	}
	return ""
}

// Resolve fills missing fields in opts from settings defaults and returns the
// complete StreamOptions to pass to a provider.
func (m *SettingsManager) Resolve(opts *StreamOptions, model Model) StreamOptions {
	var out StreamOptions
	if opts != nil {
		out = *opts
	}
	if out.APIKey == "" {
		out.APIKey = m.APIKey(model.Provider)
	}
	if m.Settings.Stream != nil {
		if out.Temperature == nil {
			out.Temperature = m.Settings.Stream.Temperature
		}
		if out.MaxTokens == nil {
			out.MaxTokens = m.Settings.Stream.MaxTokens
		}
	}
	return out
}
