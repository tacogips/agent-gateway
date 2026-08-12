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

/// ACP client: drives an agent over a transport
/// (`initialize` → `session/new` → `session/prompt`).
public struct ACPClientConnection: Sendable {
  public let connection: ACPConnection
  private let delegate: (any ACPClientDelegate)?

  public init(transport: any ACPTransport, delegate: (any ACPClientDelegate)? = nil) {
    connection = ACPConnection(transport: transport)
    self.delegate = delegate
  }

  /// Registers handlers and starts the read loop. Call before sending requests.
  public func start() async {
    let delegate = delegate
    await connection.setNotificationHandler { method, params, _ in
      guard method == ACPMethod.sessionUpdate,
            let notification = try? ACPConnection.decodeParams(ACPSessionNotification.self, from: params) else {
        return
      }
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

  public func cancel(sessionId: String) async throws {
    try await connection.sendNotification(
      method: ACPMethod.sessionCancel,
      params: ACPCancelNotification(sessionId: sessionId)
    )
  }
}
