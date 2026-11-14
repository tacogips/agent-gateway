import Foundation

// swiftlint:disable class_delegate_protocol
/// Receives agent-initiated traffic on the client side. Value-type and actor
/// delegates are both supported, so this protocol is intentionally not
/// class-bound.
public protocol ACPClientDelegate: Sendable {
  func sessionUpdate(_ notification: ACPSessionNotification) async
  /// Answers agent-initiated requests such as `session/request_permission`
  /// or `fs/read_text_file`. `params` is the raw JSON params fragment; return
  /// the encoded JSON result. The default rejects every method.
  func handleRequest(method: String, params: Data) async throws -> Data
}

extension ACPClientDelegate {
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

/// Fans `session/update` notifications out to per-turn subscribers.
private actor ACPSessionUpdateHub {
  private var nextToken = 0
  private var subscribers: [Int: (ACPSessionID, @Sendable (ACPSessionNotification) -> Void)] = [:]

  func subscribe(
    sessionId: ACPSessionID,
    handler: @escaping @Sendable (ACPSessionNotification) -> Void
  ) -> Int {
    nextToken += 1
    subscribers[nextToken] = (sessionId, handler)
    return nextToken
  }

  func unsubscribe(_ token: Int) {
    subscribers[token] = nil
  }

  func publish(_ notification: ACPSessionNotification) {
    for (sessionId, handler) in subscribers.values where sessionId == notification.sessionId {
      handler(notification)
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
  private let updateHub = ACPSessionUpdateHub()

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
    let (clientSide, agentSide) = ACPInMemoryTransport.pair()
    let server = ACPAgentServer(agent: agent, transport: agentSide)
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
      guard method == ACPMethod.sessionUpdate,
            let notification = try? ACPConnection.decodeParams(ACPSessionNotification.self, from: params) else {
        return
      }
      await hub.publish(notification)
      await delegate?.sessionUpdate(notification)
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

  public func initialize(_ request: ACPInitializeRequest = ACPInitializeRequest()) async throws -> ACPInitializeResponse {
    try await connection.sendRequest(method: ACPMethod.initialize, params: request)
  }

  public func newSession(_ request: ACPNewSessionRequest) async throws -> ACPNewSessionResponse {
    try await connection.sendRequest(method: ACPMethod.sessionNew, params: request)
  }

  public func prompt(_ request: ACPPromptRequest) async throws -> ACPPromptResponse {
    try await connection.sendRequest(method: ACPMethod.sessionPrompt, params: request)
  }

  /// Switches the session's model; valid for agents that returned `models`
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
