import Foundation

// MARK: - Model

public struct Model: Codable {
    public let id: String
    public let name: String
    public let provider: String
    public let baseURL: String
    public let contextWindow: Int
    public let maxTokens: Int
    public let cost: ModelCost
    public let supportsThinking: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, provider, baseURL = "baseUrl", contextWindow, maxTokens, cost, supportsThinking
    }
}

// MARK: - Model registry

public struct ModelRegistry {
    private let models: [Model]

    init(models: [Model] = []) { self.models = models }

    public func all() -> [Model] { models }

    public func forProvider(_ provider: String) -> [Model] {
        models.filter { $0.provider.lowercased() == provider.lowercased() }
    }

    public func find(provider: String, id: String) -> Model? {
        models.first {
            $0.provider.lowercased() == provider.lowercased() &&
            $0.id.lowercased() == id.lowercased()
        }
    }

    public func findByID(_ id: String) -> Model? {
        models.first { $0.id.lowercased() == id.lowercased() }
    }
}

// MARK: - Config

public struct Config {
    public let defaultProvider: String
    public let defaultModel: String
    public let stream: StreamDefaults?
    public let retry: RetrySettings?
    public let registry: ModelRegistry
    public let loadError: Error?
    private let apiKeys: [String: String]

    init(defaultProvider: String = "", defaultModel: String = "",
         stream: StreamDefaults? = nil, retry: RetrySettings? = nil,
         registry: ModelRegistry = ModelRegistry(), loadError: Error? = nil,
         apiKeys: [String: String] = [:]) {
        self.defaultProvider = defaultProvider; self.defaultModel = defaultModel
        self.stream = stream; self.retry = retry; self.registry = registry
        self.loadError = loadError; self.apiKeys = apiKeys
    }

    public func apiKey(for provider: String) -> String {
        apiKeys[provider.lowercased()] ?? ""
    }

    public func resolve(_ options: StreamOptions?, for model: Model) -> StreamOptions {
        var out = options ?? StreamOptions()
        if out.apiKey.isEmpty { out.apiKey = apiKey(for: model.provider) }
        if let s = stream {
            if out.temperature == nil { out.temperature = s.temperature }
            if out.maxTokens == nil   { out.maxTokens = s.maxTokens }
        }
        return out
    }
}

// MARK: - Path helpers

public func agentDir() -> String {
    if let d = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"] { return d }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return (home as NSString).appendingPathComponent(".pi/agent")
}

public func modelsPath() -> String {
    (agentDir() as NSString).appendingPathComponent("models.json")
}

// MARK: - models.json wire types

private struct ModelsFile: Decodable {
    let defaultProvider: String?
    let defaultModel: String?
    let stream: StreamDefaults?
    let retry: RetrySettings?
    let providers: [String: ProviderConfig]?
}

private struct ProviderConfig: Decodable {
    let name: String?
    let baseUrl: String?
    let apiKey: String?
    let models: [ModelDefinition]?
}

private struct ModelDefinition: Decodable {
    let id: String
    let name: String?
    let baseUrl: String?
    let contextWindow: Int?
    let maxTokens: Int?
    let cost: CostDef?
    let supportsThinking: Bool?

    struct CostDef: Decodable {
        let input: Double
        let output: Double
    }
}

// MARK: - Loader

public func getConfig() -> Config {
    loadConfig(path: modelsPath())
}

public func loadConfig(path: String) -> Config {
    guard let data = FileManager.default.contents(atPath: path) else {
        return Config()
    }
    do {
        let f = try JSONDecoder().decode(ModelsFile.self, from: data)
        var keys: [String: String] = [:]
        var models: [Model] = []

        for (providerID, prov) in f.providers ?? [:] {
            let pid = providerID.lowercased()
            if let key = prov.apiKey, !key.isEmpty { keys[pid] = key }
            for def in prov.models ?? [] {
                guard !def.id.isEmpty else { continue }
                let baseURL = def.baseUrl ?? prov.baseUrl ?? ""
                let m = Model(
                    id: def.id,
                    name: def.name ?? def.id,
                    provider: pid,
                    baseURL: baseURL,
                    contextWindow: def.contextWindow ?? 0,
                    maxTokens: def.maxTokens ?? 0,
                    cost: ModelCost(input: def.cost?.input ?? 0, output: def.cost?.output ?? 0),
                    supportsThinking: def.supportsThinking ?? false
                )
                models.append(m)
            }
        }
        return Config(
            defaultProvider: f.defaultProvider ?? "",
            defaultModel: f.defaultModel ?? "",
            stream: f.stream,
            retry: f.retry,
            registry: ModelRegistry(models: models),
            apiKeys: keys
        )
    } catch {
        return Config(loadError: error)
    }
}
