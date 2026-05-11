import XCTest
@testable import WispAI

// MARK: - Settings struct

final class SettingsStructTests: XCTestCase {

    func testDefaultsAreNil() {
        let s = Settings()
        XCTAssertNil(s.defaultProvider)
        XCTAssertNil(s.defaultModel)
        XCTAssertNil(s.apiKeys)
        XCTAssertNil(s.retry)
        XCTAssertNil(s.stream)
    }

    func testCodableRoundTrip() throws {
        let original = Settings(
            defaultProvider: "deepseek",
            defaultModel: "deepseek-reasoner",
            apiKeys: ["deepseek": "ds-key-123"],
            retry: .init(enabled: true, maxRetries: 5, baseDelayMs: 1000, timeoutMs: 30000),
            stream: .init(temperature: 0.7, maxTokens: 4096)
        )
        let data    = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        XCTAssertEqual(decoded.defaultProvider,   "deepseek")
        XCTAssertEqual(decoded.defaultModel,      "deepseek-reasoner")
        XCTAssertEqual(decoded.apiKeys?["deepseek"], "ds-key-123")
        XCTAssertEqual(decoded.retry?.maxRetries, 5)
        XCTAssertEqual(decoded.retry?.baseDelayMs, 1000)
        XCTAssertEqual(decoded.retry?.timeoutMs, 30000)
        XCTAssertEqual(decoded.stream?.temperature, 0.7, accuracy: 1e-9)
        XCTAssertEqual(decoded.stream?.maxTokens, 4096)
    }

    func testDecodingIgnoresUnknownKeys() throws {
        let json = """
        {
          "defaultProvider": "openai",
          "unknownField": "ignored",
          "anotherUnknown": 42
        }
        """
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(s.defaultProvider, "openai")
    }
}

// MARK: - Settings deep merge

final class SettingsMergeTests: XCTestCase {

    func testProjectOverridesGlobal() {
        let global  = Settings(defaultProvider: "openai", defaultModel: "gpt-4o")
        let project = Settings(defaultModel: "gpt-4o-mini")
        let merged  = global.merging(project)

        XCTAssertEqual(merged.defaultProvider, "openai")    // from global
        XCTAssertEqual(merged.defaultModel,    "gpt-4o-mini") // overridden by project
    }

    func testGlobalKeptWhenProjectNil() {
        let global  = Settings(defaultProvider: "deepseek", defaultModel: "deepseek-chat")
        let project = Settings()
        let merged  = global.merging(project)

        XCTAssertEqual(merged.defaultProvider, "deepseek")
        XCTAssertEqual(merged.defaultModel,    "deepseek-chat")
    }

    func testApiKeysMergedWithProjectWinning() {
        let global  = Settings(apiKeys: ["openai": "global-key", "deepseek": "ds-key"])
        let project = Settings(apiKeys: ["openai": "project-key", "groq": "groq-key"])
        let merged  = global.merging(project)

        XCTAssertEqual(merged.apiKeys?["openai"],   "project-key")  // project wins
        XCTAssertEqual(merged.apiKeys?["deepseek"], "ds-key")        // global preserved
        XCTAssertEqual(merged.apiKeys?["groq"],     "groq-key")      // project adds
    }

    func testRetryMergedFieldByField() {
        let global  = Settings(retry: .init(enabled: true, maxRetries: 3, baseDelayMs: 2000))
        let project = Settings(retry: .init(maxRetries: 10))
        let merged  = global.merging(project)

        XCTAssertEqual(merged.retry?.enabled,     true)  // from global
        XCTAssertEqual(merged.retry?.maxRetries,  10)    // overridden by project
        XCTAssertEqual(merged.retry?.baseDelayMs, 2000)  // from global
    }

    func testStreamMergedFieldByField() {
        let global  = Settings(stream: .init(temperature: 0.5, maxTokens: 2048))
        let project = Settings(stream: .init(temperature: 0.9))
        let merged  = global.merging(project)

        XCTAssertEqual(merged.stream?.temperature, 0.9,  accuracy: 1e-9) // overridden
        XCTAssertEqual(merged.stream?.maxTokens,   2048)                  // from global
    }

    func testProjectRetryCreatedFromNilGlobal() {
        let global  = Settings()
        let project = Settings(retry: .init(maxRetries: 5))
        let merged  = global.merging(project)

        XCTAssertEqual(merged.retry?.maxRetries, 5)
    }

    func testBothEmpty() {
        let merged = Settings().merging(Settings())
        XCTAssertNil(merged.defaultProvider)
        XCTAssertNil(merged.apiKeys)
        XCTAssertNil(merged.retry)
    }
}

// MARK: - SettingsManager file loading

