import Foundation

/// What `negotiate(_:)` settled on: the agent's initialization result in
/// the shape of the protocol version it selected.
public enum ACPNegotiatedInitialization: Equatable, Sendable {
  /// The agent selected protocol version 1 (it does not speak v2). The
  /// connection continues with the v1 API (`newSession`, `prompt`, …).
  case v1(ACPInitializeResponse)
  /// The agent selected protocol version 2. The connection continues with
  /// the v2 API (`newSessionV2`, `promptTurn`, …).
  case v2(ACPV2InitializeResponse)

  public var protocolVersion: Int {
    switch self {
    case .v1: ACPProtocol.versionV1
    case .v2: ACPProtocol.versionV2
    }
  }
}

/// One event of a v2 prompt turn (`promptTurn`).
public enum ACPV2TurnEvent: Equatable, Sendable {
  /// The agent inserted the user message; carries its `messageId`. May
  /// arrive before or after the updates describing the same message.
  case accepted(ACPV2PromptResponse)
  /// A `session/update` for the prompted session.
  case update(ACPV2SessionUpdate)
  /// Foreground work ended: the idle `state_update`, with its stop reason
  /// when the agent supplied one. Always the final event of a successful
  /// stream.
  case finished(ACPV2StateUpdate)
}

/// Aggregated outcome of a v2 prompt turn (`promptTurnCollecting`).
public struct ACPV2TurnResult: Equatable, Sendable {
  /// Id of the inserted user message.
  public var messageId: ACPMessageID
  /// The idle snapshot that ended foreground work.
  public var finalState: ACPV2StateUpdate
  /// Agent message text, joined across messages in first-seen order after
  /// applying upsert semantics (whole-message updates replace, chunks append).
  public var messageText: String
  /// Agent thought text, assembled the same way.
  public var thoughtText: String
  /// Every update received during the turn, in order.
  public var updates: [ACPV2SessionUpdate]

  /// The stop reason, or `nil` when the agent reported idle without one.
  public var stopReason: ACPV2StopReason? { finalState.stopReason }

  public init(
    messageId: ACPMessageID,
    finalState: ACPV2StateUpdate,
    messageText: String = "",
    thoughtText: String = "",
    updates: [ACPV2SessionUpdate] = []
  ) {
    self.messageId = messageId
    self.finalState = finalState
    self.messageText = messageText
    self.thoughtText = thoughtText
    self.updates = updates
  }
}

/// Accumulates the text of messages of one type, keyed by `messageId`,
/// applying v2 upsert semantics. Text blocks of one message are joined
/// without a separator, as the spec asks for adjacent text blocks.
public struct ACPV2MessageTextAccumulator: Equatable, Sendable {
  private var order: [ACPMessageID] = []
  private var texts: [ACPMessageID: String] = [:]

  public init() {}

  /// Appends a chunk; a chunk for an unseen id creates the message.
  public mutating func append(_ chunk: ACPV2ContentChunk) {
    register(chunk.messageId)
    if case .text(let content) = chunk.content {
      texts[chunk.messageId, default: ""] += content.text
    }
  }

  /// Applies a whole-message upsert: omitted content is unchanged, `null`
  /// or `[]` clears, an array replaces.
  public mutating func apply(_ message: ACPV2Message) {
    register(message.messageId)
    switch message.content {
    case .unchanged:
      break
    case .clear:
      texts[message.messageId] = ""
    case .set(let blocks):
      texts[message.messageId] = blocks.reduce(into: "") { text, block in
        if case .text(let content) = block { text += content.text }
      }
    }
  }

  private mutating func register(_ messageId: ACPMessageID) {
    guard texts[messageId] == nil else { return }
    order.append(messageId)
    texts[messageId] = ""
  }

  /// Text of one message.
  public func text(of messageId: ACPMessageID) -> String? {
    texts[messageId]
  }

  /// Message texts in first-seen order.
  public var messages: [(messageId: ACPMessageID, text: String)] {
    order.map { ($0, texts[$0] ?? "") }
  }

  /// All messages' text concatenated in first-seen order.
  public var joinedText: String {
    order.reduce(into: "") { $0 += texts[$1] ?? "" }
  }
}

// MARK: - ACP v2 client API

