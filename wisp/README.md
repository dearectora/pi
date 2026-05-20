# wisp

Минималистичный CLI для стриминга ответов от любого OpenAI-совместимого LLM.

## Сборка

```bash
cd wisp/wisp
go build -o wisp .
```

---

## Конфигурация

Wisp читает два файла при запуске:

| Файл | Назначение |
|---|---|
| `~/.pi/agent/settings.json` | API ключи, модель по умолчанию |
| `~/.pi/agent/models.json` | Список моделей и провайдеров |

Создайте папку если её нет:

```bash
mkdir -p ~/.pi/agent
```

---

## API ключи

Ключи указываются только через файлы конфигурации. Два места:

### `~/.pi/agent/settings.json`

```json
{
  "defaultProvider": "openai",
  "defaultModel": "gpt-4o-mini",
  "apiKeys": {
    "openai": "sk-...",
    "deepseek": "sk-...",
    "groq": "gsk_..."
  }
}
```

### `~/.pi/agent/models.json` — поле `apiKey` у провайдера

```json
{
  "providers": {
    "openai": {
      "apiKey": "sk-...",
      "models": [...]
    }
  }
}
```

Если ключ задан в обоих файлах — `settings.json` побеждает.

---

## Модели: `~/.pi/agent/models.json`

Все модели описываются в этом файле. Без него wisp не запустится.

### Минимальный пример

```json
{
  "providers": {
    "openai": {
      "apiKey": "sk-...",
      "models": [
        {
          "id": "gpt-4o-mini",
          "name": "GPT-4o Mini",
          "contextWindow": 128000,
          "maxTokens": 16384,
          "cost": { "input": 0.15, "output": 0.60 }
        }
      ]
    }
  }
}
```

### Поля провайдера

| Поле | Обязательное | Описание |
|---|---|---|
| `baseUrl` | нет | URL API. Если не указан, модель должна задать свой |
| `apiKey` | нет | API ключ провайдера |
| `models` | да | Список моделей |

### Поля модели

| Поле | Обязательное | Описание |
|---|---|---|
| `id` | **да** | Идентификатор модели (передаётся в запросе) |
| `name` | нет | Отображаемое название (по умолчанию = `id`) |
| `baseUrl` | нет | Переопределяет `baseUrl` провайдера для этой модели |
| `contextWindow` | нет | Максимальный контекст в токенах |
| `maxTokens` | нет | Максимум токенов в ответе |
| `cost.input` | нет | Цена входных токенов ($ за 1M) |
| `cost.output` | нет | Цена выходных токенов ($ за 1M) |
| `supportsThinking` | нет | `true` если модель поддерживает extended thinking |

---

## Примеры конфигурации

### Несколько облачных провайдеров

```json
{
  "providers": {
    "openai": {
      "apiKey": "sk-...",
      "models": [
        {
          "id": "gpt-4o",
          "name": "GPT-4o",
          "contextWindow": 128000,
          "maxTokens": 16384,
          "cost": { "input": 2.50, "output": 10.00 }
        },
        {
          "id": "gpt-4o-mini",
          "name": "GPT-4o Mini",
          "contextWindow": 128000,
          "maxTokens": 16384,
          "cost": { "input": 0.15, "output": 0.60 }
        }
      ]
    },
    "deepseek": {
      "apiKey": "sk-...",
      "models": [
        {
          "id": "deepseek-chat",
          "name": "DeepSeek V3",
          "contextWindow": 64000,
          "maxTokens": 8000,
          "cost": { "input": 0.27, "output": 1.10 }
        },
        {
          "id": "deepseek-reasoner",
          "name": "DeepSeek R1",
          "contextWindow": 64000,
          "maxTokens": 8000,
          "cost": { "input": 0.55, "output": 2.19 },
          "supportsThinking": true
        }
      ]
    }
  }
}
```

### Ollama (локальные модели)

Ollama запускает OpenAI-совместимый API на `http://localhost:11434/v1`.
API ключ можно указать любой — Ollama его игнорирует.

```bash
# Установить и запустить модель
ollama pull llama3.2
ollama pull qwen2.5-coder
```

```json
{
  "providers": {
    "ollama": {
      "baseUrl": "http://localhost:11434/v1",
      "apiKey": "ollama",
      "models": [
        {
          "id": "llama3.2",
          "name": "Llama 3.2 (local)"
        },
        {
          "id": "qwen2.5-coder",
          "name": "Qwen 2.5 Coder (local)"
        }
      ]
    }
  }
}
```

```bash
./wisp -p ollama -m llama3.2 "Объясни рекурсию"
```

### LM Studio

LM Studio поднимает сервер на `http://localhost:1234/v1`.

```json
{
  "providers": {
    "lmstudio": {
      "baseUrl": "http://localhost:1234/v1",
      "apiKey": "lmstudio",
      "models": [
        {
          "id": "meta-llama-3.1-8b-instruct",
          "name": "Llama 3.1 8B (LM Studio)"
        }
      ]
    }
  }
}
```

### Прокси / корпоративный шлюз

```json
{
  "providers": {
    "my-proxy": {
      "baseUrl": "https://proxy.company.com/v1",
      "apiKey": "internal-token",
      "models": [
        {
          "id": "gpt-4o",
          "name": "GPT-4o via proxy",
          "contextWindow": 128000,
          "maxTokens": 16384
        }
      ]
    }
  }
}
```

### OpenRouter (100+ моделей через один ключ)

```json
{
  "providers": {
    "openrouter": {
      "baseUrl": "https://openrouter.ai/api/v1",
      "apiKey": "sk-or-...",
      "models": [
        {
          "id": "meta-llama/llama-3.3-70b-instruct",
          "name": "Llama 3.3 70B",
          "contextWindow": 128000,
          "maxTokens": 32768,
          "cost": { "input": 0.10, "output": 0.30 }
        },
        {
          "id": "google/gemini-2.5-flash",
          "name": "Gemini 2.5 Flash",
          "contextWindow": 1000000,
          "maxTokens": 8192,
          "cost": { "input": 0.15, "output": 0.60 }
        }
      ]
    }
  }
}
```

```bash
./wisp -p openrouter -m "meta-llama/llama-3.3-70b-instruct" "Привет"
```

---

## Использование

```bash
# Простой вопрос
./wisp "Что такое монада?"

# Указать конкретную модель
./wisp -m gpt-4o "Напиши хайку"
./wisp -p deepseek -m deepseek-reasoner "Реши: x² + 5x + 6 = 0"

# Пайп из stdin
echo "Переведи на английский: Привет мир" | ./wisp
cat README.md | ./wisp "Кратко изложи содержимое"

# JSON-режим (одна JSON-строка на событие)
./wisp --json "Расскажи анекдот"

# Параметры генерации
./wisp --temperature 0.2 --max-tokens 256 "Напиши формулу"

# Без записи в лог
./wisp --no-log "Секретный вопрос"
```

---

## Логи сессий

По умолчанию каждый запрос записывается в `~/.pi/agent/sessions/` в формате JSONL.
Отключить: флаг `--no-log`.
