import Foundation

// swiftlint:disable class_delegate_protocol
/// Receives agent-initiated traffic on the client side. Value-type and actor
/// delegates are both supported, so this protocol is intentionally not
/// class-bound.
public protocol ACPClientDelegate: Sendable {
  /// A `session/update` on a connection that negotiated protocol version 1.
  func sessionUpdate(_ notification: ACPSessionNotification) async
  /// A `session/update` on a connection that negotiated protocol version 2.
  /// The default ignores it.
  func sessionUpdate(_ notification: ACPV2SessionNotification) async
  /// Answers agent-initiated requests such as `session/request_permission`
  /// or `fs/read_text_file`. `params` is the raw JSON params fragment; return
  /// the encoded JSON result. The default rejects every method.
  func handleRequest(method: String, params: Data) async throws -> Data
}

extension ACPClientDelegate {
  public func sessionUpdate(_ notification: ACPV2SessionNotification) async {}

  public func handleRequest(method: String, params: Data) async throws -> Data {
    throw ACPError.methodNotFound(method)
  }
}
// swiftlint:enable class_delegate_protocol

/// One event of a streaming prompt turn (`promptStream`).
public enum ACPPromptEvent: Equatable, Sendable {
  /// A `session/update` notification for the prompted session.
  case update(ACPSessionUpdate)
  /// The turn finished; always the final event of a successful stream.
  case response(ACPPromptResponse)
}

/// Aggregated outcome of a prompt turn (`promptCollecting`).
public struct ACPPromptResult: Equatable, Sendable {
  public var response: ACPPromptResponse
  /// Concatenated `agent_message_chunk` text.
  public var messageText: String
  /// Concatenated `agent_thought_chunk` text.
  public var thoughtText: String
  /// Every update received during the turn, in order.
  public var updates: [ACPSessionUpdate]

  public init(
    response: ACPPromptResponse,
    messageText: String = "",
    thoughtText: String = "",
    updates: [ACPSessionUpdate] = []
  ) {
    self.response = response
    self.messageText = messageText
    self.thoughtText = thoughtText
    self.updates = updates
  }
}

/// Fans `session/update` notifications out to per-turn subscribers and
/// remembers which protocol version the connection negotiated.
actor ACPSessionUpdateHub {
  private var nextToken = 0
  private var subscribers: [Int: (ACPSessionID, @Sendable (ACPSessionNotification) -> Void)] = [:]
  private var subscribersV2: [Int: (ACPSessionID, @Sendable (ACPV2SessionUpdate) -> Void)] = [:]
  private(set) var negotiatedVersion: Int?

  func setNegotiatedVersion(_ version: Int) {
    negotiatedVersion = version
  }

  func subscribe(
    sessionId: ACPSessionID,
    handler: @escaping @Sendable (ACPSessionNotification) -> Void
  ) -> Int {
    nextToken += 1
    subscribers[nextToken] = (sessionId, handler)
    return nextToken
  }

  func subscribeV2(
    sessionId: ACPSessionID,
    handler: @escaping @Sendable (ACPV2SessionUpdate) -> Void
  ) -> Int {
    nextToken += 1
    subscribersV2[nextToken] = (sessionId, handler)
    return nextToken
  }

  func unsubscribe(_ token: Int) {
    subscribers[token] = nil
    subscribersV2[token] = nil
  }

  func publish(_ notification: ACPSessionNotification) {
    for (sessionId, handler) in subscribers.values where sessionId == notification.sessionId {
      handler(notification)
    }
  }

  func publish(_ notification: ACPV2SessionNotification) {
    for (sessionId, handler) in subscribersV2.values where sessionId == notification.sessionId {
      handler(notification.update)
    }
  }
}