extension ACPClientConnection {
  /// The protocol version the latest successful initialization selected.
  public var negotiatedVersion: Int? {
    get async { await updateHub.negotiatedVersion }
  }

  /// Initializes the connection requesting protocol version 2 and accepts
  /// the agent's selection: v2 when it speaks it, otherwise v1.
  ///
  /// A v1-only agent reads the v2 request without v1's `clientInfo` and
  /// `clientCapabilities`; pass `v1Fallback` to repeat `initialize` in the
  /// v1 shape when the agent selects v1 (agents implementing only v1 may
  /// not accept the repeat, in which case the first selection stands).
  public func negotiate(
    _ request: ACPV2InitializeRequest, v1Fallback: ACPInitializeRequest? = nil
  ) async throws -> ACPNegotiatedInitialization {
    let raw: ACPJSONValue = try await connection.sendRequest(method: ACPMethod.initialize, params: request)
    guard let selected = raw["protocolVersion"]?.integerValue else {
      throw ACPError.internalError("initialize result has no protocolVersion")
    }
    let data = try ACPWireCoding.encoder.encode(raw)
    switch selected {
    case ACPProtocol.versionV2:
      let response = try ACPWireCoding.decoder.decode(ACPV2InitializeResponse.self, from: data)
      await updateHub.setNegotiatedVersion(selected)
      return .v2(response)
    case ACPProtocol.versionV1:
      var response = try ACPWireCoding.decoder.decode(ACPInitializeResponse.self, from: data)
      await updateHub.setNegotiatedVersion(selected)
      if let v1Fallback,
         let repeated: ACPInitializeResponse = try? await connection.sendRequest(
          method: ACPMethod.initialize, params: v1Fallback
         ), repeated.protocolVersion == ACPProtocol.versionV1 {
        response = repeated
      }
      return .v1(response)
    default:
      // The agent selected a version this client does not implement.
      throw ACPError.unsupportedProtocolVersion(requested: request.protocolVersion, supported: ACPProtocol.supportedVersions)
    }
  }

  public func newSessionV2(_ request: ACPV2NewSessionRequest) async throws -> ACPV2NewSessionResponse {
    try await connection.sendRequest(method: ACPMethod.sessionNew, params: request)
  }

  /// Resumes a session. With `replayFrom: .start` the agent replays its
  /// retained history as ordinary updates and marks the end with
  /// `replay_complete` before responding; a current `state_update`
  /// always precedes the response.
  public func resumeSessionV2(_ request: ACPV2ResumeSessionRequest) async throws -> ACPV2ResumeSessionResponse {
    try await connection.sendRequest(method: ACPMethod.sessionResume, params: request)
  }

  /// Lists the sessions the agent knows about (same shape in v1 and v2).
  public func listSessions(_ request: ACPListSessionsRequest = ACPListSessionsRequest()) async throws -> ACPListSessionsResponse {
    try await connection.sendRequest(method: ACPMethod.sessionList, params: request)
  }

  /// Closes an active session. A `-32002` response is treated as success,
  /// since closing is idempotent.
  public func closeSession(sessionId: ACPSessionID) async throws {
    try await sessionRequest(ACPMethod.sessionClose, sessionId: sessionId)
  }

  /// Deletes a session (requires the `delete` session capability). A
  /// `-32002` response is treated as a successful delete.
  public func deleteSession(sessionId: ACPSessionID) async throws {
    try await sessionRequest(ACPMethod.sessionDelete, sessionId: sessionId)
  }

  private func sessionRequest(_ method: String, sessionId: ACPSessionID) async throws {
    do {
      let _: ACPEmptyResult = try await connection.sendRequest(
        method: method, params: ACPSessionRequest(sessionId: sessionId)
      )
    } catch let error as ACPError where error.code == ACPErrorCode.resourceNotFound {
      return
    }
  }

  /// Sets a config option on a v2 session and returns the complete
  /// updated option list.
  public func setConfigOptionV2(
    sessionId: ACPSessionID, configId: String, value: ACPSessionConfigValue
  ) async throws -> [ACPSessionConfigOption] {
    let response: ACPSetSessionConfigOptionResponse = try await connection.sendRequest(
      method: ACPMethod.sessionSetConfigOption,
      params: ACPSetSessionConfigOptionRequest(sessionId: sessionId, configId: configId, value: value)
    )
    return response.configOptions
  }

