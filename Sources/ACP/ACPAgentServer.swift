import Foundation

/// Implemented by ACP protocol version 1 agents (the process that answers
/// `initialize`, `session/new`, and `session/prompt`).
///
/// In v1 a `session/prompt` request stays pending for the whole turn and
/// its response carries the stop reason. Agents that also speak v2
/// implement `ACPV2Agent` next to this protocol; `ACPAgentServer` selects
/// one of them per connection during `initialize`.
public protocol ACPAgent: Sendable {
  func initialize(_ request: ACPInitializeRequest) async throws -> ACPInitializeResponse
  func newSession(
    _ request: ACPNewSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPNewSessionResponse
  func prompt(
    _ request: ACPPromptRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPPromptResponse
  func cancel(_ notification: ACPCancelNotification) async
  func authenticate(methodId: String) async throws
  /// Switches the session's model. Only reachable for agents that advertise
  /// models in `session/new`; the default rejects the request.
  func setModel(_ request: ACPSetSessionModelRequest) async throws
  /// `session/load`: restores a session and replays its history. Requires
  /// `agentCapabilities.loadSession`; the default rejects the request.
  func loadSession(
    _ request: ACPLoadSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPLoadSessionResponse
  /// `session/resume`: restores a session without replay. Requires
  /// `sessionCapabilities.resume`; the default rejects the request.
  func resumeSession(
    _ request: ACPLoadSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPLoadSessionResponse
  /// `session/list`. Requires `sessionCapabilities.list`.
  func listSessions(_ request: ACPListSessionsRequest) async throws -> ACPListSessionsResponse
  /// `session/close`. Requires `sessionCapabilities.close`.
  func closeSession(_ request: ACPSessionRequest) async throws
  /// `session/delete`. Requires `sessionCapabilities.delete`.
  func deleteSession(_ request: ACPSessionRequest) async throws
  /// `session/set_config_option`. Required when sessions advertise config options.
  func setConfigOption(
    _ request: ACPSetSessionConfigOptionRequest
  ) async throws -> ACPSetSessionConfigOptionResponse.V1Coding
  /// Any other request, including `_`-prefixed extension methods. `params`
  /// is the raw JSON params fragment; return the encoded JSON result.
  func extensionRequest(method: String, params: Data) async throws -> Data
}

extension ACPAgent {
  public func authenticate(methodId: String) async throws {
    throw ACPError.invalidParams("authentication is not supported")
  }

  public func setModel(_ request: ACPSetSessionModelRequest) async throws {
    throw ACPError.methodNotFound(ACPMethod.sessionSetModel)
  }

  public func loadSession(
    _ request: ACPLoadSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPLoadSessionResponse {
    throw ACPError.methodNotFound(ACPMethod.sessionLoad)
  }

  public func resumeSession(
    _ request: ACPLoadSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPLoadSessionResponse {
    throw ACPError.methodNotFound(ACPMethod.sessionResume)
  }

  public func listSessions(_ request: ACPListSessionsRequest) async throws -> ACPListSessionsResponse {
    throw ACPError.methodNotFound(ACPMethod.sessionList)
  }

  public func closeSession(_ request: ACPSessionRequest) async throws {
    throw ACPError.methodNotFound(ACPMethod.sessionClose)
  }

  public func deleteSession(_ request: ACPSessionRequest) async throws {
    throw ACPError.methodNotFound(ACPMethod.sessionDelete)
  }

  public func setConfigOption(
    _ request: ACPSetSessionConfigOptionRequest
  ) async throws -> ACPSetSessionConfigOptionResponse.V1Coding {
    throw ACPError.methodNotFound(ACPMethod.sessionSetConfigOption)
  }

  public func extensionRequest(method: String, params: Data) async throws -> Data {
    throw ACPError.methodNotFound(method)
  }
}

/// Outcome of submitting a v2 prompt: resolves once the user message is
/// inserted into the conversation (or the prompt is rejected or dropped
/// before insertion). It never waits for the resulting work to finish.
public struct ACPV2PromptSubmission: Sendable {
  let response: @Sendable () async throws -> ACPV2PromptResponse

  /// `response` suspends until the message is inserted and then returns
  /// its `messageId`; it throws `ACPError` when the message is never
  /// inserted (`-32800` when cancellation or closing dropped it).
  public init(_ response: @escaping @Sendable () async throws -> ACPV2PromptResponse) {
    self.response = response
  }

  /// The message is already inserted.
  public static func inserted(messageId: ACPMessageID) -> ACPV2PromptSubmission {
    ACPV2PromptSubmission { ACPV2PromptResponse(messageId: messageId) }
  }

  /// The prompt was rejected before insertion.
  public static func rejected(_ error: ACPError) -> ACPV2PromptSubmission {
    ACPV2PromptSubmission { throw error }
  }
}

/// Implemented by ACP protocol version 2 agents.
///
/// The v2 prompt lifecycle differs from v1: `session/prompt` answers once
/// the user message is inserted, and foreground progress and completion
/// are reported through `state_update` notifications
/// (`ACPAgentSideConnection.sendUpdate`).
///
/// Advertising `capabilities.session` commits an agent to `newSession`,
/// `listSessions`, `resumeSession`, `closeSession`, `submitPrompt`, and
/// `cancel`. The remaining methods are optional and reject by default.
public protocol ACPV2Agent: Sendable {
  func initialize(_ request: ACPV2InitializeRequest) async throws -> ACPV2InitializeResponse
  func newSession(
    _ request: ACPV2NewSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPV2NewSessionResponse
  func resumeSession(
    _ request: ACPV2ResumeSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPV2ResumeSessionResponse
  func listSessions(
    _ request: ACPListSessionsRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPListSessionsResponse
  /// Cancels ongoing work and ends the session on this connection. Final
  /// updates and the idle `cancelled` state must be sent before returning.
  func closeSession(_ request: ACPSessionRequest, connection: ACPAgentSideConnection) async throws
  /// Registers a prompt. Called in arrival order and awaited before the
  /// next client message is read, so prompts and `session/cancel` keep
  /// their wire order; it must return promptly. The returned submission
  /// resolves when the message is inserted.
  func submitPrompt(
    _ request: ACPV2PromptRequest, connection: ACPAgentSideConnection
  ) async -> ACPV2PromptSubmission
  /// `session/cancel`: stops foreground work and drops prompts received
  /// before it that are not inserted yet. Called in arrival order.
  func cancel(_ notification: ACPCancelNotification, connection: ACPAgentSideConnection) async
  /// `session/delete`. Requires `capabilities.session.delete`.
  func deleteSession(_ request: ACPSessionRequest, connection: ACPAgentSideConnection) async throws
  /// `session/set_config_option`. Required when sessions advertise config options.
  func setConfigOption(
    _ request: ACPSetSessionConfigOptionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPSetSessionConfigOptionResponse
  /// `auth/login`. Required when `authMethods` is non-empty.
  func login(methodId: String) async throws
  /// `auth/logout`. Required when `authMethods` is non-empty.
  func logout() async throws
  /// `tool_call/cancel`. Required when a tool call advertises `capabilities.cancel`.
  func cancelToolCall(_ request: ACPV2CancelToolCallRequest) async throws
  /// `terminal/cancel`. Required when a terminal advertises `capabilities.cancel`.
  func cancelTerminal(_ request: ACPV2CancelTerminalRequest) async throws
  /// Any other request, including `_`-prefixed extension methods. `params`
  /// is the raw JSON params fragment; return the encoded JSON result.
  func extensionRequest(
    method: String, params: Data, connection: ACPAgentSideConnection
  ) async throws -> Data
}

extension ACPV2Agent {
  public func deleteSession(_ request: ACPSessionRequest, connection: ACPAgentSideConnection) async throws {
    throw ACPError.methodNotFound(ACPMethod.sessionDelete)
  }

  public func setConfigOption(
    _ request: ACPSetSessionConfigOptionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPSetSessionConfigOptionResponse {
    throw ACPError.methodNotFound(ACPMethod.sessionSetConfigOption)
  }

  public func login(methodId: String) async throws {
    throw ACPError.methodNotFound(ACPMethod.authLogin)
  }

  public func logout() async throws {
    throw ACPError.methodNotFound(ACPMethod.authLogout)
  }

  public func cancelToolCall(_ request: ACPV2CancelToolCallRequest) async throws {
    throw ACPError.methodNotFound(ACPMethod.toolCallCancel)
  }

  public func cancelTerminal(_ request: ACPV2CancelTerminalRequest) async throws {
    throw ACPError.methodNotFound(ACPMethod.terminalCancel)
  }

  public func extensionRequest(
    method: String, params: Data, connection: ACPAgentSideConnection
  ) async throws -> Data {
    throw ACPError.methodNotFound(method)
  }
}

/// Agent-side view of the connection: lets the agent stream `session/update`
/// notifications and issue client-bound requests such as permission checks.
public struct ACPAgentSideConnection: Sendable {
  private let connection: ACPConnection

  init(connection: ACPConnection) {
    self.connection = connection
  }

  /// Sends a v1 `session/update` notification.
  public func sendUpdate(_ notification: ACPSessionNotification) async {
    try? connection.notify(method: ACPMethod.sessionUpdate, params: notification)
  }

  /// Sends a v2 `session/update` notification. Synchronous: updates sent
  /// from one actor or task reach the wire in the order of the calls.
  public func sendUpdate(_ notification: ACPV2SessionNotification) {
    try? connection.notify(method: ACPMethod.sessionUpdate, params: notification)
  }

  /// Sends a v2 update for `sessionId`.
  public func sendUpdate(_ update: ACPV2SessionUpdate, sessionId: ACPSessionID) {
    sendUpdate(ACPV2SessionNotification(sessionId: sessionId, update: update))
  }

  public func sendRequest<Params: Encodable & Sendable, Result: Decodable & Sendable>(
    method: String, params: Params, as type: Result.Type = Result.self
  ) async throws -> Result {
    try await connection.sendRequest(method: method, params: params, as: type)
  }

  /// Asks the client for permission (v2 shape). Cancelling the calling
  /// task sends `$/cancel_request` for the pending request, as v2 requires
  /// when the work that needed the answer is cancelled.
  public func requestPermission(
    _ request: ACPV2RequestPermissionRequest
  ) async throws -> ACPRequestPermissionResponse {
    try await connection.sendRequest(method: ACPMethod.sessionRequestPermission, params: request)
  }
}

/// Binds agent implementations to a transport and serves the ACP agent side.
///
/// A server can host a v1 agent, a v2 agent, or both. During `initialize`
/// it selects the highest hosted version at or below the client's requested
/// version and dispatches every later message through that version's agent
/// only. When no hosted version qualifies it rejects `initialize` with
/// `-32022`.
public struct ACPAgentServer: Sendable {
  public let connection: ACPConnection
  private let router: ACPProtocolRouter

  /// Serves a v1-only agent.
  public init(agent: any ACPAgent, transport: any ACPTransport) {
    self.init(v1: agent, v2: nil, transport: transport)
  }

  /// Serves the given protocol versions side by side.
  public init(v1: (any ACPAgent)?, v2: (any ACPV2Agent)?, transport: any ACPTransport) {
    connection = ACPConnection(transport: transport)
    router = ACPProtocolRouter(v1: v1, v2: v2, side: ACPAgentSideConnection(connection: connection))
  }

  /// Serves until the client closes the connection.
  public func serve() async {
    await bind()
    await connection.start()
    await connection.waitUntilClosed()
  }

  /// Registers handlers and starts the read loop without blocking.
  public func start() async {
    await bind()
    await connection.start()
  }

  private func bind() async {
    let router = router
    await connection.setOrderedRequestHandler { method, params, _, _ in
      await router.dispose(method: method, params: params)
    }
    await connection.setNotificationHandler { method, params, _ in
      await router.notify(method: method, params: params)
    }
  }
}

/// Per-connection version negotiation and dispatch.
actor ACPProtocolRouter {
  private let v1: (any ACPAgent)?
  private let v2: (any ACPV2Agent)?
  private let side: ACPAgentSideConnection
  /// The version selected by the latest successful `initialize`.
  private var negotiated: Int?
  /// `initialize` may repeat only until the first other request.
  private var sawOtherRequest = false

  init(v1: (any ACPAgent)?, v2: (any ACPV2Agent)?, side: ACPAgentSideConnection) {
    self.v1 = v1
    self.v2 = v2
    self.side = side
  }

  private var supportedVersions: [Int] {
    (v1 == nil ? [] : [ACPProtocol.versionV1]) + (v2 == nil ? [] : [ACPProtocol.versionV2])
  }

  func dispose(method: String, params: Data) async -> ACPConnection.RequestDisposition {
    if method == ACPMethod.initialize {
      guard !sawOtherRequest else {
        return .reject(.invalidRequest("initialize must not be repeated after another request"))
      }
      do {
        return .respond(try await initialize(params))
      } catch let error as ACPError {
        return .reject(error)
      } catch {
        return .reject(.internalError(String(describing: error)))
      }
    }
    guard let negotiated else {
      return .reject(.invalidRequest("connection is not initialized; send initialize first"))
    }
    sawOtherRequest = true
    if negotiated == ACPProtocol.versionV2, let v2 {
      return await disposeV2(v2, method: method, params: params)
    }
    if let v1 {
      return .run { [side] in try await Self.dispatchV1(v1, side: side, method: method, params: params) }
    }
    return .reject(.methodNotFound(method))
  }

  func notify(method: String, params: Data) async {
    // Notifications before initialization completes are ignored.
    guard let negotiated, method == ACPMethod.sessionCancel,
          let notification = try? ACPConnection.decodeParams(ACPCancelNotification.self, from: params) else {
      return
    }
    if negotiated == ACPProtocol.versionV2 {
      await v2?.cancel(notification, connection: side)
    } else {
      await v1?.cancel(notification)
    }
  }

  // MARK: - initialize

  private func initialize(_ params: Data) async throws -> Data {
    // The version is read before any other parameter: a mismatch is never
    // reported as invalid params, and parameters written for a newer
    // version are not rejected.
    let requested = try Self.requestedVersion(params)
    let supported = supportedVersions
    guard let selected = supported.last(where: { $0 <= requested }) else {
      throw ACPError.unsupportedProtocolVersion(requested: requested, supported: supported)
    }
    let result: Data
    if selected == ACPProtocol.versionV2, let v2 {
      let request: ACPV2InitializeRequest
      do {
        request = try ACPConnection.decodeParams(ACPV2InitializeRequest.self, from: params)
      } catch {
        // A request for a newer version may not parse as v2; its
        // unparseable parameters are ignored rather than rejected.
        guard requested > selected else { throw error }
        request = ACPV2InitializeRequest(
          protocolVersion: requested, info: ACPImplementation(name: "unknown", version: "unknown")
        )
      }
      var response = try await v2.initialize(request)
      response.protocolVersion = selected
      result = try ACPConnection.encodeResult(response)
    } else if let v1 {
      let request = (try? ACPConnection.decodeParams(ACPInitializeRequest.self, from: params))
        ?? ACPInitializeRequest(protocolVersion: requested)
      var response = try await v1.initialize(request)
      response.protocolVersion = selected
      result = try ACPConnection.encodeResult(response)
    } else {
      throw ACPError.unsupportedProtocolVersion(requested: requested, supported: supported)
    }
    negotiated = selected
    return result
  }

  /// Missing, non-integer, or out-of-range versions are malformed params.
  static func requestedVersion(_ params: Data) throws -> Int {
    struct Probe: Decodable {
      var protocolVersion: Int
    }
    // JSONDecoder rejects strings, booleans, and fractional numbers here.
    guard let version = (try? JSONDecoder().decode(Probe.self, from: params))?.protocolVersion,
          ACPProtocol.versionRange.contains(version) else {
      throw ACPError.invalidParams("protocolVersion must be an integer from 0 to 65535")
    }
    return version
  }

  // MARK: - v1 dispatch

  private static func dispatchV1(
    _ agent: any ACPAgent, side: ACPAgentSideConnection, method: String, params: Data
  ) async throws -> Data {
    let empty = Data("{}".utf8)
    switch method {
    case ACPMethod.sessionNew:
      let request = try ACPConnection.decodeParams(ACPNewSessionRequest.self, from: params)
      return try ACPConnection.encodeResult(try await agent.newSession(request, connection: side))
    case ACPMethod.sessionLoad:
      let request = try ACPConnection.decodeParams(ACPLoadSessionRequest.self, from: params)
      return try ACPConnection.encodeResult(try await agent.loadSession(request, connection: side))
    case ACPMethod.sessionResume:
      let request = try ACPConnection.decodeParams(ACPLoadSessionRequest.self, from: params)
      return try ACPConnection.encodeResult(try await agent.resumeSession(request, connection: side))
    case ACPMethod.sessionList:
      let request = try ACPConnection.decodeParams(ACPListSessionsRequest.self, from: params)
      return try ACPConnection.encodeResult(try await agent.listSessions(request))
    case ACPMethod.sessionClose:
      try await agent.closeSession(try ACPConnection.decodeParams(ACPSessionRequest.self, from: params))
      return empty
    case ACPMethod.sessionDelete:
      try await agent.deleteSession(try ACPConnection.decodeParams(ACPSessionRequest.self, from: params))
      return empty
    case ACPMethod.sessionPrompt:
      let request = try ACPConnection.decodeParams(ACPPromptRequest.self, from: params)
      return try ACPConnection.encodeResult(try await agent.prompt(request, connection: side))
    case ACPMethod.sessionSetModel:
      try await agent.setModel(try ACPConnection.decodeParams(ACPSetSessionModelRequest.self, from: params))
      return empty
    case ACPMethod.sessionSetConfigOption:
      let request = try ACPConnection.decodeParams(ACPSetSessionConfigOptionRequest.self, from: params)
      return try ACPConnection.encodeResult(try await agent.setConfigOption(request))
    case ACPMethod.authenticate:
      let request = try ACPConnection.decodeParams(ACPLoginRequest.self, from: params)
      try await agent.authenticate(methodId: request.methodId)
      return empty
    default:
      return try await agent.extensionRequest(method: method, params: params)
    }
  }

  // MARK: - v2 dispatch

  private func disposeV2(
    _ agent: any ACPV2Agent, method: String, params: Data
  ) async -> ACPConnection.RequestDisposition {
    guard method == ACPMethod.sessionPrompt else {
      return .run { [side] in try await Self.dispatchV2(agent, side: side, method: method, params: params) }
    }
    // Prompts are registered inline so they keep their arrival order
    // relative to each other and to session/cancel.
    let request: ACPV2PromptRequest
    do {
      request = try ACPConnection.decodeParams(ACPV2PromptRequest.self, from: params)
    } catch {
      return .reject(error as? ACPError ?? .invalidParams())
    }
    let submission = await agent.submitPrompt(request, connection: side)
    return .run { try ACPConnection.encodeResult(try await submission.response()) }
  }

  private static func dispatchV2(
    _ agent: any ACPV2Agent, side: ACPAgentSideConnection, method: String, params: Data
  ) async throws -> Data {
    let empty = Data("{}".utf8)
    switch method {
    case ACPMethod.sessionNew:
      let request = try ACPConnection.decodeParams(ACPV2NewSessionRequest.self, from: params)
      return try ACPConnection.encodeResult(try await agent.newSession(request, connection: side))
    case ACPMethod.sessionResume:
      let request = try ACPConnection.decodeParams(ACPV2ResumeSessionRequest.self, from: params)
      return try ACPConnection.encodeResult(try await agent.resumeSession(request, connection: side))
    case ACPMethod.sessionList:
      let request = try ACPConnection.decodeParams(ACPListSessionsRequest.self, from: params)
      return try ACPConnection.encodeResult(try await agent.listSessions(request, connection: side))
    case ACPMethod.sessionClose:
      let request = try ACPConnection.decodeParams(ACPSessionRequest.self, from: params)
      try await agent.closeSession(request, connection: side)
      return empty
    case ACPMethod.sessionDelete:
      let request = try ACPConnection.decodeParams(ACPSessionRequest.self, from: params)
      try await agent.deleteSession(request, connection: side)
      return empty
    case ACPMethod.sessionSetConfigOption:
      let request = try ACPConnection.decodeParams(ACPSetSessionConfigOptionRequest.self, from: params)
      return try ACPConnection.encodeResult(try await agent.setConfigOption(request, connection: side))
    case ACPMethod.authLogin:
      let request = try ACPConnection.decodeParams(ACPLoginRequest.self, from: params)
      try await agent.login(methodId: request.methodId)
      return empty
    case ACPMethod.authLogout:
      try await agent.logout()
      return empty
    case ACPMethod.toolCallCancel:
      try await agent.cancelToolCall(try ACPConnection.decodeParams(ACPV2CancelToolCallRequest.self, from: params))
      return empty
    case ACPMethod.terminalCancel:
      try await agent.cancelTerminal(try ACPConnection.decodeParams(ACPV2CancelTerminalRequest.self, from: params))
      return empty
    default:
      return try await agent.extensionRequest(method: method, params: params, connection: side)
    }
  }
}