final class SettingsManagerLoadTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeSetting(_ content: String, name: String) throws -> String {
        let url = tmpDir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testLoadFromBothFiles() throws {
        let globalPath = try writeSetting("""
        { "defaultProvider": "openai", "defaultModel": "gpt-4o",
          "apiKeys": { "openai": "global-sk" } }
        """, name: "global.json")

        let projectPath = try writeSetting("""
        { "defaultModel": "gpt-4o-mini",
          "apiKeys": { "openai": "project-sk", "deepseek": "ds-key" },
          "stream": { "temperature": 0.3 } }
        """, name: "project.json")

        let mgr = SettingsManager.load(globalPath: globalPath, projectPath: projectPath)

        XCTAssertTrue(mgr.errors.isEmpty)
        XCTAssertEqual(mgr.settings.defaultProvider,        "openai")       // global
        XCTAssertEqual(mgr.settings.defaultModel,           "gpt-4o-mini")  // project
        XCTAssertEqual(mgr.settings.apiKeys?["openai"],     "project-sk")   // project wins
        XCTAssertEqual(mgr.settings.apiKeys?["deepseek"],   "ds-key")       // project adds
        XCTAssertEqual(mgr.settings.stream?.temperature,    0.3, accuracy: 1e-9)
    }

    func testMissingGlobalFileIsNotAnError() throws {
        let projectPath = try writeSetting(
            #"{ "defaultProvider": "groq" }"#, name: "project.json"
        )
        let mgr = SettingsManager.load(
            globalPath:  tmpDir.appendingPathComponent("nonexistent.json").path,
            projectPath: projectPath
        )
        XCTAssertTrue(mgr.errors.isEmpty)
        XCTAssertEqual(mgr.settings.defaultProvider, "groq")
    }

    func testMissingBothFilesReturnsEmptySettings() {
        let mgr = SettingsManager.load(
            globalPath:  tmpDir.appendingPathComponent("a.json").path,
            projectPath: tmpDir.appendingPathComponent("b.json").path
        )
        XCTAssertTrue(mgr.errors.isEmpty)
        XCTAssertNil(mgr.settings.defaultProvider)
    }

    func testInvalidJSONRecordsError() throws {
        let globalPath = try writeSetting("not json at all", name: "bad.json")
        let mgr = SettingsManager.load(
            globalPath:  globalPath,
            projectPath: tmpDir.appendingPathComponent("missing.json").path
        )
        XCTAssertEqual(mgr.errors.count, 1)
        if case .invalidJSON(let path, _) = mgr.errors[0] {
            XCTAssertEqual(path, globalPath)
        } else {
            XCTFail("Expected .invalidJSON error")
        }
    }

    func testBothInvalidReportsTwoErrors() throws {
        let gp = try writeSetting("{bad", name: "g.json")
        let pp = try writeSetting("{bad", name: "p.json")
        let mgr = SettingsManager.load(globalPath: gp, projectPath: pp)
        XCTAssertEqual(mgr.errors.count, 2)
    }

    func testEmptyObjectIsValid() throws {
        let path = try writeSetting("{}", name: "empty.json")
        let mgr  = SettingsManager.load(globalPath: path, projectPath: path)
        XCTAssertTrue(mgr.errors.isEmpty)
        XCTAssertNil(mgr.settings.defaultProvider)
    }
}

// MARK: - SettingsManager.envVarName

final class EnvVarNameTests: XCTestCase {

    func testKnownProviders() {
        XCTAssertEqual(SettingsManager.envVarName(for: "openai"),     "OPENAI_API_KEY")
        XCTAssertEqual(SettingsManager.envVarName(for: "deepseek"),   "DEEPSEEK_API_KEY")
        XCTAssertEqual(SettingsManager.envVarName(for: "groq"),       "GROQ_API_KEY")
        XCTAssertEqual(SettingsManager.envVarName(for: "xai"),        "XAI_API_KEY")
        XCTAssertEqual(SettingsManager.envVarName(for: "minimax"),    "MINIMAX_API_KEY")
        XCTAssertEqual(SettingsManager.envVarName(for: "cerebras"),   "CEREBRAS_API_KEY")
        XCTAssertEqual(SettingsManager.envVarName(for: "openrouter"), "OPENROUTER_API_KEY")
        XCTAssertEqual(SettingsManager.envVarName(for: "anthropic"),  "ANTHROPIC_API_KEY")
    }

    func testLocalProvidersReturnNil() {
        XCTAssertNil(SettingsManager.envVarName(for: "ollama"))
        XCTAssertNil(SettingsManager.envVarName(for: "lm-studio"))
        XCTAssertNil(SettingsManager.envVarName(for: "faux"))
    }

