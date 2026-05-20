# wisp-clang

CLI-агент для работы с кодом через любой OpenAI-совместимый LLM, реализованный на C (clang).
Полный аналог [wisp (Go)](../wisp/README.md) и [wisp-swift](../wisp-swift/README.md) — те же возможности, та же конфигурация, тот же RPC-протокол.

## Требования

- Linux (POSIX)
- clang или gcc
- `curl` в PATH (используется для HTTP-запросов)
- pthreads (входит в libc)

cJSON [бандлится в репозитории](src/cJSON.c) — внешних зависимостей нет.

## Сборка

```bash
cd wisp-clang
make
```

Бинарник появится в `./wisp`.

```bash
make clean   # удалить бинарник
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

Единственный конфигурационный файл — тот же формат, что и в Go/Swift-версиях.

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
| `id` | **да** | Идентификатор модели |
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
        { "id": "gpt-4o", "name": "GPT-4o", "contextWindow": 128000, "maxTokens": 16384, "cost": { "input": 2.50, "output": 10.00 } },
        { "id": "gpt-4o-mini", "name": "GPT-4o Mini", "contextWindow": 128000, "maxTokens": 16384, "cost": { "input": 0.15, "output": 0.60 } }
      ]
    },
    "deepseek": {
      "apiKey": "sk-...",
      "models": [
        { "id": "deepseek-chat", "name": "DeepSeek V3", "contextWindow": 64000, "maxTokens": 8000, "cost": { "input": 0.27, "output": 1.10 } },
        { "id": "deepseek-reasoner", "name": "DeepSeek R1", "contextWindow": 64000, "maxTokens": 8000, "cost": { "input": 0.55, "output": 2.19 }, "supportsThinking": true }
      ]
    }
  }
}
```

### Ollama (локальные модели)

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

### OpenRouter

```json
{
  "providers": {
    "openrouter": {
      "baseUrl": "https://openrouter.ai/api/v1",
      "apiKey": "sk-or-...",
      "models": [
        { "id": "google/gemini-2.5-flash", "name": "Gemini 2.5 Flash", "contextWindow": 1000000, "maxTokens": 8192, "cost": { "input": 0.15, "output": 0.60 } }
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

RPC-режим превращает wisp в полноценного кодинг-агента. Читает команды из stdin и пишет события в stdout в формате JSON Lines. История сообщений хранится между запросами внутри сессии.

```bash
./wisp --mode rpc
./wisp --mode rpc -m gpt-4o -p openai
```

### Инструменты агента

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
{ "type": "set_system_prompt", "systemPrompt": "Ты эксперт по C..." }
```

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
{ "type": "textEnd",   "content": "Хорошо, давай добавим тесты." }
{ "type": "toolCallStart", "index": 0 }
{ "type": "toolCallEnd",   "index": 0, "id": "call_abc", "name": "bash", "arguments": "{\"command\":\"make test\"}" }
{ "type": "done", "message": { "role": "assistant", "model": "gpt-4o", ... } }
```

---

## Внутреннее устройство

### Как работает HTTP/SSE

В отличие от Go (net/http) и Swift (URLSession), C-версия не использует libcurl как библиотеку. Вместо этого JSON-тело запроса записывается во временный файл (`mkstemp`), затем вызывается системный `curl` через `popen()`:

```c
// Упрощённо:
char cmd[4096];
snprintf(cmd, sizeof(cmd),
    "curl -s -N --no-buffer "
    "-H 'Content-Type: application/json' "
    "-H 'Authorization: Bearer %s' "
    "-H 'Accept: text/event-stream' "
    "--data @%s '%s'",
    api_key, tmpfile, url);
FILE *pipe = popen(cmd, "r");
// читаем SSE построчно из pipe
```

Это убирает зависимость от dev-заголовков libcurl при сохранении всей функциональности.

### Потоки в RPC-режиме

RPC-режим использует pthreads:
- Главный поток читает команды из stdin
- Стриминг ответа запускается в отдельном worker-потоке
- Состояние сессии защищено `pthread_mutex_t`
- Отмена через `volatile int abort_flag`

### Структура кода

| Файл | Назначение |
|---|---|
| `src/main.c` | Точка входа, разводка по режимам |
| `src/args.c` | Парсинг CLI аргументов |
| `src/config.c` | Загрузка models.json, реестр моделей |
| `src/openai.c` | SSE-стриминг через curl + все типы данных |
| `src/agent.c` | Агентский цикл (tool use → execute → repeat) |
| `src/tools.c` | Реализация 7 инструментов |
| `src/rpc.c` | RPC-сервер на pthreads |
| `src/systemprompt.c` | Системный промпт с датой и cwd |
| `src/logger.c` | JSONL-лог сессий |
| `src/output.c` | Вывод в text/json режимах |
| `src/util.c` | Утилиты: строки, UUID, tmpfile, mkdirp |

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
