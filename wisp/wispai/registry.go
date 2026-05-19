package wispai

import "strings"

// ModelRegistry is a queryable list of models.
type ModelRegistry struct {
	models []Model
}

// NewRegistry returns a registry loaded from the bundled models.json.
func NewRegistry() *ModelRegistry {
	return &ModelRegistry{models: BundledModels()}
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
