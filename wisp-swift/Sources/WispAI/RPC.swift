import Foundation

// MARK: - Protocol types

public struct RpcCommand: Decodable {
    public let type: String
    public let id: String?
    public let message: String?
    public let provider: String?
    public let modelId: String?
    public let systemPrompt: String?
}

public struct RpcResponse: Encodable {
    public let id: String?
    public let type: String
    public let command: String
    public let success: Bool
    public let data: AnyEncodable?
    public let error: String?

    public init(id: String?, command: String, data: (any Encodable)? = nil, error: String? = nil) {
        self.id = id
        self.type = "response"
        self.command = command
        self.success = error == nil
        self.data = data.map(AnyEncodable.init)
        self.error = error
    }
}

public struct RpcSessionState: Encodable {
    public let model: Model
    public let isStreaming: Bool
    public let sessionId: String
    public let messageCount: Int
}

struct RpcEvent: Encodable {
    let type: EventType
    let index: Int?
    let delta: String?
    let content: String?
    let part: ContentPart?
    let message: AssistantMessage?

    init(from e: AssistantMessageEvent) {
        type = e.type
        index = e.index != 0 ? e.index : nil
        delta = e.delta.isEmpty ? nil : e.delta
        content = e.content.isEmpty ? nil : e.content
        part = e.part
        message = e.message
    }
}

// MARK: - Type-erased encodable

public struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    public init(_ value: any Encodable) { _encode = { try value.encode(to: $0) } }
    public func encode(to encoder: Encoder) throws { try _encode(encoder) }
}

// MARK: - Session actor

actor RPCSession {
    var messages: [ContextMessage] = []
    var systemPrompt: String
    var model: Model
    var options: StreamOptions
    var tools: [Tool]
    var handler: ToolHandler?
    var isStreaming: Bool = false
    var streamTask: Task<Void, Never>?
    var id: String
    let config: Config

    init(config: Config, model: Model, options: StreamOptions, tools: [Tool],
         handler: ToolHandler?, systemPrompt: String) {
        self.config = config; self.model = model; self.options = options
        self.tools = tools; self.handler = handler; self.systemPrompt = systemPrompt
        self.id = UUID().uuidString
    }

    func abort() { streamTask?.cancel(); streamTask = nil; isStreaming = false }

    func newSession() {
        abort(); messages = []; systemPrompt = ""; id = UUID().uuidString
    }

    func startStreaming(task: Task<Void, Never>) {
        streamTask = task; isStreaming = true
    }

    func finishStreaming() { streamTask = nil; isStreaming = false }

    func appendMessages(_ msgs: [ContextMessage]) { messages.append(contentsOf: msgs) }

    func setModel(_ m: Model, opts: StreamOptions) { model = m; options = opts }

    func setSystemPrompt(_ s: String) { systemPrompt = s }

    func snapshot() -> (model: Model, options: StreamOptions, systemPrompt: String,
                        messages: [ContextMessage], tools: [Tool], handler: ToolHandler?,
                        isStreaming: Bool, id: String) {
        (model, options, systemPrompt, messages, tools, handler, isStreaming, self.id)
    }
}

// MARK: - Output writer actor

actor OutputWriter {
    func write(_ data: Data) {
        var buf = data
        buf.append(contentsOf: [UInt8(ascii: "\n")])
        FileHandle.standardOutput.write(buf)
    }

    func writeEncodable(_ value: some Encodable) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        write(data)
    }
}

// MARK: - RPC server

public func runRPC(
    config: Config,
    model: Model,
    options: StreamOptions,
    tools: [Tool],
    handler: ToolHandler?,
    initialSystemPrompt: String
) async {
    let session = RPCSession(config: config, model: model, options: options,
                             tools: tools, handler: handler, systemPrompt: initialSystemPrompt)
    let out = OutputWriter()

    func respond(id: String?, command: String, data: (any Encodable)? = nil, error: String? = nil) async {
        await out.writeEncodable(RpcResponse(id: id, command: command, data: data, error: error))
    }

    do {
        for try await line in FileHandle.standardInput.bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let cmd = try? JSONDecoder().decode(RpcCommand.self, from: Data(trimmed.utf8))
            else { continue }

            switch cmd.type {

            case "prompt", "follow_up":
                let snap = await session.snapshot()
                if snap.isStreaming {
                    await respond(id: cmd.id, command: cmd.type, error: "already streaming; send abort first")
                    continue
                }
                let userMsg = ContextMessage.user(cmd.message ?? "")
                await session.appendMessages([userMsg])
                let snap2 = await session.snapshot()
                let ctx = Context(systemPrompt: snap2.systemPrompt, messages: snap2.messages, tools: snap2.tools)
                let resolvedOpts = snap2.options

                await respond(id: cmd.id, command: cmd.type)

                let task = Task {
                    defer { Task { await session.finishStreaming() } }

                    let agentOpts = AgentOptions(onStep: { added in
                        Task { await session.appendMessages(added) }
                    })

                    let noopHandler: ToolHandler = { _, name, _ in "error: no handler for tool \(name)" }
                    let h = snap2.handler ?? noopHandler

                    for try await event in runAgent(config: snap2.config, model: snap2.model,
                                                    context: ctx, options: resolvedOpts,
                                                    handler: h, agentOptions: agentOpts) {
                        await out.writeEncodable(RpcEvent(from: event))
                        if event.type == .done, let msg = event.message {
                            let lastRole = await session.snapshot().messages.last?.role
                            if lastRole != "assistant" {
                                await session.appendMessages([.assistant(msg)])
                            }
                        }
                    }
                }
                await session.startStreaming(task: task)

            case "abort":
                await session.abort()
                await respond(id: cmd.id, command: "abort")

            case "new_session":
                await session.newSession()
                await respond(id: cmd.id, command: "new_session")

            case "get_state":
                let snap = await session.snapshot()
                let state = RpcSessionState(model: snap.model, isStreaming: snap.isStreaming,
                                            sessionId: snap.id, messageCount: snap.messages.count)
                await respond(id: cmd.id, command: "get_state", data: state)

            case "get_messages":
                let msgs = await session.snapshot().messages
                await respond(id: cmd.id, command: "get_messages", data: ["messages": msgs])

            case "set_model":
                let registry = config.registry
                let pid = cmd.provider ?? ""
                let mid = cmd.modelId ?? ""
                let found = registry.find(provider: pid, id: mid) ?? registry.findByID(mid)
                if let m = found {
                    let newOpts = config.resolve(nil, for: m)
                    await session.setModel(m, opts: newOpts)
                    await respond(id: cmd.id, command: "set_model", data: m)
                } else {
                    await respond(id: cmd.id, command: "set_model", error: "model \"\(mid)\" not found")
                }

            case "get_available_models":
                let models = config.registry.all()
                await respond(id: cmd.id, command: "get_available_models", data: ["models": models])

            case "set_system_prompt":
                await session.setSystemPrompt(cmd.systemPrompt ?? "")
                await respond(id: cmd.id, command: "set_system_prompt")

            default:
                await respond(id: cmd.id, command: cmd.type, error: "unknown command: \(cmd.type)")
            }
        }
    } catch {
        // stdin closed or error — exit cleanly
    }
}