    func testUnknownProviderGeneratesGenericName() {
        XCTAssertEqual(SettingsManager.envVarName(for: "myprovider"),  "MYPROVIDER_API_KEY")
        XCTAssertEqual(SettingsManager.envVarName(for: "my-provider"), "MY_PROVIDER_API_KEY")
    }

    func testCaseInsensitive() {
        XCTAssertEqual(SettingsManager.envVarName(for: "OpenAI"),  "OPENAI_API_KEY")
        XCTAssertEqual(SettingsManager.envVarName(for: "DEEPSEEK"), "DEEPSEEK_API_KEY")
    }
}

// MARK: - SettingsManager.apiKey resolution

final class ApiKeyResolutionTests: XCTestCase {

    func testCallerKeyWins() throws {
        let mgr = SettingsManager.load(
            globalPath:  "/nonexistent/g.json",
            projectPath: "/nonexistent/p.json"
        )
        let key = mgr.apiKey(for: "openai", callerKey: "caller-key")
        XCTAssertEqual(key, "caller-key")
    }

    func testSettingsKeyUsedWhenNoCallerKey() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let json = #"{ "apiKeys": { "openai": "settings-key" } }"#
        try json.write(to: tmp, atomically: true, encoding: .utf8)

        let mgr = SettingsManager.load(
            globalPath:  tmp.path,
            projectPath: "/nonexistent/p.json"
        )
        let key = mgr.apiKey(for: "openai", callerKey: nil)
        XCTAssertEqual(key, "settings-key")
    }

    func testNilReturnedWhenNothingConfigured() {
        let mgr = SettingsManager.load(
            globalPath:  "/nonexistent/g.json",
            projectPath: "/nonexistent/p.json"
        )
        // "faux" has no env var and no settings entry
        let key = mgr.apiKey(for: "faux", callerKey: nil)
        XCTAssertNil(key)
    }
}

// MARK: - SettingsManager.resolve(options:for:)

final class ResolveOptionsTests: XCTestCase {

    private func managerWithStream(temperature: Double, maxTokens: Int) throws -> SettingsManager {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let json = """
        { "stream": { "temperature": \(temperature), "maxTokens": \(maxTokens) },
          "apiKeys": { "openai": "from-settings" } }
        """
        try json.write(to: tmp, atomically: true, encoding: .utf8)
        return SettingsManager.load(
            globalPath:  tmp.path,
            projectPath: "/nonexistent/p.json"
        )
    }

    func testCallerOptionsOverrideSettings() throws {
        let mgr = try managerWithStream(temperature: 0.5, maxTokens: 1024)
        let caller = StreamOptions(apiKey: "caller-key", temperature: 0.9, maxTokens: 2048)
        let resolved = mgr.resolve(options: caller, for: .gpt4oMini)

        XCTAssertEqual(resolved.apiKey,      "caller-key")
        XCTAssertEqual(resolved.temperature, 0.9, accuracy: 1e-9)
        XCTAssertEqual(resolved.maxTokens,   2048)
    }

    func testSettingsFillMissingCallerOptions() throws {
        let mgr = try managerWithStream(temperature: 0.3, maxTokens: 512)
        let resolved = mgr.resolve(options: StreamOptions(), for: .gpt4oMini)

        XCTAssertEqual(resolved.apiKey,      "from-settings")
        XCTAssertEqual(resolved.temperature, 0.3, accuracy: 1e-9)
        XCTAssertEqual(resolved.maxTokens,   512)
    }

    func testNilOptionsFullyFilledFromSettings() throws {
        let mgr = try managerWithStream(temperature: 0.7, maxTokens: 4096)
        let resolved = mgr.resolve(options: nil, for: .gpt4oMini)

        XCTAssertEqual(resolved.apiKey,      "from-settings")
        XCTAssertEqual(resolved.temperature, 0.7, accuracy: 1e-9)
        XCTAssertEqual(resolved.maxTokens,   4096)
    }
}

// MARK: - Paths

final class SettingsPathTests: XCTestCase {

    func testGlobalPathEndsWithSettingsJSON() {
        XCTAssertTrue(SettingsManager.globalSettingsPath().hasSuffix("settings.json"))
    }

    func testProjectPathContainsDotPi() {
        let path = SettingsManager.projectSettingsPath(cwd: "/my/project")
        XCTAssertEqual(path, "/my/project/.pi/settings.json")
    }

    func testAgentDirDefaultContainsDotPi() {
        // Only valid when PI_CODING_AGENT_DIR is not set in test environment.
        if ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"] == nil {
            XCTAssertTrue(SettingsManager.agentDir.contains("/.pi/"))
        }
    }
}
