# wisp

CLI-агент для работы с кодом через любой OpenAI-совместимый LLM.
Умеет читать файлы, выполнять команды, редактировать код — и общаться через RPC-протокол с нативными UI-приложениями.

## Сборка

```bash
cd wisp/wisp
go build -o wisp .
```

---

## Режимы работы

| Режим | Команда | Описание |
|---|---|---|
| `text` | `./wisp "вопрос"` | Одиночный запрос, потоковый вывод текста |
| `json` | `./wisp --json "вопрос"` | Одиночный запрос, события в JSON Lines |
| `rpc` | `./wisp --mode rpc` | Агент с инструментами, протокол JSON Lines через stdin/stdout |

---

## Конфигурация: `~/.pi/agent/models.json`

Единственный конфигурационный файл. Содержит провайдеры, модели, API ключи и дефолты.

```bash
mkdir -p ~/.pi/agent
```

### Полная схема

```json
{
  "defaultProvider": "openai",
  "defaultModel": "gpt-4o-mini",
  "stream": {
    "temperature": 0.7,
    "maxTokens": 4096
  },
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

### Поля верхнего уровня

| Поле | Обязательное | Описание |
|---|---|---|
| `defaultProvider` | нет | Провайдер по умолчанию |
| `defaultModel` | нет | Модель по умолчанию |
| `stream.temperature` | нет | Температура генерации (0.0–2.0) |
| `stream.maxTokens` | нет | Максимум токенов в ответе |
| `providers` | **да** | Провайдеры и их модели |

### Поля провайдера

| Поле | Обязательное | Описание |
|---|---|---|
| `apiKey` | нет | API ключ провайдера |
| `baseUrl` | нет | URL API. Если не указан, модель должна задать свой |
| `models` | **да** | Список моделей |

### Поля модели

| Поле | Обязательное | Описание |
|---|---|---|
| `id` | **да** | Идентификатор модели (передаётся в запросе) |
| `name` | нет | Отображаемое название (по умолчанию = `id`) |
| `baseUrl` | нет | Переопределяет `baseUrl` провайдера |
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
  "defaultProvider": "openai",
  "defaultModel": "gpt-4o-mini",
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
        { "id": "llama3.2", "name": "Llama 3.2 (local)" },
        { "id": "qwen2.5-coder", "name": "Qwen 2.5 Coder (local)" }
      ]
    }
  }
}
```

### LM Studio

```json
{
  "providers": {
    "lmstudio": {
      "baseUrl": "http://localhost:1234/v1",
      "apiKey": "lmstudio",
      "models": [
        { "id": "meta-llama-3.1-8b-instruct", "name": "Llama 3.1 8B (LM Studio)" }
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

### Прокси / корпоративный шлюз

```json
{
  "providers": {
    "my-proxy": {
      "baseUrl": "https://proxy.company.com/v1",
      "apiKey": "internal-token",
      "models": [
        { "id": "gpt-4o", "name": "GPT-4o via proxy", "contextWindow": 128000, "maxTokens": 16384 }
      ]
    }
  }
}
```

---

## Использование: одиночный запрос

```bash
# Простой вопрос
./wisp "Что такое монада?"

# Конкретная модель или провайдер
./wisp -m gpt-4o "Напиши хайку"
./wisp -p deepseek -m deepseek-reasoner "Реши: x² + 5x + 6 = 0"
./wisp -p openrouter -m "meta-llama/llama-3.3-70b-instruct" "Привет"

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

## RPC-режим (агент с инструментами)

RPC-режим превращает wisp в полноценного кодинг-агента. Wisp читает команды из stdin и пишет события в stdout в формате JSON Lines (одна JSON-строка на строку). История сообщений хранится между запросами внутри сессии.

```bash
./wisp --mode rpc
./wisp --mode rpc -m gpt-4o -p openai
```

### Инструменты агента

В RPC-режиме модель имеет доступ к семи встроенным инструментам:

| Инструмент | Описание |
|---|---|
| `bash` | Выполняет shell-команды, возвращает stdout+stderr |
| `read` | Читает файл с поддержкой offset/limit |
| `write` | Создаёт или перезаписывает файл, создаёт родительские директории |
| `edit` | Точечная замена текста — каждый `oldText` должен быть уникальным в файле |
| `grep` | Поиск по regex в файлах с фильтром по glob |
| `find` | Поиск файлов по glob-паттерну, поддерживает `**` |
| `ls` | Листинг директории |

### Команды (stdin → wisp)

```jsonc
{ "type": "prompt",      "message": "Добавь тесты для функции foo", "id": "1" }
{ "type": "follow_up",   "message": "Теперь запусти их", "id": "2" }
{ "type": "abort",       "id": "3" }
{ "type": "new_session" }
{ "type": "get_state" }
{ "type": "get_messages" }
{ "type": "set_model",         "provider": "openai", "modelId": "gpt-4o" }
{ "type": "get_available_models" }
{ "type": "set_system_prompt", "systemPrompt": "Ты эксперт по Go..." }
```

Поле `id` опционально — если указано, возвращается в ответе для сопоставления запрос/ответ.

### События (wisp → stdout)

**Ответ на команду:**
```json
{ "type": "response", "id": "1", "command": "prompt", "success": true }
{ "type": "response", "command": "set_model", "success": false, "error": "model \"x\" not found" }
```

**Стриминг ответа:**
```json
{ "type": "start" }
{ "type": "textDelta", "delta": "Хорошо, " }
{ "type": "textDelta", "delta": "давай добавим тесты." }
{ "type": "textEnd",   "content": "Хорошо, давай добавим тесты." }
{ "type": "toolCallStart", "index": 0 }
{ "type": "toolCallDelta", "index": 0, "delta": "{\"path\":\"main_test.go\"..." }
{ "type": "toolCallEnd",   "index": 0, "part": { "type": "toolCall", "name": "write", ... } }
{ "type": "done", "message": { "role": "assistant", "model": "gpt-4o", ... } }
```

### Интеграция с нативным UI (Swift/macOS)

Wisp в RPC-режиме — это обычный дочерний процесс. Нативное приложение общается с ним через `Pipe`:

```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "/path/to/wisp")
process.arguments = ["--mode", "rpc"]

let inputPipe = Pipe()
let outputPipe = Pipe()
process.standardInput = inputPipe
process.standardOutput = outputPipe
try process.run()

// Отправить команду
let cmd = #"{"type":"prompt","message":"Привет"}"# + "\n"
inputPipe.fileHandleForWriting.write(cmd.data(using: .utf8)!)

// Читать события построчно из outputPipe
```

---

## Логи сессий

В режимах `text` и `json` каждый запрос записывается в `~/.pi/agent/sessions/` в формате JSONL.
Отключить: флаг `--no-log`.

В RPC-режиме логирование не ведётся — история хранится в памяти сессии.

---

## Переменные окружения

| Переменная | Описание |
|---|---|
| `PI_CODING_AGENT_DIR` | Переопределяет путь к директории агента (по умолчанию `~/.pi/agent`) |