/// ACP client: drives an agent over a transport
/// (`initialize` → `session/new` → `session/prompt`).
///
/// Prompt turns come in two shapes, chosen per call:
/// - `promptStream(_:)` streams every `session/update` as it arrives.
/// - `promptCollecting(_:)` awaits the finished turn and returns the
///   aggregated text plus the ordered update list.
/// Both wrap the same `prompt(_:)` request; the delegate (if any) continues
/// to observe all updates independently.
public struct ACPClientConnection: Sendable {
  public let connection: ACPConnection
  private let delegate: (any ACPClientDelegate)?
  let updateHub = ACPSessionUpdateHub()

  public init(transport: any ACPTransport, delegate: (any ACPClientDelegate)? = nil) {
    connection = ACPConnection(transport: transport)
    self.delegate = delegate
  }

  /// Hosts `agent` in this process over an in-memory transport pair and
  /// returns a started, connected client. Library consumers get ACP
  /// semantics (sessions, streaming updates) without spawning a subprocess.
  /// The returned server value keeps the agent side alive; retain it for
  /// the connection's lifetime.
  public static func inProcess(
    agent: any ACPAgent, delegate: (any ACPClientDelegate)? = nil
  ) async -> (client: ACPClientConnection, server: ACPAgentServer) {
    await inProcess(v1: agent, v2: nil, delegate: delegate)
  }

  /// Hosts a dual-stack endpoint in this process: the client picks the
  /// protocol version with `initialize(_:)` (v1) or `negotiate(_:)` (v2
  /// with fallback).
  public static func inProcess(
    v1: (any ACPAgent)?, v2: (any ACPV2Agent)?, delegate: (any ACPClientDelegate)? = nil
  ) async -> (client: ACPClientConnection, server: ACPAgentServer) {
    let (clientSide, agentSide) = ACPInMemoryTransport.pair()
    let server = ACPAgentServer(v1: v1, v2: v2, transport: agentSide)
    await server.start()
    let client = ACPClientConnection(transport: clientSide, delegate: delegate)
    await client.start()
    return (client, server)
  }

  /// Registers handlers and starts the read loop. Call before sending requests.
  public func start() async {
    let delegate = delegate
    let hub = updateHub
    await connection.setNotificationHandler { method, params, _ in
      guard method == ACPMethod.sessionUpdate else { return }
      // One connection speaks exactly one negotiated version, and the two
      // versions' update shapes are decoded by separate types.
      if await hub.negotiatedVersion == ACPProtocol.versionV2 {
        guard let notification = try? ACPConnection.decodeParams(ACPV2SessionNotification.self, from: params) else {
          return
        }
        // The delegate observes an update before per-turn streams do, so a
        // turn never finishes ahead of the delegate seeing its last update.
        await delegate?.sessionUpdate(notification)
        await hub.publish(notification)
        return
      }
      guard let notification = try? ACPConnection.decodeParams(ACPSessionNotification.self, from: params) else {
        return
      }
      await delegate?.sessionUpdate(notification)
      await hub.publish(notification)
    }
    await connection.setRequestHandler { method, params, _ in
      guard let delegate else { throw ACPError.methodNotFound(method) }
      return try await delegate.handleRequest(method: method, params: params)
    }
    await connection.start()
  }

  public func stop() async {
    await connection.stop()
  }

  public func waitUntilClosed() async {
    await connection.waitUntilClosed()
  }

  /// Initializes the connection as protocol version 1. Use
  /// `negotiate(_:)` to request version 2 with fallback to version 1.
  public func initialize(_ request: ACPInitializeRequest = ACPInitializeRequest()) async throws -> ACPInitializeResponse {
    let response: ACPInitializeResponse = try await connection.sendRequest(
      method: ACPMethod.initialize, params: request
    )
    guard response.protocolVersion == ACPProtocol.versionV1 else {
      throw ACPError.unsupportedProtocolVersion(
        requested: request.protocolVersion, supported: [ACPProtocol.versionV1]
      )
    }
    await updateHub.setNegotiatedVersion(response.protocolVersion)
    return response
  }

  public func newSession(_ request: ACPNewSessionRequest) async throws -> ACPNewSessionResponse {
    try await connection.sendRequest(method: ACPMethod.sessionNew, params: request)
  }

