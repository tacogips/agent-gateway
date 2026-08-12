import ACP
import AgentGateway
import Foundation

/// Default execution configuration for ACP sessions. Values can be overridden
/// per session through the spec's `meta` extension point under the
/// `agentGateway` key of `session/new`.
public struct GatewayAgentDefaults: Equatable, Sendable {
  public var vendor: GatewayVendor?
  public var model: String?
  public var systemPrompt: String?
  public var executable: String?
  public var arguments: [String]
  public var providerName: String?
  public var apiKeyEnvironment: String?
  public var baseURL: String?
  public var maxTokens: Int?
  public var cursorAPI: GatewayCursorAPIOptions?

  public init(
    vendor: GatewayVendor? = nil,
    model: String? = nil,
    systemPrompt: String? = nil,
    executable: String? = nil,
    arguments: [String] = [],
    providerName: String? = nil,
    apiKeyEnvironment: String? = nil,
    baseURL: String? = nil,
    maxTokens: Int? = nil,
    cursorAPI: GatewayCursorAPIOptions? = nil
  ) {
    self.vendor = vendor
    self.model = model
    self.systemPrompt = systemPrompt
    self.executable = executable
    self.arguments = arguments
    self.providerName = providerName
    self.apiKeyEnvironment = apiKeyEnvironment
    self.baseURL = baseURL
    self.maxTokens = maxTokens
    self.cursorAPI = cursorAPI
  }

  func merging(meta: ACPJSONValue?) -> GatewayAgentDefaults {
    guard let overrides = meta?["agentGateway"]?.objectValue else { return self }
    var merged = self
    if let value = overrides["vendor"]?.stringValue {
      merged.vendor = GatewayVendor(rawValue: value)
    }
    merged.model = overrides["model"]?.stringValue ?? merged.model
    merged.systemPrompt = overrides["systemPrompt"]?.stringValue ?? merged.systemPrompt
    merged.executable = overrides["executable"]?.stringValue ?? merged.executable
    if case .array(let values)? = overrides["arguments"] {
      merged.arguments = values.compactMap(\.stringValue)
    }
    merged.providerName = overrides["providerName"]?.stringValue ?? merged.providerName
    merged.apiKeyEnvironment = overrides["apiKeyEnvironment"]?.stringValue ?? merged.apiKeyEnvironment
    merged.baseURL = overrides["baseURL"]?.stringValue ?? merged.baseURL
    merged.maxTokens = overrides["maxTokens"]?.integerValue ?? merged.maxTokens
    return merged
  }
}

