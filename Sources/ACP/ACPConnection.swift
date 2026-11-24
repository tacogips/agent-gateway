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

  /// How an ordered request handler disposes of an incoming request.
  public enum RequestDisposition: Sendable {
    /// Answered inline with this encoded JSON result.
    case respond(Data)
    /// Answered inline with this error.
    case reject(ACPError)
    /// The request was admitted in arrival order; `work` produces its result
    /// concurrently so it never blocks the read loop.
    case run(@Sendable () async throws -> Data)
    /// Not claimed; falls through to the plain request handler.
    case unhandled
  }

  /// Sees every incoming request in arrival order, awaited on the read loop
  /// before the next message is read. Use it for work whose order relative
  /// to other messages matters (initialization gating, prompt admission);
  /// it must return promptly and move long work into `.run`.
  public typealias OrderedRequestHandler = @Sendable (
    _ method: String, _ params: Data, _ id: ACPRequestID, _ connection: ACPConnection
  ) async -> RequestDisposition

  private let transport: any ACPTransport
  private let outbox: ACPOutbox
  private var requestHandler: RequestHandler?
  private var orderedRequestHandler: OrderedRequestHandler?
  private var notificationHandler: NotificationHandler?
  private var nextRequestNumber = 0
  private var pending: [ACPRequestID: CheckedContinuation<Data, any Error>] = [:]
  /// Requests received from the peer that have not been answered yet, so
  /// `$/cancel_request` can reach the work behind them.
  private var inFlight: [ACPRequestID: Task<Void, Never>] = [:]
  private var runTask: Task<Void, Never>?
  private var closed = false

  public init(transport: any ACPTransport) {
    self.transport = transport
    outbox = ACPOutbox(transport: transport)
  }

  /// Handles incoming requests. Return the encoded JSON result;
  /// throw `ACPError` to produce a protocol error response.
  public func setRequestHandler(_ handler: @escaping RequestHandler) {
    requestHandler = handler
  }

  /// Installs the arrival-ordered request handler; see `OrderedRequestHandler`.
  public func setOrderedRequestHandler(_ handler: @escaping OrderedRequestHandler) {
    orderedRequestHandler = handler
  }

  public func setNotificationHandler(_ handler: @escaping NotificationHandler) {
    notificationHandler = handler
  }

  /// Observes every line sent or received, e.g. for logging raw traffic.
  public func setRawLineObserver(_ observer: RawLineObserver?) {
    outbox.setObserver(observer)
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
    outbox.close()
    for continuation in pending.values {
      continuation.resume(throwing: ACPError.internalError("connection closed"))
    }
    pending.removeAll()
    for task in inFlight.values {
      task.cancel()
    }
    inFlight.removeAll()
  }

  // MARK: - Outgoing

  /// Sends a request and awaits its response. Cancelling the calling task
  /// sends `$/cancel_request` for it and keeps waiting for the peer's
  /// response, which the peer still owes.
  public func sendRequest<Params: Encodable & Sendable, Result: Decodable & Sendable>(
    method: String,
    params: Params,
    as type: Result.Type = Result.self
  ) async throws -> Result {
    guard !closed else { throw ACPError.internalError("connection closed") }
    guard !Task.isCancelled else { throw ACPError.requestCancelled() }
    nextRequestNumber += 1
    let id = ACPRequestID.number(nextRequestNumber)
    let line = try ACPWireCoding.encodeRequest(id: id, method: method, params: params)
    let cancelLine = try ACPWireCoding.encodeNotification(
      method: ACPMethod.cancelRequest, params: ACPCancelRequestNotification(requestId: id)
    )
    let outbox = outbox
    let resultData: Data = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending[id] = continuation
        outbox.write(line)
      }
    } onCancel: {
      outbox.write(cancelLine)
    }
    return try ACPWireCoding.decoder.decode(Result.self, from: resultData)
  }

  public func sendNotification<Params: Encodable & Sendable>(method: String, params: Params) throws {
    try notify(method: method, params: params)
  }

  /// Sends a notification synchronously, from any isolation. Lines written
  /// by one caller keep the order of its calls, so an actor that reports
  /// session state through this method gets a totally ordered update stream.
  public nonisolated func notify<Params: Encodable>(method: String, params: Params) throws {
    guard outbox.write(try ACPWireCoding.encodeNotification(method: method, params: params)) else {
      throw ACPError.internalError("connection closed")
    }
  }

  /// Asks the peer to cancel a request this side sent (`$/cancel_request`).
  /// The peer still answers the request; unknown ids are ignored by it.
  public nonisolated func cancelRequest(_ id: ACPRequestID) {
    try? notify(method: ACPMethod.cancelRequest, params: ACPCancelRequestNotification(requestId: id))
  }

  // MARK: - Incoming

  private func receive(line: Data) async {
    outbox.observeIncoming(line)
    let message: ACPIncomingMessage
    do {
      message = try ACPWireCoding.parse(line)
    } catch let invalid as ACPInvalidEnvelope {
      write(error: invalid.error, id: invalid.id)
      return
    } catch {
      write(error: error as? ACPError ?? ACPError.parseError(), id: nil)
      return
    }
    switch message {
    case .request(let id, let method, let params):
      await admit(id: id, method: method, params: params)
    case .notification(let method, let params):
      if method == ACPMethod.cancelRequest {
        cancelInFlight(params)
        return
      }
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

  private func cancelInFlight(_ params: Data) {
    guard let notification = try? ACPWireCoding.decoder.decode(ACPCancelRequestNotification.self, from: params) else {
      return
    }
    // Unknown or already answered ids are ignored: no second response.
    inFlight[notification.requestId]?.cancel()
  }

  private func admit(id: ACPRequestID, method: String, params: Data) async {
    var work: (@Sendable () async throws -> Data)?
    if let orderedRequestHandler {
      switch await orderedRequestHandler(method, params, id, self) {
      case .respond(let result):
        respond(id: id, result: result)
        return
      case .reject(let error):
        write(error: error, id: id)
        return
      case .run(let admitted):
        work = admitted
      case .unhandled:
        break
      }
    }
    if work == nil, let requestHandler {
      work = { [self] in try await requestHandler(method, params, self) }
    }
    guard let work else {
      write(error: ACPError.methodNotFound(method), id: id)
      return
    }
    guard !closed else { return }
    // Run off the read loop so long-running requests (session/prompt)
    // don't block notifications such as session/cancel.
    inFlight[id] = Task { await self.run(id: id, work: work) }
  }

  private func run(id: ACPRequestID, work: @Sendable () async throws -> Data) async {
    let outcome: Result<Data, ACPError>
    do {
      outcome = .success(try await work())
    } catch let error as ACPError {
      outcome = .failure(error)
    } catch is CancellationError {
      outcome = .failure(ACPError.requestCancelled())
    } catch {
      outcome = .failure(ACPError.internalError(String(describing: error)))
    }
    inFlight[id] = nil
    switch outcome {
    case .success(let result): respond(id: id, result: result)
    case .failure(let error): write(error: error, id: id)
    }
  }

  private func respond(id: ACPRequestID, result: Data) {
    do {
      outbox.write(try ACPWireCoding.encodeResponse(id: id, result: ACPRawJSON(result)))
    } catch {
      // Never leave the peer's request pending: a result that fails to
      // encode still gets an error response.
      write(error: ACPError.internalError("failed to encode response"), id: id)
    }
  }

  private func write(error: ACPError, id: ACPRequestID?) {
    guard let line = try? ACPWireCoding.encodeError(id: id, error: error) else { return }
    outbox.write(line)
  }
}

/// `$/cancel_request` notification params.
public struct ACPCancelRequestNotification: Codable, Equatable, Sendable {
  public var requestId: ACPRequestID
  public var meta: ACPJSONValue?

  public init(requestId: ACPRequestID, meta: ACPJSONValue? = nil) {
    self.requestId = requestId
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case requestId
    case meta = "_meta"
  }
}

/// Serializes writes to the transport so lines never interleave and a
/// single writer's lines keep their call order, without actor hops.
final class ACPOutbox: @unchecked Sendable {
  private let lock = NSLock()
  private let transport: any ACPTransport
  private var observer: ACPConnection.RawLineObserver?
  private var closed = false

  init(transport: any ACPTransport) {
    self.transport = transport
  }

  func setObserver(_ observer: ACPConnection.RawLineObserver?) {
    lock.withLock { self.observer = observer }
  }

  func observeIncoming(_ line: Data) {
    let observer = lock.withLock { self.observer }
    observer?(line, false)
  }

  /// Returns false when the connection is already closed and nothing was written.
  @discardableResult
  func write(_ line: Data) -> Bool {
    lock.withLock {
      guard !closed else { return false }
      observer?(line, true)
      transport.send(line: line)
      return true
    }
  }

  func close() {
    lock.withLock { closed = true }
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
