import ACP
import AgentGateway
import Foundation

// ACP protocol version 2 for the gateway agent.
//
// v2 moves turn progress out of the `session/prompt` request: the request
// answers once the user message is inserted, and everything after that
// (`running`, output, `idle` with a stop reason) is reported as
// `session/update` notifications. All updates for a session are sent
// synchronously from this actor, so their wire order is the actor's order.
extension GatewayACPAgent: ACPV2Agent {
  public func initialize(_ request: ACPV2InitializeRequest) async throws -> ACPV2InitializeResponse {
    ACPV2InitializeResponse(
      protocolVersion: ACPProtocol.versionV2,
      info: ACPImplementation(name: "agent-gateway", version: Version.current, title: "Agent Gateway"),
      capabilities: ACPV2AgentCapabilities(
        session: ACPV2SessionCapabilities(
          // Text and resource links are the baseline.
          prompt: ACPV2PromptCapabilities(image: ACPSupportMarker(), embeddedContext: ACPSupportMarker()),
          // Stdio MCP servers are handed to the vendor CLI, so the
          // transport is advertised only when the configured vendor takes
          // them. With no fixed vendor, or one that cannot connect, no
          // transport is advertised and servers are rejected.
          mcp: defaults.vendor?.connectsToMCPServers == true
            ? ACPV2MCPCapabilities(stdio: ACPSupportMarker()) : nil,
          delete: ACPSupportMarker(),
          systemPrompt: ACPSystemPromptCapabilities()
        )
      )
    )
  }

