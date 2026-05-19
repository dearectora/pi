package wispai

import "time"

// DiagnosticErrorInfo holds structured error details for a diagnostic entry.
type DiagnosticErrorInfo struct {
	Name    string `json:"name,omitempty"`
	Message string `json:"message"`
	Code    string `json:"code,omitempty"`
}

// AssistantMessageDiagnostic records a diagnostic event attached to a message.
type AssistantMessageDiagnostic struct {
	Type      string               `json:"type"`
	Timestamp time.Time            `json:"timestamp"`
	Error     *DiagnosticErrorInfo `json:"error,omitempty"`
	Details   map[string]string    `json:"details,omitempty"`
}

// AppendDiagnostic adds a diagnostic with a plain message string.
func (msg *AssistantMessage) AppendDiagnostic(diagType, errMessage string, details map[string]string) {
	msg.Diagnostics = append(msg.Diagnostics, AssistantMessageDiagnostic{
		Type:      diagType,
		Timestamp: time.Now(),
		Error:     &DiagnosticErrorInfo{Message: errMessage},
		Details:   details,
	})
}

// AppendDiagnosticErr adds a diagnostic from an error value.
func (msg *AssistantMessage) AppendDiagnosticErr(diagType string, err error, details map[string]string) {
	msg.AppendDiagnostic(diagType, err.Error(), details)
}
