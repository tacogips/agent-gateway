import Foundation

/// Implemented by ACP agents (the process that answers `initialize`,
/// `session/new`, and `session/prompt`).
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
}

extension ACPAgent {
  public func authenticate(methodId: String) async throws {
    throw ACPError.invalidParams("authentication is not supported")
  }
}

/// Agent-side view of the connection: lets the agent stream `session/update`
/// notifications and issue client-bound requests such as permission checks.
public struct ACPAgentSideConnection: Sendable {
  private let connection: ACPConnection

  init(connection: ACPConnection) {
    self.connection = connection
  }

  public func sendUpdate(_ notification: ACPSessionNotification) async {
    try? await connection.sendNotification(method: ACPMethod.sessionUpdate, params: notification)
  }

  public func sendRequest<Params: Encodable & Sendable, Result: Decodable & Sendable>(
    method: String, params: Params, as type: Result.Type = Result.self
  ) async throws -> Result {
    try await connection.sendRequest(method: method, params: params, as: type)
  }
}

/// Binds an `ACPAgent` to a transport and serves the ACP agent side.
public struct ACPAgentServer: Sendable {
  public let connection: ACPConnection
  private let agent: any ACPAgent

  public init(agent: any ACPAgent, transport: any ACPTransport) {
    self.agent = agent
    self.connection = ACPConnection(transport: transport)
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
    let agent = agent
    let side = ACPAgentSideConnection(connection: connection)
    await connection.setRequestHandler { method, params, _ in
      switch method {
      case ACPMethod.initialize:
        let request = try ACPConnection.decodeParams(ACPInitializeRequest.self, from: params)
        return try ACPConnection.encodeResult(try await agent.initialize(request))
      case ACPMethod.sessionNew:
        let request = try ACPConnection.decodeParams(ACPNewSessionRequest.self, from: params)
        return try ACPConnection.encodeResult(try await agent.newSession(request, connection: side))
      case ACPMethod.sessionPrompt:
        let request = try ACPConnection.decodeParams(ACPPromptRequest.self, from: params)
        return try ACPConnection.encodeResult(try await agent.prompt(request, connection: side))
      case ACPMethod.authenticate:
        struct AuthenticateParams: Decodable {
          var methodId: String
        }
        let request = try ACPConnection.decodeParams(AuthenticateParams.self, from: params)
        try await agent.authenticate(methodId: request.methodId)
        return Data("{}".utf8)
      default:
        throw ACPError.methodNotFound(method)
      }
    }
    await connection.setNotificationHandler { method, params, _ in
      guard method == ACPMethod.sessionCancel,
            let notification = try? ACPConnection.decodeParams(ACPCancelNotification.self, from: params) else {
        return
      }
      await agent.cancel(notification)
    }
  }
}