  /// Sends a v2 prompt and returns once the agent inserted the user
  /// message. This is not turn completion: watch `state_update` (or use
  /// `promptTurn`) for the idle state that ends foreground work.
  public func promptV2(_ request: ACPV2PromptRequest) async throws -> ACPV2PromptResponse {
    try await connection.sendRequest(method: ACPMethod.sessionPrompt, params: request)
  }

  /// `auth/login` for an advertised protocol-driven auth method.
  public func login(methodId: String) async throws {
    let _: ACPEmptyResult = try await connection.sendRequest(
      method: ACPMethod.authLogin, params: ACPLoginRequest(methodId: methodId)
    )
  }

  /// `auth/logout`. Only valid when the agent returned a non-empty `authMethods`.
  public func logout() async throws {
    let _: ACPEmptyResult = try await connection.sendRequest(
      method: ACPMethod.authLogout, params: ACPEmptyResult()
    )
  }

  /// Stops one tool call that currently advertises `capabilities.cancel`.
  public func cancelToolCall(sessionId: ACPSessionID, toolCallId: ACPToolCallID) async throws {
    let _: ACPEmptyResult = try await connection.sendRequest(
      method: ACPMethod.toolCallCancel,
      params: ACPV2CancelToolCallRequest(sessionId: sessionId, toolCallId: toolCallId)
    )
  }

  /// Stops the process of one terminal that currently advertises `capabilities.cancel`.
  public func cancelTerminal(sessionId: ACPSessionID, terminalId: String) async throws {
    let _: ACPEmptyResult = try await connection.sendRequest(
      method: ACPMethod.terminalCancel,
      params: ACPV2CancelTerminalRequest(sessionId: sessionId, terminalId: terminalId)
    )
  }

  /// Streams every v2 update for a session until the stream is abandoned,
  /// including background updates that arrive while the session is idle.
  public func sessionUpdates(sessionId: ACPSessionID) -> AsyncStream<ACPV2SessionUpdate> {
    let hub = updateHub
    return AsyncStream(ACPV2SessionUpdate.self) { continuation in
      let subscription = Task {
        await hub.subscribeV2(sessionId: sessionId) { continuation.yield($0) }
      }
      continuation.onTermination = { _ in
        Task { await hub.unsubscribe(await subscription.value) }
      }
    }
  }

  /// Runs one v2 prompt as a turn: sends the prompt, streams the session's
  /// updates, and finishes with the idle `state_update` that ends the
  /// foreground work the prompt started.
  ///
  /// The prompt response only acknowledges insertion, so completion is
  /// taken from the first idle snapshot that follows evidence of this
  /// turn (the acknowledgment or an active state), never from the
  /// response or from message content. A failure after insertion arrives
  /// as `.finished` with `stopReason == .error`; the stream throws only
  /// when the message was never inserted.
  ///
  /// Intended for one prompt at a time per session. Abandoning the stream
  /// does not stop the agent's work; send `cancel(sessionId:)` for that.
  public func promptTurn(_ request: ACPV2PromptRequest) -> AsyncThrowingStream<ACPV2TurnEvent, any Error> {
    let hub = updateHub
    let connection = connection
    return AsyncThrowingStream(ACPV2TurnEvent.self) { continuation in
      let tracker = ACPV2TurnTracker(continuation: continuation)
      let task = Task {
        let token = await hub.subscribeV2(sessionId: request.sessionId) { tracker.receive($0) }
        do {
          let response: ACPV2PromptResponse = try await connection.sendRequest(
            method: ACPMethod.sessionPrompt, params: request
          )
          tracker.accepted(response)
          await tracker.waitUntilFinished()
        } catch {
          tracker.fail(error)
        }
        await hub.unsubscribe(token)
      }
      continuation.onTermination = { termination in
        if case .cancelled = termination { task.cancel() }
        tracker.abandon()
      }
    }
  }