/// ACP-compliant agent that routes prompt turns to AI vendor backends
/// (CLI agents and HTTP APIs) through `GatewayExecuting`.
public actor GatewayACPAgent: ACPAgent {
  private struct SessionState {
    var cwd: String
    var configuration: GatewayAgentDefaults
    var vendorSessionId: String?
    var activeTask: Task<GatewayExecuteResult, any Error>?
    var cancelRequested = false
  }

  private let executor: any GatewayExecuting
  private let defaults: GatewayAgentDefaults
  private var sessions: [String: SessionState] = [:]
  /// Vendor model lists fetched for `session/new`, keyed by
  /// vendor/baseURL/credential so repeated sessions skip the network.
  private var modelListCache: [String: [ACPModelInfo]] = [:]

  public init(
    defaults: GatewayAgentDefaults = GatewayAgentDefaults(),
    executor: any GatewayExecuting = ProductionGatewayExecutor()
  ) {
    self.defaults = defaults
    self.executor = executor
  }

  public func initialize(_ request: ACPInitializeRequest) async throws -> ACPInitializeResponse {
    ACPInitializeResponse(
      protocolVersion: min(request.protocolVersion, ACPProtocol.versionV1),
      agentCapabilities: ACPAgentCapabilities(
        loadSession: false,
        promptCapabilities: ACPPromptCapabilities(image: true, audio: false, embeddedContext: true)
      ),
      agentInfo: ACPImplementation(name: "agent-gateway", version: Version.current)
    )
  }

  public func newSession(
    _ request: ACPNewSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPNewSessionResponse {
    guard request.cwd.hasPrefix("/") else {
      throw ACPError.invalidParams("cwd must be an absolute path")
    }
    let configuration = defaults.merging(meta: request.meta)
    guard let vendor = configuration.vendor else {
      throw ACPError.invalidParams(
        "no vendor configured; start the agent with --vendor or pass _meta.agentGateway.vendor"
      )
    }
    guard configuration.model != nil else {
      throw ACPError.invalidParams(
        "no model configured; start the agent with --model or pass _meta.agentGateway.model"
      )
    }
    let sessionId = "sess-" + UUID().uuidString.lowercased()
    sessions[sessionId] = SessionState(
      cwd: request.cwd,
      configuration: configuration,
      vendorSessionId: request.meta?["agentGateway"]?["vendorSessionId"]?.stringValue
    )
    return ACPNewSessionResponse(
      sessionId: sessionId,
      models: await sessionModels(for: configuration),
      meta: .object([
        "agentGateway": .object([
          "vendor": .string(vendor.rawValue),
          "model": .string(configuration.model ?? "")
        ])
      ])
    )
  }

  public func setModel(_ request: ACPSetSessionModelRequest) async throws {
    guard sessions[request.sessionId] != nil else {
      throw ACPError.invalidParams("unknown session '\(request.sessionId)'")
    }
    guard !request.modelId.isEmpty else {
      throw ACPError.invalidParams("modelId must not be empty")
    }
    // Model ids are pass-through vendor strings, so ids outside the
    // advertised list are accepted; the vendor validates at prompt time.
    sessions[request.sessionId]?.configuration.model = request.modelId
  }

  /// Best-effort ACP model advertisement for `session/new`. Only vendors
  /// with a listing endpoint participate; failures and slow responses
  /// (over 3 seconds) degrade to no advertisement instead of failing or
  /// stalling session creation. Successful lists are cached per
  /// vendor/baseURL/credential.
  private func sessionModels(for configuration: GatewayAgentDefaults) async -> ACPSessionModelState? {
    guard let vendor = configuration.vendor, !vendor.isCLI,
          let currentModel = configuration.model,
          let listing = executor as? any GatewayModelListing else { return nil }
    let cacheKey = [
      vendor.rawValue, configuration.baseURL ?? "", configuration.apiKeyEnvironment ?? ""
    ].joined(separator: "|")
    if let cached = modelListCache[cacheKey] {
      return ACPSessionModelState(availableModels: cached, currentModelId: currentModel)
    }
    let params = GatewayModelCatalogParams(
      vendor: vendor,
      apiKeyEnvironment: configuration.apiKeyEnvironment,
      baseURL: configuration.baseURL
    )
    let result = await withTaskGroup(of: GatewayModelCatalogResult?.self) { group in
      group.addTask { try? await listing.models(params) }
      group.addTask {
        try? await Task.sleep(for: .seconds(3))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
    guard let result, !result.models.isEmpty else { return nil }
    let models = result.models.map {
      ACPModelInfo(modelId: $0.modelId, name: $0.name ?? $0.modelId, description: $0.description)
    }
    modelListCache[cacheKey] = models
    return ACPSessionModelState(availableModels: models, currentModelId: currentModel)
  }

  public func prompt(
    _ request: ACPPromptRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPPromptResponse {
    guard let session = sessions[request.sessionId] else {
      throw ACPError.invalidParams("unknown session '\(request.sessionId)'")
    }
    guard session.activeTask == nil else {
      throw ACPError.invalidRequest("session '\(request.sessionId)' already has a prompt in flight")
    }
    let params = try executeParams(for: session, prompt: request.prompt)
    sessions[request.sessionId]?.cancelRequested = false

    // Updates are pumped through an AsyncStream so the synchronous vendor
    // emitter preserves token order while the actor sends them sequentially.
    let (stream, continuation) = AsyncStream.makeStream(of: ACPSessionUpdate.self)
    let pump = Task {
      for await update in stream {
        await connection.sendUpdate(ACPSessionNotification(sessionId: request.sessionId, update: update))
      }
    }
    let bridge = GatewayACPStreamBridge { continuation.yield($0) }
    let executor = executor
    let task = Task { try await executor.execute(params, emit: bridge.emitter) }
    sessions[request.sessionId]?.activeTask = task
    defer { sessions[request.sessionId]?.activeTask = nil }
    // A cancel notification can land between the task launch and the
    // activeTask assignment above; honor it instead of losing it.
    if sessions[request.sessionId]?.cancelRequested == true {
      task.cancel()
    }

    do {
      let result = try await task.value
      continuation.finish()
      await pump.value
      if let vendorSessionId = result.sessionId {
        sessions[request.sessionId]?.vendorSessionId = vendorSessionId
      }
      return ACPPromptResponse(stopReason: .endTurn, meta: resultMeta(result))
    } catch {
      continuation.finish()
      await pump.value
      if sessions[request.sessionId]?.cancelRequested == true || error is CancellationError {
        return ACPPromptResponse(stopReason: .cancelled)
      }
      if let gatewayError = error as? GatewayRPCError {
        throw ACPError(code: gatewayError.code, message: gatewayError.message)
      }
      throw ACPError.internalError(String(describing: error))
    }
  }

  public func cancel(_ notification: ACPCancelNotification) async {
    sessions[notification.sessionId]?.cancelRequested = true
    sessions[notification.sessionId]?.activeTask?.cancel()
  }

  private func executeParams(
    for session: SessionState, prompt blocks: [ACPContentBlock]
  ) throws -> GatewayExecuteParams {
    let configuration = session.configuration
    guard let vendor = configuration.vendor, let model = configuration.model else {
      throw ACPError.invalidParams("session has no vendor/model configuration")
    }
    var textParts: [String] = []
    var images: [GatewayImageInput] = []
    for block in blocks {
      switch block {
      case .text(let content):
        textParts.append(content.text)
      case .image(let content):
        images.append(GatewayImageInput(dataBase64: content.data, mimeType: content.mimeType))
      case .resourceLink(let link):
        textParts.append(link.uri)
      case .resource(let embedded):
        if let text = embedded.resource.text {
          textParts.append(text)
        } else {
          throw ACPError.invalidParams("binary embedded resources are not supported")
        }
      case .audio:
        throw ACPError.invalidParams("audio content is not supported")
      }
    }
    guard !textParts.isEmpty || !images.isEmpty else {
      throw ACPError.invalidParams("prompt must contain at least one supported content block")
    }
    return GatewayExecuteParams(
      vendor: vendor,
      model: model,
      prompt: textParts.joined(separator: "\n\n"),
      systemPrompt: configuration.systemPrompt,
      workingDirectory: session.cwd,
      executable: configuration.executable,
      arguments: configuration.arguments,
      providerName: configuration.providerName,
      apiKeyEnvironment: configuration.apiKeyEnvironment,
      baseURL: configuration.baseURL,
      maxTokens: configuration.maxTokens,
      sessionMode: session.vendorSessionId == nil ? .new : .reuse,
      sessionId: session.vendorSessionId,
      cursorAPI: configuration.cursorAPI,
      images: images
    )
  }

  private func resultMeta(_ result: GatewayExecuteResult) -> ACPJSONValue {
    var gateway: [String: ACPJSONValue] = [
      "vendor": .string(result.vendor.rawValue),
      "model": .string(result.model),
      // The vendor's authoritative final text. Streamed chunks may span
      // multiple assistant messages; hosts that need exactly the vendor's
      // final result (e.g. for output contracts) should prefer this value.
      "resultText": .string(result.text)
    ]
    if let sessionId = result.sessionId {
      gateway["vendorSessionId"] = .string(sessionId)
    }
    if let usage = result.usage {
      var tokens: [String: ACPJSONValue] = [:]
      if let input = usage.inputTokens { tokens["inputTokens"] = .integer(input) }
      if let output = usage.outputTokens { tokens["outputTokens"] = .integer(output) }
      if let total = usage.totalTokens { tokens["totalTokens"] = .integer(total) }
      gateway["usage"] = .object(tokens)
    }
    return .object(["agentGateway": .object(gateway)])
  }
}

/// Converts gateway emitter callbacks into ordered ACP session updates.
///
/// Streaming vendors produce token deltas that map 1:1 to
/// `agent_message_chunk`. Non-streaming vendors produce whole-message
/// snapshots; those are de-duplicated so a final echo of already-streamed
/// text (e.g. Claude Code's `result` event or cursor-agent's `result`
/// after deltas) is not emitted twice.
final class GatewayACPStreamBridge: @unchecked Sendable {
  private let lock = NSLock()
  private let yield: @Sendable (ACPSessionUpdate) -> Void
  private var accumulated = ""

  init(yield: @escaping @Sendable (ACPSessionUpdate) -> Void) {
    self.yield = yield
  }

  var emitter: GatewayEventEmitter {
    { [self] event in consume(event) }
  }

  func consume(_ event: GatewayEvent) {
    lock.withLock {
      switch event.channel {
      case .assistant:
        if let delta = event.textDelta, !delta.isEmpty {
          accumulated += delta
          yield(.agentMessageChunk(.text(delta)))
        } else if let snapshot = event.textSnapshot, !snapshot.isEmpty {
          guard !accumulated.hasSuffix(snapshot) else { return }
          if snapshot.hasPrefix(accumulated), !accumulated.isEmpty {
            let suffix = String(snapshot.dropFirst(accumulated.count))
            accumulated = snapshot
            if !suffix.isEmpty { yield(.agentMessageChunk(.text(suffix))) }
          } else {
            accumulated += snapshot
            yield(.agentMessageChunk(.text(snapshot)))
          }
        }
      case .thinking:
        if let text = event.textDelta ?? event.textSnapshot, !text.isEmpty {
          yield(.agentThoughtChunk(.text(text)))
        }
      case .lifecycle, .tool, .usage, .vendor:
        break
      }
    }
  }
}