  public func prompt(_ request: ACPPromptRequest) async throws -> ACPPromptResponse {
    try await connection.sendRequest(method: ACPMethod.sessionPrompt, params: request)
  }

  /// v1 `session/load`: restores a session and replays its history as
  /// `session/update` notifications before responding. Requires the
  /// agent's `loadSession` capability.
  public func loadSession(_ request: ACPLoadSessionRequest) async throws -> ACPLoadSessionResponse {
    try await connection.sendRequest(method: ACPMethod.sessionLoad, params: request)
  }

  /// v1 `session/resume`: restores a session without replay. Requires the
  /// agent's `sessionCapabilities.resume`.
  public func resumeSession(_ request: ACPLoadSessionRequest) async throws -> ACPLoadSessionResponse {
    try await connection.sendRequest(method: ACPMethod.sessionResume, params: request)
  }

  /// v1 `session/set_config_option`; returns the complete updated options.
  public func setConfigOption(
    sessionId: ACPSessionID, configId: String, value: ACPSessionConfigValue
  ) async throws -> [ACPSessionConfigOption] {
    let response: ACPSetSessionConfigOptionResponse = try await connection.sendRequest(
      method: ACPMethod.sessionSetConfigOption,
      params: ACPSetSessionConfigOptionRequest(
        sessionId: sessionId, configId: configId, value: value, usesV1Encoding: true
      )
    )
    return response.configOptions
  }

  /// Legacy `session/set_model` from an early unstable v1 schema; current
  /// agents expose models as a `model` config option instead. Valid for
  /// agents that returned `models`
  /// from `session/new`.
  public func setModel(sessionId: ACPSessionID, modelId: String) async throws {
    struct Empty: Decodable, Sendable {}
    let _: Empty = try await connection.sendRequest(
      method: ACPMethod.sessionSetModel,
      params: ACPSetSessionModelRequest(sessionId: sessionId, modelId: modelId)
    )
  }

  /// Runs one prompt turn, streaming its `session/update`s as they arrive.
  /// The final event of a successful turn is `.response`. Abandoning the
  /// stream does not cancel the agent-side turn; send `cancel(sessionId:)`
  /// for that.
  public func promptStream(_ request: ACPPromptRequest) -> AsyncThrowingStream<ACPPromptEvent, any Error> {
    let hub = updateHub
    let connection = connection
    return AsyncThrowingStream(ACPPromptEvent.self) { continuation in
      let task = Task {
        let token = await hub.subscribe(sessionId: request.sessionId) { notification in
          continuation.yield(.update(notification.update))
        }
        defer { Task { await hub.unsubscribe(token) } }
        do {
          let response: ACPPromptResponse = try await connection.sendRequest(
            method: ACPMethod.sessionPrompt, params: request
          )
          continuation.yield(.response(response))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { termination in
        if case .cancelled = termination { task.cancel() }
      }
    }
  }

  /// Runs one prompt turn and returns the aggregated result: the response
  /// plus concatenated message/thought text and the full update list.
  /// Aggregation is implemented on top of `promptStream(_:)`.
  public func promptCollecting(_ request: ACPPromptRequest) async throws -> ACPPromptResult {
    var messageText = ""
    var thoughtText = ""
    var updates: [ACPSessionUpdate] = []
    for try await event in promptStream(request) {
      switch event {
      case .update(let update):
        updates.append(update)
        switch update {
        case .agentMessageChunk(.text(let content)):
          messageText += content.text
        case .agentThoughtChunk(.text(let content)):
          thoughtText += content.text
        default:
          break
        }
      case .response(let response):
        return ACPPromptResult(
          response: response,
          messageText: messageText,
          thoughtText: thoughtText,
          updates: updates
        )
      }
    }
    throw ACPError.internalError("prompt stream ended without a response")
  }

  public func cancel(sessionId: ACPSessionID) async throws {
    try await connection.sendNotification(
      method: ACPMethod.sessionCancel,
      params: ACPCancelNotification(sessionId: sessionId)
    )
  }
}