  public func newSession(
    _ request: ACPV2NewSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPV2NewSessionResponse {
    let session = try await createSession(
      cwd: request.cwd, meta: request.meta, systemPrompt: request.systemPrompt,
      mcpServers: try gatewayMCPServers(v2: request.mcpServers), requiresMCPSupport: true,
      connection: connection
    )
    return ACPV2NewSessionResponse(
      sessionId: session.sessionId,
      configOptions: session.configOptions,
      meta: sessionMeta(session, key: GatewayACPMetaKey.v2)
    )
  }

  public func resumeSession(
    _ request: ACPV2ResumeSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPV2ResumeSessionResponse {
    let mcpServers = try gatewayMCPServers(v2: request.mcpServers)
    if case .other(let cursor)? = request.replayFrom {
      // Never substitute another replay mode for an unsupported cursor.
      throw ACPError.invalidParams(
        "unsupported replayFrom type '\(cursor["type"]?.stringValue ?? "unknown")'"
      )
    }
    let session = try reactivateSession(
      request.sessionId, cwd: request.cwd, systemPrompt: request.systemPrompt,
      mcpServers: mcpServers, requiresMCPSupport: true, connection: connection
    )
    let sessionId = session.sessionId
    // Everything below is sent without suspension, so no live update can
    // interleave with the replay or precede `replay_complete`.
    if request.replayFrom == .start {
      for message in session.history {
        connection.sendUpdate(replayUpdate(message), sessionId: sessionId)
      }
      if let turn = session.turn {
        // Work still running is cut here: what has streamed so far is
        // history, and later chunks append to the same message ids.
        if !turn.thoughtText.isEmpty {
          connection.sendUpdate(
            .agentThought(ACPV2Message(messageId: turn.thoughtMessageId, content: [.text(turn.thoughtText)])),
            sessionId: sessionId
          )
        }
        if !turn.agentText.isEmpty {
          connection.sendUpdate(
            .agentMessage(ACPV2Message(messageId: turn.agentMessageId, content: [.text(turn.agentText)])),
            sessionId: sessionId
          )
        }
      }
      connection.sendUpdate(.replayComplete, sessionId: sessionId)
    }
    // Current-state synchronization: a snapshot, not a new completion.
    connection.sendUpdate(
      .stateUpdate(ACPV2StateUpdate(state: session.turn == nil ? .idle : .running)), sessionId: sessionId
    )
    connection.sendUpdate(
      .sessionInfoUpdate(ACPV2SessionInfoUpdate(
        title: session.title.map { .set($0) } ?? .unchanged,
        updatedAt: .set(gatewayTimestamp(session.updatedAt))
      )),
      sessionId: sessionId
    )
    return ACPV2ResumeSessionResponse(configOptions: session.configOptions)
  }

  private func replayUpdate(_ message: GatewayHistoryMessage) -> ACPV2SessionUpdate {
    let upsert = ACPV2Message(messageId: message.messageId, content: message.content)
    switch message.role {
    case .user: return .userMessage(upsert)
    case .agent: return .agentMessage(upsert)
    case .thought: return .agentThought(upsert)
    }
  }

  public func listSessions(
    _ request: ACPListSessionsRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPListSessionsResponse {
    try sessionList(request)
  }

  public func setConfigOption(
    _ request: ACPSetSessionConfigOptionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPSetSessionConfigOptionResponse {
    let before = sessions[request.sessionId]?.configOptions
    let options = try applyConfigOption(request)
    if options != before {
      // Other views of the session learn about the change the same way.
      connection.sendUpdate(.configOptionUpdate(options), sessionId: request.sessionId)
    }
    return ACPSetSessionConfigOptionResponse(configOptions: options)
  }

  // MARK: - Prompt lifecycle

  public func submitPrompt(
    _ request: ACPV2PromptRequest, connection: ACPAgentSideConnection
  ) async -> ACPV2PromptSubmission {
    let sessionId = request.sessionId
    guard let session = sessions[sessionId], session.isActive else {
      return .rejected(.sessionNotFound(sessionId))
    }
    guard !session.isClosing else {
      return .rejected(.requestCancelled("session is closing"))
    }
    if let key = request.idempotencyKey, !(1...255).contains(key.count) {
      return .rejected(.invalidParams("idempotencyKey must be a string of 1 to 255 characters"))
    }
    do {
      // Content the gateway cannot handle is rejected before insertion.
      _ = try gatewayPromptInput(request.prompt)
    } catch {
      return .rejected(gatewayACPError(error))
    }
    if let key = request.idempotencyKey {
      // A retry of an inserted submission returns the original message
      // without a second insertion or a second round of work.
      if let messageId = session.promptKeys[key] {
        return .inserted(messageId: messageId)
      }
      // A retry of a prompt still held shares that prompt's outcome.
      if let held = session.heldPrompts.first(where: { $0.idempotencyKey == key }) {
        return submission(for: held, sessionId: sessionId)
      }
    }
    if session.turn == nil, session.heldPrompts.isEmpty {
      let messageId = insert(prompt: request.prompt, idempotencyKey: request.idempotencyKey, sessionId: sessionId)
      startTurn(sessionId: sessionId, prompt: request.prompt)
      return .inserted(messageId: messageId)
    }
    // Foreground work is active (or stopping): hold the prompt and insert
    // it, in arrival order, when that work has reported idle.
    let held = GatewayHeldPrompt(prompt: request.prompt, idempotencyKey: request.idempotencyKey)
    sessions[sessionId]?.heldPrompts.append(held)
    return submission(for: held, sessionId: sessionId)
  }

  private func submission(for held: GatewayHeldPrompt, sessionId: ACPSessionID) -> ACPV2PromptSubmission {
    ACPV2PromptSubmission { [self] in
      let result = await withTaskCancellationHandler {
        await held.wait()
      } onCancel: {
        // `$/cancel_request` for a prompt that is not inserted yet
        // withdraws it; an inserted prompt still answers its messageId.
        Task { await self.withdraw(held, sessionId: sessionId) }
      }
      return ACPV2PromptResponse(messageId: try result.get())
    }
  }

  private func withdraw(_ held: GatewayHeldPrompt, sessionId: ACPSessionID) {
    guard let index = sessions[sessionId]?.heldPrompts.firstIndex(where: { $0.id == held.id }) else { return }
    sessions[sessionId]?.heldPrompts.remove(at: index)
    held.resolve(.failure(.requestCancelled()))
  }

  /// Inserts a user message into the conversation and reports it.
  private func insert(
    prompt: [ACPContentBlock], idempotencyKey: String?, sessionId: ACPSessionID
  ) -> ACPMessageID {
    let messageId = gatewayNewMessageId()
    let titled = sessions[sessionId]?.retain(
      GatewayHistoryMessage(role: .user, messageId: messageId, content: prompt)
    ) ?? false
    if let idempotencyKey {
      sessions[sessionId]?.promptKeys[idempotencyKey] = messageId
    }
    send(.userMessage(ACPV2Message(messageId: messageId, content: prompt)), sessionId: sessionId)
    if titled, let session = sessions[sessionId] {
      send(
        .sessionInfoUpdate(ACPV2SessionInfoUpdate(
          title: session.title.map { .set($0) } ?? .unchanged,
          updatedAt: .set(gatewayTimestamp(session.updatedAt))
        )),
        sessionId: sessionId
      )
    }
    return messageId
  }

  private func send(_ update: ACPV2SessionUpdate, sessionId: ACPSessionID) {
    sessions[sessionId]?.connection?.sendUpdate(update, sessionId: sessionId)
  }

  /// Starts the foreground work an inserted prompt asks for.
  private func startTurn(sessionId: ACPSessionID, prompt: [ACPContentBlock]) {
    sessions[sessionId]?.turnCount += 1
    guard let session = sessions[sessionId] else { return }
    send(.stateUpdate(.running()), sessionId: sessionId)
    let (stream, continuation) = AsyncStream.makeStream(of: GatewayStreamChunk.self)
    let bridge = GatewayACPStreamBridge(scope: gatewayActivityScope(turn: session.turnCount)) {
      continuation.yield($0)
    }
    let executor = executor
    let params = Result { try executeParams(for: session, input: try gatewayPromptInput(prompt)) }
    let task = Task { [self] in
      let pump = Task { [self] in
        for await chunk in stream {
          deliver(chunk, sessionId: sessionId)
        }
      }
      let outcome: Result<GatewayExecuteResult, any Error>
      do {
        outcome = .success(try await executor.execute(try params.get(), emit: bridge.emitter))
      } catch {
        outcome = .failure(error)
      }
      // However the work ended, no tool call is left looking like it is
      // still running: the vendor execution is over.
      switch outcome {
      case .success: bridge.settleOpenToolCalls(.completed)
      case .failure: bridge.settleOpenToolCalls(.failed)
      }
      continuation.finish()
      // Pending output is delivered before the idle update.
      await pump.value
      finishTurn(sessionId: sessionId, outcome: outcome)
    }
    sessions[sessionId]?.turn = GatewayForegroundTurn(
      task: task, agentMessageId: gatewayNewMessageId(), thoughtMessageId: gatewayNewMessageId()
    )
  }

  private func deliver(_ chunk: GatewayStreamChunk, sessionId: ACPSessionID) {
    guard let turn = sessions[sessionId]?.turn else { return }
    switch chunk {
    case .message(let text):
      sessions[sessionId]?.turn?.agentText += text
      send(
        .agentMessageChunk(ACPV2ContentChunk(messageId: turn.agentMessageId, content: .text(text))),
        sessionId: sessionId
      )
    case .thought(let text):
      sessions[sessionId]?.turn?.thoughtText += text
      send(
        .agentThoughtChunk(ACPV2ContentChunk(messageId: turn.thoughtMessageId, content: .text(text))),
        sessionId: sessionId
      )
    case .toolCall(let toolCall):
      send(.toolCallUpdate(toolCall.v2Update), sessionId: sessionId)
    case .plan(let plan):
      send(plan.v2Update, sessionId: sessionId)
    case .usage(let usage):
      sessions[sessionId]?.turn?.costUSD = usage.costUSD ?? turn.costUSD
      // Reported once the vendor has said how large the context window is.
      guard let update = usage.v2Update(priorCostUSD: sessions[sessionId]?.costUSD ?? 0) else { return }
      send(update, sessionId: sessionId)
    }
  }

  /// Ends foreground work: retains its output, reports `idle` with the
  /// stop reason, then starts the next held prompt, if any.
  private func finishTurn(sessionId: ACPSessionID, outcome: Result<GatewayExecuteResult, any Error>) {
    guard var turn = sessions[sessionId]?.turn else { return }
    let state: ACPV2StateUpdate
    switch outcome {
    case .success(let result):
      if turn.agentText.isEmpty, !result.text.isEmpty {
        // The vendor produced a result without streaming it.
        turn.agentText = result.text
        send(
          .agentMessage(ACPV2Message(messageId: turn.agentMessageId, content: [.text(result.text)])),
          sessionId: sessionId
        )
      }
      if let vendorSessionId = result.sessionId {
        sessions[sessionId]?.vendorSessionId = vendorSessionId
      }
      state = .idle(stopReason: .endTurn, meta: gatewayResultMeta(result, key: GatewayACPMetaKey.v2))
    case .failure(let error):
      if turn.cancelRequested || error is CancellationError {
        // Errors raised while aborting cancelled work are a cancellation,
        // not a failure.
        state = .idle(stopReason: .cancelled)
      } else {
        state = .idle(stopReason: .error, error: gatewayACPError(error))
      }
    }
    retainOutput(
      sessionId: sessionId, thought: turn.thoughtText, message: turn.agentText,
      thoughtMessageId: turn.thoughtMessageId, agentMessageId: turn.agentMessageId
    )
    sessions[sessionId]?.costUSD += turn.costUSD ?? 0
    sessions[sessionId]?.turn = nil
    send(.stateUpdate(state), sessionId: sessionId)
    for waiter in turn.endWaiters {
      waiter.resume()
    }
    startNextHeldPrompt(sessionId: sessionId)
  }

  private func startNextHeldPrompt(sessionId: ACPSessionID) {
    guard let session = sessions[sessionId], session.isActive, !session.isClosing,
          session.turn == nil, let held = session.heldPrompts.first else { return }
    sessions[sessionId]?.heldPrompts.removeFirst()
    let messageId = insert(prompt: held.prompt, idempotencyKey: held.idempotencyKey, sessionId: sessionId)
    held.resolve(.success(messageId))
    startTurn(sessionId: sessionId, prompt: held.prompt)
  }

  /// Answers every prompt not inserted yet with `-32800`.
  private func dropHeldPrompts(sessionId: ACPSessionID) {
    guard let held = sessions[sessionId]?.heldPrompts, !held.isEmpty else { return }
    sessions[sessionId]?.heldPrompts.removeAll()
    for prompt in held {
      prompt.resolve(.failure(.requestCancelled()))
    }
  }

  public func cancel(_ notification: ACPCancelNotification, connection: ACPAgentSideConnection) async {
    let sessionId = notification.sessionId
    // Ignored for sessions that are not active on the connection.
    guard let session = sessions[sessionId], session.isActive else { return }
    dropHeldPrompts(sessionId: sessionId)
    // With no foreground work there is nothing to confirm: no extra idle.
    guard let turn = session.turn else { return }
    sessions[sessionId]?.turn?.cancelRequested = true
    turn.task.cancel()
  }

  /// Cancels foreground work and waits until its final updates and the
  /// idle `cancelled` state have been sent.
  private func stopForegroundWork(sessionId: ACPSessionID) async {
    dropHeldPrompts(sessionId: sessionId)
    guard let turn = sessions[sessionId]?.turn else { return }
    sessions[sessionId]?.turn?.cancelRequested = true
    turn.task.cancel()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      sessions[sessionId]?.turn?.endWaiters.append(continuation)
    }
  }

  public func closeSession(_ request: ACPSessionRequest, connection: ACPAgentSideConnection) async throws {
    let sessionId = request.sessionId
    // Closing is idempotent: unknown and already closed sessions succeed.
    guard let session = sessions[sessionId], session.isActive else { return }
    sessions[sessionId]?.isClosing = true
    await stopForegroundWork(sessionId: sessionId)
    sessions[sessionId]?.isActive = false
    sessions[sessionId]?.isClosing = false
    // After the close response nothing more is sent for the session.
    sessions[sessionId]?.connection = nil
  }

  public func deleteSession(_ request: ACPSessionRequest, connection: ACPAgentSideConnection) async throws {
    // Deleting cancels ongoing work as if the session were closed first;
    // deleting a session that does not exist succeeds.
    try await closeSession(request, connection: connection)
    sessions[request.sessionId] = nil
  }
}
