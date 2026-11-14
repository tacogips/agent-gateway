import Foundation

/// Bidirectional JSON-RPC 2.0 peer over an `ACPTransport`.
///
/// Both ACP sides (client and agent) are JSON-RPC peers: each can send
/// requests and notifications and must answer the other side's requests.
public actor ACPConnection {
  public typealias RequestHandler = @Sendable (
    _ method: String, _ params: Data, _ connection: ACPConnection
  ) async throws -> Data
  public typealias NotificationHandler = @Sendable (
    _ method: String, _ params: Data, _ connection: ACPConnection
  ) async -> Void
  public typealias RawLineObserver = @Sendable (_ line: Data, _ outgoing: Bool) -> Void

  private let transport: any ACPTransport
  private var requestHandler: RequestHandler?
  private var notificationHandler: NotificationHandler?
  private var rawLineObserver: RawLineObserver?
  private var nextRequestNumber = 0
  private var pending: [ACPRequestID: CheckedContinuation<Data, any Error>] = [:]
  private var runTask: Task<Void, Never>?
  private var closed = false

  public init(transport: any ACPTransport) {
    self.transport = transport
  }

  /// Handles incoming requests. Return the encoded JSON result;
  /// throw `ACPError` to produce a protocol error response.
  public func setRequestHandler(_ handler: @escaping RequestHandler) {
    requestHandler = handler
  }

  public func setNotificationHandler(_ handler: @escaping NotificationHandler) {
    notificationHandler = handler
  }

  /// Observes every line sent or received, e.g. for logging raw traffic.
  public func setRawLineObserver(_ observer: RawLineObserver?) {
    rawLineObserver = observer
  }

  /// Starts reading messages. Returns immediately; the read loop runs until
  /// the transport finishes or `stop()` is called.
  public func start() {
    guard runTask == nil else { return }
    runTask = Task { [weak self, transport] in
      for await line in transport.lines {
        guard let self else { break }
        await self.receive(line: line)
      }
      await self?.finish()
    }
  }

  /// Waits until the peer closes the connection.
  public func waitUntilClosed() async {
    await runTask?.value
  }

  public func stop() {
    transport.close()
    finish()
  }

  private func finish() {
    guard !closed else { return }
    closed = true
    for continuation in pending.values {
      continuation.resume(throwing: ACPError.internalError("connection closed"))
    }
    pending.removeAll()
  }

  // MARK: - Outgoing

  public func sendRequest<Params: Encodable & Sendable, Result: Decodable & Sendable>(
    method: String,
    params: Params,
    as type: Result.Type = Result.self
  ) async throws -> Result {
    guard !closed else { throw ACPError.internalError("connection closed") }
    nextRequestNumber += 1
    let id = ACPRequestID.number(nextRequestNumber)
    let line = try ACPWireCoding.encodeRequest(id: id, method: method, params: params)
    let resultData: Data = try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      write(line)
    }
    return try ACPWireCoding.decoder.decode(Result.self, from: resultData)
  }

  public func sendNotification<Params: Encodable & Sendable>(method: String, params: Params) throws {
    guard !closed else { throw ACPError.internalError("connection closed") }
    write(try ACPWireCoding.encodeNotification(method: method, params: params))
  }

  private func write(_ line: Data) {
    rawLineObserver?(line, true)
    transport.send(line: line)
  }

  // MARK: - Incoming

  private func receive(line: Data) async {
    rawLineObserver?(line, false)
    let message: ACPIncomingMessage
    do {
      message = try ACPWireCoding.parse(line)
    } catch {
      let acpError = error as? ACPError ?? ACPError.parseError()
      if let data = try? ACPWireCoding.encodeError(id: nil, error: acpError) {
        write(data)
      }
      return
    }
    switch message {
    case .request(let id, let method, let params):
      // Handled off the read loop so long-running requests (session/prompt)
      // don't block notifications such as session/cancel.
      Task { await self.handle(id: id, method: method, params: params) }
    case .notification(let method, let params):
      // Awaited inline so streamed updates keep their on-wire order.
      // Notification handlers must not block on peer round-trips.
      await notificationHandler?(method, params, self)
    case .response(let id, let result, let error):
      guard let continuation = pending.removeValue(forKey: id) else { return }
      if let error {
        continuation.resume(throwing: error)
      } else {
        continuation.resume(returning: result ?? Data("null".utf8))
      }
    }
  }

  private func handle(id: ACPRequestID, method: String, params: Data) async {
    guard let requestHandler else {
      respond(id: id, error: ACPError.methodNotFound(method))
      return
    }
    do {
      let result = try await requestHandler(method, params, self)
      do {
        write(try ACPWireCoding.encodeResponse(id: id, result: ACPRawJSON(result)))
      } catch {
        // Never leave the peer's request pending: a result that fails to
        // encode still gets an error response.
        respond(id: id, error: ACPError.internalError("failed to encode response"))
      }
    } catch let error as ACPError {
      respond(id: id, error: error)
    } catch is CancellationError {
      respond(id: id, error: ACPError.internalError("request cancelled"))
    } catch {
      respond(id: id, error: ACPError.internalError(String(describing: error)))
    }
  }

  private func respond(id: ACPRequestID, error: ACPError) {
    guard let line = try? ACPWireCoding.encodeError(id: id, error: error) else { return }
    write(line)
  }
}

/// Wraps already-encoded JSON so it can be embedded in another Encodable value.
struct ACPRawJSON: Encodable {
  let data: Data

  init(_ data: Data) {
    self.data = data
  }

  func encode(to encoder: any Encoder) throws {
    let value = try JSONDecoder().decode(ACPJSONValue.self, from: data)
    try value.encode(to: encoder)
  }
}

extension ACPConnection {
  /// Encodes a typed handler result for `setRequestHandler`.
  public static func encodeResult<T: Encodable>(_ value: T) throws -> Data {
    try ACPWireCoding.encoder.encode(value)
  }

  /// Decodes typed params inside a request handler, mapping failures to
  /// JSON-RPC invalid-params errors.
  public static func decodeParams<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
      return try ACPWireCoding.decoder.decode(type, from: data)
    } catch {
      throw ACPError.invalidParams(String(describing: error))
    }
  }
}
