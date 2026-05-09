import Foundation

// MARK: - ModelRegistry

/// Хранилище моделей с поддержкой загрузки из JSON.
///
/// Пример — загрузить встроенный каталог:
/// ```swift
/// let registry = try ModelRegistry.bundled()
/// let model = registry.model(provider: "openai", id: "gpt-4o")
/// ```
///
/// Пример — загрузить свой файл:
/// ```swift
/// let registry = try ModelRegistry.load(from: url)
/// ```
///
/// Пример — загрузить из строки прямо в коде:
/// ```swift
/// let registry = try ModelRegistry.load(from: jsonString)
/// ```
public struct ModelRegistry: Sendable {

    public let models: [Model]

    public init(models: [Model]) {
        self.models = models
    }

    // MARK: - Загрузка

    /// Загружает встроенный `models.json` из бандла пакета.
    public static func bundled() throws -> ModelRegistry {
        guard let url = Bundle.module.url(forResource: "models", withExtension: "json") else {
            throw ModelRegistryError.bundledFileNotFound
        }
        return try load(from: url)
    }

    /// Загружает модели из файла по URL.
    public static func load(from url: URL) throws -> ModelRegistry {
        let data = try Data(contentsOf: url)
        return try load(from: data)
    }

    /// Загружает модели из JSON-строки.
    public static func load(from jsonString: String) throws -> ModelRegistry {
        guard let data = jsonString.data(using: .utf8) else {
            throw ModelRegistryError.invalidEncoding
        }
        return try load(from: data)
    }

    /// Загружает модели из `Data`.
    public static func load(from data: Data) throws -> ModelRegistry {
        let decoder = JSONDecoder()
        do {
            let models = try decoder.decode([Model].self, from: data)
            return ModelRegistry(models: models)
        } catch let decodingError as DecodingError {
            throw ModelRegistryError.decodingFailed(decodingError)
        }
    }

    // MARK: - Поиск

    /// Возвращает модель по провайдеру и id, или `nil` если не найдена.
    public func model(provider: String, id: String) -> Model? {
        models.first { $0.provider == provider && $0.id == id }
    }

    /// Возвращает все модели указанного провайдера.
    public func models(for provider: String) -> [Model] {
        models.filter { $0.provider == provider }
    }

    /// Список всех провайдеров (без дублей, отсортированный).
    public var providers: [String] {
        Array(Set(models.map { $0.provider })).sorted()
    }

    /// Все модели с поддержкой reasoning/thinking.
    public var thinkingModels: [Model] {
        models.filter { $0.supportsThinking }
    }
}

// MARK: - Errors

public enum ModelRegistryError: Error, LocalizedError {
    case bundledFileNotFound
    case invalidEncoding
    case decodingFailed(DecodingError)

    public var errorDescription: String? {
        switch self {
        case .bundledFileNotFound:
            return "Встроенный файл models.json не найден в бандле"
        case .invalidEncoding:
            return "Строка не может быть закодирована в UTF-8"
        case .decodingFailed(let error):
            return "Ошибка декодирования JSON: \(error.localizedDescription)"
        }
    }
}
