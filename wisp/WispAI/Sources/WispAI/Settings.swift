import Foundation

// MARK: - Settings

/// Subset of the pi `~/.pi/agent/settings.json` schema relevant to WispAI.
/// Parsed from global and project scopes and merged together.
public struct Settings: Codable, Sendable {

    // MARK: Nested types

    public struct RetrySettings: Codable, Sendable {
        /// Whether automatic retries are enabled (default: true).
        public var enabled: Bool?
        /// Maximum number of retry attempts (default: 3).
        public var maxRetries: Int?
        /// Base delay in milliseconds for exponential back-off (default: 2000).
        public var baseDelayMs: Int?
        /// Per-request timeout in milliseconds; nil = no timeout.
        public var timeoutMs: Int?

        public init(enabled: Bool? = nil, maxRetries: Int? = nil,
                    baseDelayMs: Int? = nil, timeoutMs: Int? = nil) {
            self.enabled     = enabled
            self.maxRetries  = maxRetries
            self.baseDelayMs = baseDelayMs
            self.timeoutMs   = timeoutMs
        }

        func merging(_ override: RetrySettings?) -> RetrySettings {
            guard let o = override else { return self }
            return RetrySettings(
                enabled:     o.enabled     ?? enabled,
                maxRetries:  o.maxRetries  ?? maxRetries,
                baseDelayMs: o.baseDelayMs ?? baseDelayMs,
                timeoutMs:   o.timeoutMs   ?? timeoutMs
            )
        }
    }

    public struct StreamDefaults: Codable, Sendable {
        /// Default sampling temperature applied when caller does not specify one.
        public var temperature: Double?
        /// Default max tokens applied when caller does not specify one.
        public var maxTokens: Int?

        public init(temperature: Double? = nil, maxTokens: Int? = nil) {
            self.temperature = temperature
            self.maxTokens   = maxTokens
        }

        func merging(_ override: StreamDefaults?) -> StreamDefaults {
            guard let o = override else { return self }
            return StreamDefaults(
                temperature: o.temperature ?? temperature,
                maxTokens:   o.maxTokens   ?? maxTokens
            )
        }
    }

    // MARK: Fields

    /// Preferred provider id, e.g. `"openai"`, `"deepseek"`.
    public var defaultProvider: String?
    /// Preferred model id, e.g. `"gpt-4o-mini"`.
    public var defaultModel: String?
    /// Per-provider API keys stored in settings.
    /// Key is the provider id; value is the API key string.
    public var apiKeys: [String: String]?
    /// Retry behaviour for failed HTTP requests.
    public var retry: RetrySettings?
    /// Default streaming parameters (temperature, maxTokens).
    public var stream: StreamDefaults?

    public init(
        defaultProvider: String? = nil,
        defaultModel:    String? = nil,
        apiKeys:         [String: String]? = nil,
        retry:           RetrySettings? = nil,
        stream:          StreamDefaults? = nil
    ) {
        self.defaultProvider = defaultProvider
        self.defaultModel    = defaultModel
        self.apiKeys         = apiKeys
        self.retry           = retry
        self.stream          = stream
    }

    // MARK: Deep merge

    /// Returns a new Settings where non-nil fields in `override` win.
    /// Nested structs merge field-by-field; `apiKeys` dictionaries are unioned
    /// (override keys win on collision).
    func merging(_ override: Settings) -> Settings {
        var merged = self
        if let v = override.defaultProvider { merged.defaultProvider = v }
        if let v = override.defaultModel    { merged.defaultModel    = v }
        merged.apiKeys = mergedDicts(base: apiKeys, override: override.apiKeys)
        merged.retry   = retry?.merging(override.retry)   ?? override.retry
        merged.stream  = stream?.merging(override.stream) ?? override.stream
        return merged
    }

    private func mergedDicts(
        base: [String: String]?,
        override: [String: String]?
    ) -> [String: String]? {
        switch (base, override) {
        case (.none, .none):         return nil
        case (let b?, .none):        return b
        case (.none, let o?):        return o
        case (let b?, let o?):       return b.merging(o) { _, new in new }
        }
    }
}

// MARK: - SettingsLoadError

public enum SettingsLoadError: Error, Sendable {
    /// File was absent — not an error, just signals no settings at that scope.
    case fileNotFound(path: String)
    /// File exists but could not be read or decoded.
    case invalidJSON(path: String, underlying: Error)
}

// MARK: - SettingsManager

/// Loads, merges, and queries pi-compatible settings from
/// `~/.pi/agent/settings.json` (global) and `.pi/settings.json` (project).
public struct SettingsManager: Sendable {

    // MARK: Path constants

    /// Name of the config directory (`".pi"`), matching the original pi tool.
    public static let configDirName = ".pi"