  /// Runs one v2 prompt turn and returns the aggregated result.
  public func promptTurnCollecting(_ request: ACPV2PromptRequest) async throws -> ACPV2TurnResult {
    var messageId: ACPMessageID?
    var messages = ACPV2MessageTextAccumulator()
    var thoughts = ACPV2MessageTextAccumulator()
    var updates: [ACPV2SessionUpdate] = []
    for try await event in promptTurn(request) {
      switch event {
      case .accepted(let response):
        messageId = response.messageId
      case .update(let update):
        updates.append(update)
        switch update {
        case .agentMessageChunk(let chunk): messages.append(chunk)
        case .agentMessage(let message): messages.apply(message)
        case .agentThoughtChunk(let chunk): thoughts.append(chunk)
        case .agentThought(let message): thoughts.apply(message)
        default: break
        }
      case .finished(let state):
        guard let messageId else { break }
        return ACPV2TurnResult(
          messageId: messageId,
          finalState: state,
          messageText: messages.joinedText,
          thoughtText: thoughts.joinedText,
          updates: updates
        )
      }
    }
    throw ACPError.internalError("prompt turn ended without an idle state update")
  }
}

/// Decides when a v2 turn is complete from the interleaving of the prompt
/// response and the session's state snapshots.
///
/// The stream's continuation is only touched outside the lock: finishing
/// it runs the termination handler synchronously, which calls back into
/// `abandon()`.
private final class ACPV2TurnTracker: @unchecked Sendable {
  private let lock = NSLock()
  private let continuation: AsyncThrowingStream<ACPV2TurnEvent, any Error>.Continuation
  private var accepted = false
  private var sawActiveState = false
  private var finalState: ACPV2StateUpdate?
  private var finished = false
  private var waiter: CheckedContinuation<Void, Never>?

  init(continuation: AsyncThrowingStream<ACPV2TurnEvent, any Error>.Continuation) {
    self.continuation = continuation
  }

  /// Marks the turn finished and hands back the suspended waiter, if any.
  /// Call with the lock held.
  private func finishLocked() -> CheckedContinuation<Void, Never>? {
    finished = true
    defer { waiter = nil }
    return waiter
  }

  /// Both halves are required: the acknowledgment (so the caller learns the
  /// `messageId`) and the idle snapshot ending the work. Call with the lock held.
  private func completionLocked() -> ACPV2StateUpdate? {
    guard accepted, let finalState else { return nil }
    return finalState
  }

  func receive(_ update: ACPV2SessionUpdate) {
    var events: [ACPV2TurnEvent] = []
    var resumed: CheckedContinuation<Void, Never>?
    var completed = false
    lock.withLock {
      guard !finished else { return }
      events.append(.update(update))
      guard case .stateUpdate(let state) = update else { return }
      if state.isActive {
        sawActiveState = true
        // A newer active state supersedes an idle seen earlier.
        finalState = nil
      } else if state.state == .idle, accepted || sawActiveState {
        finalState = state
      }
      if let final = completionLocked() {
        events.append(.finished(final))
        resumed = finishLocked()
        completed = true
      }
    }
    deliver(events, completed: completed, resumed: resumed)
  }

  func accepted(_ response: ACPV2PromptResponse) {
    var events: [ACPV2TurnEvent] = []
    var resumed: CheckedContinuation<Void, Never>?
    var completed = false
    lock.withLock {
      guard !finished else { return }
      accepted = true
      events.append(.accepted(response))
      if let final = completionLocked() {
        events.append(.finished(final))
        resumed = finishLocked()
        completed = true
      }
    }
    deliver(events, completed: completed, resumed: resumed)
  }

  private func deliver(
    _ events: [ACPV2TurnEvent], completed: Bool, resumed: CheckedContinuation<Void, Never>?
  ) {
    for event in events {
      continuation.yield(event)
    }
    if completed {
      continuation.finish()
    }
    resumed?.resume()
  }

  func fail(_ error: any Error) {
    let resumed = lock.withLock { () -> CheckedContinuation<Void, Never>?? in
      guard !finished else { return nil }
      return .some(finishLocked())
    }
    guard let resumed else { return }
    continuation.finish(throwing: error)
    resumed?.resume()
  }

  func abandon() {
    let resumed = lock.withLock { finishLocked() }
    resumed?.resume()
  }

  func waitUntilFinished() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let alreadyFinished = lock.withLock { () -> Bool in
        if finished { return true }
        waiter = continuation
        return false
      }
      if alreadyFinished {
        continuation.resume()
      }
    }
  }
}
