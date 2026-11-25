import ACP
import AgentGateway
import Foundation

/// Default execution configuration for ACP sessions. Values can be overridden
/// per session through the spec's `_meta` extension point of `session/new`,
/// under the gateway's extension key (`GatewayACPMetaKey`).
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
    guard let overrides = gatewayACPMeta(meta)?.objectValue else { return self }
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
///
/// The agent speaks both ACP protocol versions: it conforms to `ACPAgent`
/// (v1, in this file) and `ACPV2Agent` (v2, in `GatewayACPAgent+V2.swift`)
/// over one shared session table, so `ACPAgentServer(v1:v2:transport:)`
/// can serve either version from the same instance. One instance serves
/// one connection.
public actor GatewayACPAgent: ACPAgent {
  let executor: any GatewayExecuting
  let defaults: GatewayAgentDefaults
  var sessions: [String: GatewaySession] = [:]
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

  // MARK: - Shared session logic

  /// Validates and stores a new session; shared by both protocol versions.
  func createSession(
    cwd: String, meta: ACPJSONValue?, systemPrompt: ACPSystemPrompt?,
    mcpServers: [GatewayMCPServer] = [], requiresMCPSupport: Bool = false,
    connection: ACPAgentSideConnection?
  ) async throws -> GatewaySession {
    guard cwd.hasPrefix("/") else {
      throw ACPError.invalidParams("cwd must be an absolute path")
    }
    let configuration = defaults.merging(meta: meta)
    guard configuration.vendor != nil else {
      throw ACPError.invalidParams(
        "no vendor configured; start the agent with --vendor or pass _meta.agentGateway.vendor"
      )
    }
    guard configuration.model != nil else {
      throw ACPError.invalidParams(
        "no model configured; start the agent with --model or pass _meta.agentGateway.model"
      )
    }
    if requiresMCPSupport, !mcpServers.isEmpty, configuration.vendor?.connectsToMCPServers != true {
      throw ACPError.invalidParams(
        "vendor '\(configuration.vendor?.rawValue ?? "")' cannot connect to client-provided MCP servers"
      )
    }
    let clientSystemPrompt = try gatewaySystemPromptText(systemPrompt)
    var session = GatewaySession(
      sessionId: "sess-" + UUID().uuidString.lowercased(),
      cwd: cwd,
      configuration: configuration,
      clientSystemPrompt: clientSystemPrompt,
      vendorSessionId: gatewayACPMeta(meta)?["vendorSessionId"]?.stringValue,
      updatedAt: Date()
    )
    session.connection = connection
    session.mcpServers = mcpServers
    session.availableModels = await availableModels(for: configuration)
    sessions[session.sessionId] = session
    return session
  }

  /// The session when it is active on the connection; otherwise the
  /// `-32002` error that names it.
  func activeSession(_ sessionId: ACPSessionID) throws -> GatewaySession {
    guard let session = sessions[sessionId], session.isActive else {
      throw ACPError.sessionNotFound(sessionId)
    }
    return session
  }

  /// Reattaches a stored session to the connection; shared by v1
  /// `session/load`/`session/resume` and v2 `session/resume`.
  func reactivateSession(
    _ sessionId: ACPSessionID, cwd: String, systemPrompt: ACPSystemPrompt?,
    mcpServers: [GatewayMCPServer] = [], requiresMCPSupport: Bool = false,
    connection: ACPAgentSideConnection?
  ) throws -> GatewaySession {
    guard var session = sessions[sessionId] else {
      throw ACPError.sessionNotFound(sessionId)
    }
    guard cwd.hasPrefix("/") else {
      throw ACPError.invalidParams("cwd must be an absolute path")
    }
    guard gatewayNormalizedPath(cwd) == gatewayNormalizedPath(session.cwd) else {
      throw ACPError.invalidParams("cwd does not match the session's working directory")
    }
    if requiresMCPSupport, !mcpServers.isEmpty, session.configuration.vendor?.connectsToMCPServers != true {
      throw ACPError.invalidParams(
        "vendor '\(session.configuration.vendor?.rawValue ?? "")' cannot connect to client-provided MCP servers"
      )
    }
    if let text = try gatewaySystemPromptText(systemPrompt) {
      session.clientSystemPrompt = text
    }
    // The request's servers are the complete set: earlier ones are not restored.
    session.mcpServers = mcpServers
    session.isActive = true
    session.isClosing = false
    session.connection = connection
    sessions[sessionId] = session
    return session
  }

  func sessionList(_ request: ACPListSessionsRequest) throws -> ACPListSessionsResponse {
    if let cwd = request.cwd, !cwd.hasPrefix("/") {
      throw ACPError.invalidParams("cwd must be an absolute path")
    }
    var offset = 0
    if let cursor = request.cursor {
      guard let decoded = gatewaySessionListOffset(cursor) else {
        throw ACPError.invalidParams("invalid session/list cursor")
      }
      offset = decoded
    }
    let filter = request.cwd.map(gatewayNormalizedPath)
    let matching = sessions.values
      .filter { filter == nil || gatewayNormalizedPath($0.cwd) == filter }
      .sorted { ($0.updatedAt, $0.sessionId) > ($1.updatedAt, $1.sessionId) }
    guard offset <= matching.count else {
      throw ACPError.invalidParams("invalid session/list cursor")
    }
    let page = matching.dropFirst(offset).prefix(gatewaySessionListPageSize)
    let next = offset + page.count
    return ACPListSessionsResponse(
      sessions: page.map(\.info),
      nextCursor: next < matching.count ? gatewaySessionListCursor(next) : nil
    )
  }

  /// Applies `session/set_config_option`; returns the complete option list.
  func applyConfigOption(_ request: ACPSetSessionConfigOptionRequest) throws -> [ACPSessionConfigOption] {
    var session = try activeSession(request.sessionId)
    let options = session.configOptions
    guard let option = options.first(where: { $0.configId == request.configId }),
          case .select(_, let choices) = option.kind else {
      throw ACPError.invalidParams("unknown config option '\(request.configId)'")
    }
    guard case .id(let value) = request.value else {
      throw ACPError.invalidParams("config option '\(request.configId)' takes an option id")
    }
    guard choices.all.contains(where: { $0.value == value }) else {
      throw ACPError.invalidParams("unknown value '\(value)' for config option '\(request.configId)'")
    }
    session.configuration.model = value
    sessions[request.sessionId] = session
    return session.configOptions
  }

  /// Best-effort model advertisement for `session/new`. Only vendors with
  /// a listing endpoint participate; failures and slow responses (over 3
  /// seconds) degrade to no advertisement instead of failing or stalling
  /// session creation. Successful lists are cached per
  /// vendor/baseURL/credential.
  private func availableModels(for configuration: GatewayAgentDefaults) async -> [ACPModelInfo] {
    guard let vendor = configuration.vendor, !vendor.isCLI, configuration.model != nil,
          let listing = executor as? any GatewayModelListing else { return [] }
    let cacheKey = [
      vendor.rawValue, configuration.baseURL ?? "", configuration.apiKeyEnvironment ?? ""
    ].joined(separator: "|")
    if let cached = modelListCache[cacheKey] {
      return cached
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
    guard let result, !result.models.isEmpty else { return [] }
    let models = result.models.map {
      ACPModelInfo(modelId: $0.modelId, name: $0.name ?? $0.modelId, description: $0.description)
    }
    modelListCache[cacheKey] = models
    return models
  }

  func executeParams(for session: GatewaySession, input: GatewayPromptInput) throws -> GatewayExecuteParams {
    let configuration = session.configuration
    guard let vendor = configuration.vendor, let model = configuration.model else {
      throw ACPError.invalidParams("session has no vendor/model configuration")
    }
    return GatewayExecuteParams(
      vendor: vendor,
      model: model,
      prompt: input.text,
      systemPrompt: session.effectiveSystemPrompt,
      workingDirectory: session.cwd,
      executable: configuration.executable,
      arguments: configuration.arguments + gatewayMCPArguments(vendor: vendor, servers: session.mcpServers),
      providerName: configuration.providerName,
      apiKeyEnvironment: configuration.apiKeyEnvironment,
      baseURL: configuration.baseURL,
      maxTokens: configuration.maxTokens,
      sessionMode: session.vendorSessionId == nil ? .new : .reuse,
      sessionId: session.vendorSessionId,
      cursorAPI: configuration.cursorAPI,
      images: input.images
    )
  }

  func sessionMeta(_ session: GatewaySession, key: String) -> ACPJSONValue {
    .object([
      key: .object([
        "vendor": .string(session.configuration.vendor?.rawValue ?? ""),
        "model": .string(session.configuration.model ?? "")
      ])
    ])
  }

  // MARK: - ACP v1

  public func initialize(_ request: ACPInitializeRequest) async throws -> ACPInitializeResponse {
    ACPInitializeResponse(
      protocolVersion: min(request.protocolVersion, ACPProtocol.versionV1),
      agentCapabilities: ACPAgentCapabilities(
        loadSession: true,
        promptCapabilities: ACPPromptCapabilities(image: true, audio: false, embeddedContext: true),
        sessionCapabilities: ACPSessionCapabilities(
          list: ACPSupportMarker(),
          resume: ACPSupportMarker(),
          close: ACPSupportMarker(),
          delete: ACPSupportMarker(),
          systemPrompt: ACPSystemPromptCapabilities()
        )
      ),
      agentInfo: ACPImplementation(name: "agent-gateway", version: Version.current, title: "Agent Gateway")
    )
  }

  public func newSession(
    _ request: ACPNewSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPNewSessionResponse {
    // v1 has no way to decline stdio servers, so vendors that cannot
    // connect to them still accept the session and leave them unused.
    let session = try await createSession(
      cwd: request.cwd, meta: request.meta, systemPrompt: request.systemPrompt,
      mcpServers: try gatewayMCPServers(v1: request.mcpServers), connection: nil
    )
    return ACPNewSessionResponse(
      sessionId: session.sessionId,
      // Models are advertised as the standard `model` config option. The
      // former root-level `models` field is not part of the v1 schema.
      configOptions: v1ConfigOptions(session),
      meta: sessionMeta(session, key: GatewayACPMetaKey.v1)
    )
  }

  private func v1ConfigOptions(_ session: GatewaySession) -> [ACPSessionConfigOption.V1Coding]? {
    let options = session.configOptions
    return options.isEmpty ? nil : options.map(ACPSessionConfigOption.V1Coding.init)
  }

  /// `session/load`: reattaches the session and replays its retained
  /// history as message chunks before responding.
  public func loadSession(
    _ request: ACPLoadSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPLoadSessionResponse {
    let session = try reactivateSession(
      request.sessionId, cwd: request.cwd, systemPrompt: request.systemPrompt,
      mcpServers: try gatewayMCPServers(v1: request.mcpServers), connection: nil
    )
    for message in session.history {
      for block in message.content {
        let update: ACPSessionUpdate
        switch message.role {
        case .user: update = .userMessageChunk(block)
        case .agent: update = .agentMessageChunk(block)
        case .thought: update = .agentThoughtChunk(block)
        }
        await connection.sendUpdate(ACPSessionNotification(sessionId: session.sessionId, update: update))
      }
    }
    return ACPLoadSessionResponse(configOptions: v1ConfigOptions(session))
  }

  /// `session/resume`: reattaches the session without replaying history.
  public func resumeSession(
    _ request: ACPLoadSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPLoadSessionResponse {
    let session = try reactivateSession(
      request.sessionId, cwd: request.cwd, systemPrompt: request.systemPrompt,
      mcpServers: try gatewayMCPServers(v1: request.mcpServers), connection: nil
    )
    return ACPLoadSessionResponse(configOptions: v1ConfigOptions(session))
  }

  public func listSessions(_ request: ACPListSessionsRequest) async throws -> ACPListSessionsResponse {
    try sessionList(request)
  }

  /// `session/close`: cancels an in-flight prompt and ends the session on
  /// the connection. Idempotent: unknown and closed sessions succeed.
  public func closeSession(_ request: ACPSessionRequest) async throws {
    guard sessions[request.sessionId] != nil else { return }
    sessions[request.sessionId]?.cancelRequested = true
    sessions[request.sessionId]?.activeTask?.cancel()
    sessions[request.sessionId]?.isActive = false
  }

  public func deleteSession(_ request: ACPSessionRequest) async throws {
    try await closeSession(request)
    sessions[request.sessionId] = nil
  }

  public func setConfigOption(
    _ request: ACPSetSessionConfigOptionRequest
  ) async throws -> ACPSetSessionConfigOptionResponse.V1Coding {
    ACPSetSessionConfigOptionResponse(configOptions: try applyConfigOption(request)).v1
  }

  public func setModel(_ request: ACPSetSessionModelRequest) async throws {
    _ = try activeSession(request.sessionId)
    guard !request.modelId.isEmpty else {
      throw ACPError.invalidParams("modelId must not be empty")
    }
    // Model ids are pass-through vendor strings, so ids outside the
    // advertised list are accepted; the vendor validates at prompt time.
    sessions[request.sessionId]?.configuration.model = request.modelId
  }

  public func prompt(
    _ request: ACPPromptRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPPromptResponse {
    let session = try activeSession(request.sessionId)
    guard session.activeTask == nil else {
      throw ACPError.invalidRequest("session '\(request.sessionId)' already has a prompt in flight")
    }
    let params = try executeParams(for: session, input: try gatewayPromptInput(request.prompt))
    sessions[request.sessionId]?.cancelRequested = false
    sessions[request.sessionId]?.retain(
      GatewayHistoryMessage(role: .user, messageId: gatewayNewMessageId(), content: request.prompt)
    )
    sessions[request.sessionId]?.turnCount += 1
    let scope = gatewayActivityScope(turn: session.turnCount + 1)
    let priorCostUSD = session.costUSD

    // Chunks are pumped through an AsyncStream so the synchronous vendor
    // emitter preserves token order while they are sent sequentially.
    let (stream, continuation) = AsyncStream.makeStream(of: GatewayStreamChunk.self)
    let pump = Task { () -> GatewayStreamedOutput in
      var message = ""
      var thought = ""
      var costUSD: Double?
      for await chunk in stream {
        let update: ACPSessionUpdate
        switch chunk {
        case .message(let text):
          message += text
          update = .agentMessageChunk(.text(text))
        case .thought(let text):
          thought += text
          update = .agentThoughtChunk(.text(text))
        case .toolCall(let toolCall):
          update = toolCall.v1Update
        case .plan(let plan):
          update = .plan(plan.entries)
        case .usage(let usage):
          costUSD = usage.costUSD ?? costUSD
          // Reported once the vendor has said how large the context window is.
          guard let usageUpdate = usage.v1Update(priorCostUSD: priorCostUSD) else { continue }
          update = usageUpdate
        }
        await connection.sendUpdate(ACPSessionNotification(sessionId: request.sessionId, update: update))
      }
      return GatewayStreamedOutput(message: message, thought: thought, costUSD: costUSD)
    }
    let bridge = GatewayACPStreamBridge(scope: scope) { continuation.yield($0) }
    let executor = executor
    let task = Task { try await executor.execute(params, emit: bridge.emitter) }
    sessions[request.sessionId]?.activeTask = task
    defer { sessions[request.sessionId]?.activeTask = nil }
    // A cancel notification can land between the task launch and the
    // activeTask assignment above; honor it instead of losing it.
    if sessions[request.sessionId]?.cancelRequested == true {
      task.cancel()
    }

    let outcome: Result<GatewayExecuteResult, any Error>
    do {
      // `$/cancel_request` for this prompt cancels the calling task; treat
      // it like session/cancel so the turn still ends with one response.
      outcome = .success(try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      })
    } catch {
      outcome = .failure(error)
    }
    // However the turn ended, no tool call is left looking like it is
    // still running: the vendor execution is over.
    switch outcome {
    case .success: bridge.settleOpenToolCalls(.completed)
    case .failure: bridge.settleOpenToolCalls(.failed)
    }
    continuation.finish()
    let streamed = await pump.value
    sessions[request.sessionId]?.costUSD += streamed.costUSD ?? 0
    retainOutput(sessionId: request.sessionId, thought: streamed.thought, message: streamed.message)
    switch outcome {
    case .success(let result):
      if let vendorSessionId = result.sessionId {
        sessions[request.sessionId]?.vendorSessionId = vendorSessionId
      }
      return ACPPromptResponse(stopReason: .endTurn, meta: gatewayResultMeta(result, key: GatewayACPMetaKey.v1))
    case .failure(let error):
      if sessions[request.sessionId]?.cancelRequested == true || error is CancellationError || Task.isCancelled {
        return ACPPromptResponse(stopReason: .cancelled)
      }
      throw gatewayACPError(error)
    }
  }

  /// Retains the output of a finished turn for history replay.
  func retainOutput(
    sessionId: ACPSessionID, thought: String, message: String,
    thoughtMessageId: ACPMessageID = gatewayNewMessageId(), agentMessageId: ACPMessageID = gatewayNewMessageId()
  ) {
    if !thought.isEmpty {
      sessions[sessionId]?.retain(
        GatewayHistoryMessage(role: .thought, messageId: thoughtMessageId, content: [.text(thought)])
      )
    }
    if !message.isEmpty {
      sessions[sessionId]?.retain(
        GatewayHistoryMessage(role: .agent, messageId: agentMessageId, content: [.text(message)])
      )
    }
  }

  public func cancel(_ notification: ACPCancelNotification) async {
    sessions[notification.sessionId]?.cancelRequested = true
    sessions[notification.sessionId]?.activeTask?.cancel()
  }
}

/// Opaque `session/list` cursor for a result offset.
func gatewaySessionListCursor(_ offset: Int) -> String {
  Data("offset:\(offset)".utf8).base64EncodedString()
}

/// The offset a cursor issued by `gatewaySessionListCursor` names, or nil
/// for anything else.
func gatewaySessionListOffset(_ cursor: String) -> Int? {
  guard let data = Data(base64Encoded: cursor),
        let text = String(data: data, encoding: .utf8),
        text.hasPrefix("offset:"),
        let offset = Int(text.dropFirst("offset:".count)), offset > 0 else { return nil }
  return offset
}