    /// Returns the global agent directory.
    ///
    /// Respects the `PI_CODING_AGENT_DIR` environment variable, exactly as the
    /// original pi does.
    public static var agentDir: String {
        if let env = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"], !env.isEmpty {
            return env
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/\(configDirName)/agent"
    }

    /// Path to the global settings file (`~/.pi/agent/settings.json`).
    public static func globalSettingsPath() -> String {
        "\(agentDir)/settings.json"
    }

    /// Path to the project-local settings file (`.pi/settings.json` in `cwd`).
    public static func projectSettingsPath(
        cwd: String = FileManager.default.currentDirectoryPath
    ) -> String {
        "\(cwd)/\(configDirName)/settings.json"
    }

    // MARK: State

    /// Fully merged settings (project overrides global).
    public let settings: Settings
    /// Parse or I/O errors encountered during loading (does not include missing files).
    public let errors: [SettingsLoadError]

    // MARK: Loading

    /// Loads global and project settings, merges them, and returns a manager.
    /// - Parameters:
    ///   - cwd:         Working directory for the project-scope file.
    ///   - globalPath:  Override the global file path (useful in tests).
    ///   - projectPath: Override the project file path (useful in tests).
    public static func load(
        cwd:         String  = FileManager.default.currentDirectoryPath,
        globalPath:  String? = nil,
        projectPath: String? = nil
    ) -> SettingsManager {
        var errors: [SettingsLoadError] = []
        let gp = globalPath  ?? globalSettingsPath()
        let pp = projectPath ?? projectSettingsPath(cwd: cwd)

        let global  = tryLoad(path: gp, errors: &errors) ?? Settings()
        let project = tryLoad(path: pp, errors: &errors) ?? Settings()
        return SettingsManager(settings: global.merging(project), errors: errors)
    }

    private init(settings: Settings, errors: [SettingsLoadError]) {
        self.settings = settings
        self.errors   = errors
    }

    private static func tryLoad(path: String, errors: inout [SettingsLoadError]) -> Settings? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            errors.append(.invalidJSON(path: path, underlying: error))
            return nil
        }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            errors.append(.invalidJSON(path: path, underlying: error))
            return nil
        }
    }

    // MARK: API key resolution

    /// Resolves the API key for a provider using the following priority:
    ///
    /// 1. Caller-supplied key (non-empty)
    /// 2. `settings.apiKeys[provider]`
    /// 3. Well-known environment variable (e.g. `OPENAI_API_KEY`)
    ///
    /// Returns `nil` when no key is available.
    public func apiKey(for provider: String, callerKey: String? = nil) -> String? {
        if let k = callerKey, !k.isEmpty { return k }
        if let k = settings.apiKeys?[provider.lowercased()], !k.isEmpty { return k }
        if let envVar = Self.envVarName(for: provider),
           let env = ProcessInfo.processInfo.environment[envVar], !env.isEmpty { return env }
        return nil
    }

    /// Returns the well-known environment variable name for a provider, matching
    /// the original `packages/ai/src/env-api-keys.ts` mapping.
    public static func envVarName(for provider: String) -> String? {
        switch provider.lowercased() {
        case "openai":              return "OPENAI_API_KEY"
        case "deepseek":            return "DEEPSEEK_API_KEY"
        case "groq":                return "GROQ_API_KEY"
        case "xai":                 return "XAI_API_KEY"
        case "minimax":             return "MINIMAX_API_KEY"
        case "cerebras":            return "CEREBRAS_API_KEY"
        case "openrouter":          return "OPENROUTER_API_KEY"
        case "mistral":             return "MISTRAL_API_KEY"
        case "anthropic":           return "ANTHROPIC_API_KEY"
        case "google":              return "GEMINI_API_KEY"
        case "fireworks":           return "FIREWORKS_API_KEY"
        case "ollama", "lm-studio", "faux": return nil // local / test — no key needed
        default:
            // Generic fallback: MYPROVIDER_API_KEY
            let normalized = provider.uppercased().replacingOccurrences(of: "-", with: "_")
            return "\(normalized)_API_KEY"
        }
    }

    // MARK: StreamOptions resolution

    /// Produces a resolved `StreamOptions` by filling any nil fields from settings.
    ///
    /// Priority for each field:
    /// - `apiKey`      → caller → `settings.apiKeys` → env var
    /// - `temperature` → caller → `settings.stream.temperature`
    /// - `maxTokens`   → caller → `settings.stream.maxTokens`
    public func resolve(options: StreamOptions?, for model: Model) -> StreamOptions {
        StreamOptions(
            apiKey:      apiKey(for: model.provider, callerKey: options?.apiKey),
            temperature: options?.temperature ?? settings.stream?.temperature,
            maxTokens:   options?.maxTokens   ?? settings.stream?.maxTokens
        )
    }
}
