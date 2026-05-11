import Foundation

// MARK: - DiagnosticErrorInfo

/// Normalized representation of any error attached to a diagnostic entry.
public struct DiagnosticErrorInfo: Sendable {
    /// Swift type name of the original error (e.g. "WispError", "URLError").
    public var name: String?
    /// Human-readable error description.
    public var message: String
    /// Provider-level or HTTP error code when available (e.g. "401", "ECONNREFUSED").
    public var code: String?

    public init(name: String? = nil, message: String, code: String? = nil) {
        self.name = name
        self.message = message
        self.code = code
    }

    /// Extracts normalized info from any Swift `Error`.
    public static func extract(from error: Error) -> DiagnosticErrorInfo {
        let typeName = String(describing: type(of: error))
        let message  = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

        let code: String?
        switch error {
        case WispError.httpError(let statusCode, _):
            code = "\(statusCode)"
        case let urlError as URLError:
            code = "\(urlError.code.rawValue)"
        default:
            code = nil
        }

        return DiagnosticErrorInfo(name: typeName, message: message, code: code)
    }
}

// MARK: - AssistantMessageDiagnostic

/// A single structured diagnostic record attached to an `AssistantMessage`.
public struct AssistantMessageDiagnostic: Sendable {
    /// Dot-namespaced event identifier, e.g. `"http_error"`, `"network_error"`.
    public var type: String
    /// Wall-clock time when the diagnostic was recorded.
    public var timestamp: Date
    /// Normalized error information, if the diagnostic is error-driven.
    public var error: DiagnosticErrorInfo?
    /// Arbitrary string key–value pairs for extra context (status codes, URLs, etc.).
    public var details: [String: String]

    public init(
        type: String,
        error: DiagnosticErrorInfo? = nil,
        details: [String: String] = [:],
        timestamp: Date = Date()
    ) {
        self.type      = type
        self.timestamp = timestamp
        self.error     = error
        self.details   = details
    }
}

// MARK: - AssistantMessage helpers

public extension AssistantMessage {

    /// Appends a diagnostic derived from a Swift `Error`.
    mutating func appendDiagnostic(
        type: String,
        error: Error,
        details: [String: String] = [:]
    ) {
        let info = DiagnosticErrorInfo.extract(from: error)
        diagnostics.append(AssistantMessageDiagnostic(type: type, error: info, details: details))
    }

    /// Appends a diagnostic with a plain message (no underlying `Error`).
    mutating func appendDiagnostic(
        type: String,
        message: String,
        details: [String: String] = [:]
    ) {
        let info = DiagnosticErrorInfo(message: message)
        diagnostics.append(AssistantMessageDiagnostic(type: type, error: info, details: details))
    }
}
