import ACP
import Foundation
import Testing
@testable import AgentGateway
@testable import AgentGatewayAppCore

// MARK: - Fixtures

/// Emits its steps, then returns; optionally fails instead.
private struct V2ScriptedExecutor: GatewayExecuting {
  var deltas: [String] = ["Hel", "lo"]
  var thinking: [String] = []
  var resultText = "Hello"
  var failure: GatewayRPCError?

  func execute(
    _ params: GatewayExecuteParams, emit: @escaping GatewayEventEmitter
  ) async throws -> GatewayExecuteResult {
    for text in thinking {
      emit(GatewayEvent(type: "thinking.delta", channel: .thinking, textDelta: text))
    }
    for text in deltas {
      emit(GatewayEvent(type: "assistant.delta", channel: .assistant, textDelta: text))
    }
    if let failure { throw failure }
    return GatewayExecuteResult(
      vendor: params.vendor, model: params.model, text: resultText,
      usage: GatewayUsage(inputTokens: 2, outputTokens: 3, totalTokens: 5), sessionId: "vendor-1"
    )
  }
}

/// Blocks each execution until `release()`; records the prompts it ran.
private actor GatedExecutor: GatewayExecuting {
  private(set) var prompts: [String] = []
  private var gates: [CheckedContinuation<Void, Never>] = []
  private var started: [CheckedContinuation<Void, Never>] = []

  func execute(
    _ params: GatewayExecuteParams, emit: @escaping GatewayEventEmitter
  ) async throws -> GatewayExecuteResult {
    prompts.append(params.prompt)
    emit(GatewayEvent(type: "assistant.delta", channel: .assistant, textDelta: "partial:\(params.prompt)"))
    for waiter in started { waiter.resume() }
    started.removeAll()
    await withTaskCancellationHandler {
      await withCheckedContinuation { gates.append($0) }
    } onCancel: {
      Task { await self.release() }
    }
    try Task.checkCancellation()
    return GatewayExecuteResult(vendor: params.vendor, model: params.model, text: "done:\(params.prompt)")
  }

  func release() {
    for gate in gates { gate.resume() }
    gates.removeAll()
  }

  /// Suspends until `count` executions have started.
  func waitForStart(count: Int) async {
    while prompts.count < count {
      await withCheckedContinuation { started.append($0) }
    }
  }
}

private actor V2Recorder: ACPClientDelegate {
  private(set) var updates: [ACPV2SessionUpdate] = []
  private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  func sessionUpdate(_ notification: ACPSessionNotification) async {}

  func sessionUpdate(_ notification: ACPV2SessionNotification) async {
    updates.append(notification.update)
    let idleCount = idleStates
    waiters.removeAll { waiter in
      guard idleCount >= waiter.count else { return false }
      waiter.continuation.resume()
      return true
    }
  }

  var kinds: [String] { updates.map(\.kind) }

  var states: [ACPV2StateUpdate] {
    updates.compactMap {
      if case .stateUpdate(let state) = $0 { return state }
      return nil
    }
  }

  private var idleStates: Int { states.filter { $0.state == .idle }.count }

  /// Suspends until `count` idle state updates have been recorded.
  func waitForIdle(count: Int = 1) async {
    guard idleStates < count else { return }
    await withCheckedContinuation { waiters.append((count, $0)) }
  }
}

private func makeV2Gateway(
  executor: any GatewayExecuting,
  defaults: GatewayAgentDefaults = GatewayAgentDefaults(vendor: .codex, model: "gpt-5")
) async throws -> (ACPClientConnection, V2Recorder) {
  let recorder = V2Recorder()
  let agent = GatewayACPAgent(defaults: defaults, executor: executor)
  let (client, _) = await ACPClientConnection.inProcess(v1: agent, v2: agent, delegate: recorder)
  let negotiated = try await client.negotiate(
    ACPV2InitializeRequest(info: ACPImplementation(name: "test", version: "1"))
  )
  #expect(negotiated.protocolVersion == ACPProtocol.versionV2)
  return (client, recorder)
}

private func text(_ value: String) -> [ACPContentBlock] { [.text(value)] }

// MARK: - Initialization

@Test func v2InitializeAdvertisesObjectMarkersAndRequiredInfo() async throws {
  let agent = GatewayACPAgent(executor: V2ScriptedExecutor())
  let (client, _) = await ACPClientConnection.inProcess(v1: agent, v2: agent)
  let negotiated = try await client.negotiate(
    ACPV2InitializeRequest(info: ACPImplementation(name: "test", version: "1"))
  )
  guard case .v2(let response) = negotiated else {
    Issue.record("expected v2")
    return
  }
  #expect(response.info.name == "agent-gateway")
  let session = try #require(response.capabilities.session)
  #expect(session.prompt?.image != nil)
  #expect(session.prompt?.embeddedContext != nil)
  #expect(session.prompt?.audio == nil)
  #expect(session.delete != nil)
  #expect(session.systemPrompt != nil)
  // No MCP transport is advertised, and no auth methods.
  #expect(session.mcp == nil)
  #expect(response.authMethods.isEmpty)
  await client.stop()
}

@Test func sameAgentStillServesV1Clients() async throws {
  let agent = GatewayACPAgent(
    defaults: GatewayAgentDefaults(vendor: .codex, model: "gpt-5"), executor: V2ScriptedExecutor()
  )
  let (client, _) = await ACPClientConnection.inProcess(v1: agent, v2: agent)
  let initialized = try await client.initialize()
  #expect(initialized.protocolVersion == ACPProtocol.versionV1)
  #expect(initialized.agentCapabilities.sessionCapabilities.list != nil)
  let session = try await client.newSession(ACPNewSessionRequest(cwd: "/tmp"))
  // v1 keeps the turn inside the prompt request and the legacy _meta key.
  let response = try await client.prompt(ACPPromptRequest(sessionId: session.sessionId, prompt: text("hi")))
  #expect(response.stopReason == .endTurn)
  #expect(response.meta?["agentGateway"]?["resultText"]?.stringValue == "Hello")
  await client.stop()
}

// MARK: - Prompt lifecycle

@Test func v2TurnReportsInsertionRunningOutputAndIdleThroughUpdates() async throws {
  let (client, recorder) = try await makeV2Gateway(
    executor: V2ScriptedExecutor(deltas: ["Hel", "lo"], thinking: ["hmm"])
  )
  let session = try await client.newSessionV2(ACPV2NewSessionRequest(cwd: "/tmp"))
  let turn = try await client.promptTurnCollecting(
    ACPV2PromptRequest(sessionId: session.sessionId, prompt: text("hi"))
  )
  #expect(turn.stopReason == .endTurn)
  #expect(turn.messageText == "Hello")
  #expect(turn.thoughtText == "hmm")

  let updates = await recorder.updates
  #expect(await recorder.kinds == [
    "user_message", "session_info_update", "state_update",
    "agent_thought_chunk", "agent_message_chunk", "agent_message_chunk", "state_update"
  ])
  // The acknowledged user message carries the response's messageId and content.
  guard case .userMessage(let user) = updates[0] else {
    Issue.record("expected the user message acknowledgment first")
    return
  }
  #expect(user.messageId == turn.messageId)
  #expect(user.content == .set(text("hi")))
  // Every chunk of one message shares its messageId.
  let chunkIds = updates.compactMap { update -> String? in
    if case .agentMessageChunk(let chunk) = update { return chunk.messageId }
    return nil
  }
  #expect(Set(chunkIds).count == 1)
  let states = await recorder.states
  #expect(states.map(\.state) == [.running, .idle])
  // Execution details ride the idle update under the namespaced key.
  let meta = gatewayACPMeta(states.last?.meta)
  #expect(states.last?.meta?[GatewayACPMetaKey.v2] != nil)
  #expect(meta?["resultText"]?.stringValue == "Hello")
  #expect(meta?["vendorSessionId"]?.stringValue == "vendor-1")
  #expect(meta?["usage"]?["totalTokens"]?.integerValue == 5)
  await client.stop()
}

@Test func v2FailureAfterInsertionIsAnIdleErrorStateNotAnErrorResponse() async throws {
  let failure = GatewayRPCError(code: -32010, message: "vendor HTTP 500: boom")
  let (client, recorder) = try await makeV2Gateway(executor: V2ScriptedExecutor(deltas: [], failure: failure))
  let session = try await client.newSessionV2(ACPV2NewSessionRequest(cwd: "/tmp"))
  let turn = try await client.promptTurnCollecting(
    ACPV2PromptRequest(sessionId: session.sessionId, prompt: text("hi"))
  )
  #expect(!turn.messageId.isEmpty)
  #expect(turn.stopReason == .error)
  #expect(turn.finalState.error == ACPError(code: -32010, message: "vendor HTTP 500: boom"))
  #expect(await recorder.states.map(\.state) == [.running, .idle])
  await client.stop()
}

@Test func v2PromptRejectedBeforeInsertionGetsAnErrorAndNoUpdates() async throws {
  let (client, recorder) = try await makeV2Gateway(executor: V2ScriptedExecutor())
  let session = try await client.newSessionV2(ACPV2NewSessionRequest(cwd: "/tmp"))
  let rejected: [[ACPContentBlock]] = [
    [],
    [.audio(ACPAudioContent(data: "AAAA", mimeType: "audio/wav"))],
    [.other(.object(["type": .string("_com.example/chart")]))]
  ]
  for prompt in rejected {
    do {
      _ = try await client.promptV2(ACPV2PromptRequest(sessionId: session.sessionId, prompt: prompt))
      Issue.record("expected the prompt to be rejected")
    } catch let error as ACPError {
      #expect(error.code == ACPErrorCode.invalidParams)
    }
  }
  do {
    _ = try await client.promptV2(ACPV2PromptRequest(sessionId: "missing", prompt: text("hi")))
    Issue.record("expected the unknown session to be rejected")
  } catch let error as ACPError {
    #expect(error.code == ACPErrorCode.resourceNotFound)
    #expect(error.data?["sessionId"]?.stringValue == "missing")
  }
  do {
    _ = try await client.promptV2(
      ACPV2PromptRequest(sessionId: session.sessionId, prompt: text("hi"), idempotencyKey: "")
    )
    Issue.record("expected the malformed key to be rejected")
  } catch let error as ACPError {
    #expect(error.code == ACPErrorCode.invalidParams)
  }
  // Nothing was inserted, so nothing was reported.
  #expect(await recorder.updates.isEmpty)
  await client.stop()
}

@Test func v2IdempotencyKeyReturnsTheOriginalMessageWithoutASecondRun() async throws {
  let executor = GatedExecutor()
  let (client, recorder) = try await makeV2Gateway(executor: executor)
  let session = try await client.newSessionV2(ACPV2NewSessionRequest(cwd: "/tmp"))
  let request = ACPV2PromptRequest(sessionId: session.sessionId, prompt: text("once"), idempotencyKey: "key-1")
  let first = try await client.promptV2(request)
  // A retry while the work is still running, and again after it ended.
  let during = try await client.promptV2(request)
  await executor.waitForStart(count: 1)
  await executor.release()
  await recorder.waitForIdle()
  let after = try await client.promptV2(request)
  #expect(during.messageId == first.messageId)
  #expect(after.messageId == first.messageId)
  #expect(await executor.prompts == ["once"])
  #expect(await recorder.kinds.filter { $0 == "user_message" }.count == 1)
  // A different key is a new submission.
  let other = try await client.promptV2(
    ACPV2PromptRequest(sessionId: session.sessionId, prompt: text("once"), idempotencyKey: "key-2")
  )
  #expect(other.messageId != first.messageId)
  await executor.release()
  await client.stop()
}

@Test func v2PromptsDuringActiveWorkAreHeldAndInsertedInArrivalOrder() async throws {
  let executor = GatedExecutor()
  let (client, recorder) = try await makeV2Gateway(executor: executor)
  let session = try await client.newSessionV2(ACPV2NewSessionRequest(cwd: "/tmp"))
  let first = try await client.promptV2(ACPV2PromptRequest(sessionId: session.sessionId, prompt: text("one")))
  await executor.waitForStart(count: 1)
  // Not rejected because work is active: held with the response pending.
  async let second = client.promptV2(ACPV2PromptRequest(sessionId: session.sessionId, prompt: text("two")))
  try await Task.sleep(for: .milliseconds(50))
  #expect(await recorder.kinds.filter { $0 == "user_message" }.count == 1)
  await executor.release()
  let secondResponse = try await second
  #expect(secondResponse.messageId != first.messageId)
  await executor.waitForStart(count: 2)
  await executor.release()
  await recorder.waitForIdle(count: 2)
  #expect(await executor.prompts == ["one", "two"])
  // Two completed intervals have an idle boundary between them.
  #expect(await recorder.states.map(\.state) == [.running, .idle, .running, .idle])
  await client.stop()
}

// MARK: - Cancellation and closing

@Test func v2CancelConfirmsWithIdleCancelledAndDropsHeldPrompts() async throws {
  let executor = GatedExecutor()
  let (client, recorder) = try await makeV2Gateway(executor: executor)
  let session = try await client.newSessionV2(ACPV2NewSessionRequest(cwd: "/tmp"))
  let first = try await client.promptV2(ACPV2PromptRequest(sessionId: session.sessionId, prompt: text("one")))
  #expect(!first.messageId.isEmpty)
  await executor.waitForStart(count: 1)
  async let held = client.promptV2(ACPV2PromptRequest(sessionId: session.sessionId, prompt: text("two")))
  try await Task.sleep(for: .milliseconds(50))
  try await client.cancel(sessionId: session.sessionId)
  // The prompt received before the cancel and not inserted gets -32800.
  do {
    _ = try await held
    Issue.record("expected the held prompt to be dropped")
  } catch let error as ACPError {
    #expect(error.code == ACPErrorCode.requestCancelled)
  }
  await recorder.waitForIdle()
  let states = await recorder.states
  #expect(states.map(\.state) == [.running, .idle])
  #expect(states.last?.stopReason == .cancelled)
  #expect(await executor.prompts == ["one"])
  // Cancelling an idle session needs no further completion update.
  try await client.cancel(sessionId: session.sessionId)
  try await Task.sleep(for: .milliseconds(50))
  #expect(await recorder.states.count == 2)
  await client.stop()
}

@Test func v2CloseFinishesCancelledWorkBeforeRespondingAndIsIdempotent() async throws {
  let executor = GatedExecutor()
  let (client, recorder) = try await makeV2Gateway(executor: executor)
  let session = try await client.newSessionV2(ACPV2NewSessionRequest(cwd: "/tmp"))
  _ = try await client.promptV2(ACPV2PromptRequest(sessionId: session.sessionId, prompt: text("one")))
  await executor.waitForStart(count: 1)
  try await client.closeSession(sessionId: session.sessionId)
  // The idle `cancelled` state was sent before the close response.
  #expect(await recorder.states.last?.stopReason == .cancelled)
  try await client.closeSession(sessionId: session.sessionId)
  try await client.closeSession(sessionId: "never-existed")
  // A closed session is not active: prompts get -32002, but it stays listed.
  do {
    _ = try await client.promptV2(ACPV2PromptRequest(sessionId: session.sessionId, prompt: text("again")))
    Issue.record("expected the closed session to be rejected")
  } catch let error as ACPError {
    #expect(error.code == ACPErrorCode.resourceNotFound)
  }
  #expect(try await client.listSessions().sessions.map(\.sessionId) == [session.sessionId])
  await client.stop()
}

// MARK: - Resume, list, delete, config

@Test func v2ResumeReplaysHistoryThenMarksCompletionAndSynchronizesState() async throws {
  let (client, recorder) = try await makeV2Gateway(executor: V2ScriptedExecutor(thinking: ["hmm"]))
  let session = try await client.newSessionV2(ACPV2NewSessionRequest(cwd: "/work/project"))
  let turn = try await client.promptTurnCollecting(
    ACPV2PromptRequest(sessionId: session.sessionId, prompt: text("first line"))
  )
  try await client.closeSession(sessionId: session.sessionId)
  let before = await recorder.updates.count

  // Without replayFrom: state synchronization only, no history, no marker.
  _ = try await client.resumeSessionV2(ACPV2ResumeSessionRequest(sessionId: session.sessionId, cwd: "/work/project/"))
  var resumed = Array(await recorder.updates.dropFirst(before))
  #expect(resumed.map(\.kind) == ["state_update", "session_info_update"])

  let mark = await recorder.updates.count
  _ = try await client.resumeSessionV2(
    ACPV2ResumeSessionRequest(sessionId: session.sessionId, cwd: "/work/project", replayFrom: .start)
  )
  resumed = Array(await recorder.updates.dropFirst(mark))
  #expect(resumed.map(\.kind) == [
    "user_message", "agent_thought", "agent_message", "replay_complete", "state_update", "session_info_update"
  ])
  // The retained user message keeps the id the prompt response returned.
  if case .userMessage(let user) = resumed[0] {
    #expect(user.messageId == turn.messageId)
  }
  if case .agentMessage(let agent) = resumed[2] {
    #expect(agent.content == .set(text("Hello")))
  }
  // The snapshot is current state, not a replayed completion.
  if case .stateUpdate(let state) = resumed[4] {
    #expect(state.state == .idle)
    #expect(state.stopReason == nil)
  }
  if case .sessionInfoUpdate(let info) = resumed[5] {
    #expect(info.title == .set("first line"))
  }

  // Unsupported cursors and mismatched directories are rejected, not ignored.
  for request in [
    ACPV2ResumeSessionRequest(
      sessionId: session.sessionId, cwd: "/work/project", replayFrom: .other(.object(["type": .string("_point")]))
    ),
    ACPV2ResumeSessionRequest(sessionId: session.sessionId, cwd: "/elsewhere")
  ] {
    do {
      _ = try await client.resumeSessionV2(request)
      Issue.record("expected the resume to be rejected")
    } catch let error as ACPError {
      #expect(error.code == ACPErrorCode.invalidParams)
    }
  }
  do {
    _ = try await client.resumeSessionV2(ACPV2ResumeSessionRequest(sessionId: "missing", cwd: "/work/project"))
    Issue.record("expected the unknown session to be rejected")
  } catch let error as ACPError {
    #expect(error.code == ACPErrorCode.resourceNotFound)
  }
  await client.stop()
}

@Test func v2ListFiltersByDirectoryAndDeleteRemovesSessions() async throws {
  let (client, _) = try await makeV2Gateway(executor: V2ScriptedExecutor())
  let first = try await client.newSessionV2(ACPV2NewSessionRequest(cwd: "/work/a"))
  let second = try await client.newSessionV2(ACPV2NewSessionRequest(cwd: "/work/b"))
  #expect(Set(try await client.listSessions().sessions.map(\.sessionId)) == [first.sessionId, second.sessionId])
  let filtered = try await client.listSessions(ACPListSessionsRequest(cwd: "/work/a/"))
  #expect(filtered.sessions.map(\.sessionId) == [first.sessionId])
  #expect(filtered.nextCursor == nil)
  for request in [ACPListSessionsRequest(cwd: "relative"), ACPListSessionsRequest(cursor: "never-issued")] {
    do {
      _ = try await client.listSessions(request)
      Issue.record("expected the list request to be rejected")
    } catch let error as ACPError {
      #expect(error.code == ACPErrorCode.invalidParams)
    }
  }
  try await client.deleteSession(sessionId: first.sessionId)
  try await client.deleteSession(sessionId: first.sessionId)
  #expect(try await client.listSessions().sessions.map(\.sessionId) == [second.sessionId])
  do {
    _ = try await client.resumeSessionV2(ACPV2ResumeSessionRequest(sessionId: first.sessionId, cwd: "/work/a"))
    Issue.record("expected the deleted session to be gone")
  } catch let error as ACPError {
    #expect(error.code == ACPErrorCode.resourceNotFound)
  }
  await client.stop()
}

@Test func v2SessionSetupValidatesDirectoriesServersAndSystemPrompt() async throws {
  let (client, _) = try await makeV2Gateway(executor: V2ScriptedExecutor())
  let invalid: [ACPV2NewSessionRequest] = [
    ACPV2NewSessionRequest(cwd: "relative/path"),
    // No MCP transport is advertised, so any server is unsupported.
    ACPV2NewSessionRequest(cwd: "/tmp", mcpServers: [.stdio(.init(name: "fs", command: "/bin/mcp"))]),
    ACPV2NewSessionRequest(cwd: "/tmp", systemPrompt: ACPSystemPrompt(mode: "override", content: text("x"))),
    ACPV2NewSessionRequest(cwd: "/tmp", systemPrompt: ACPSystemPrompt(content: [])),
    ACPV2NewSessionRequest(
      cwd: "/tmp",
      systemPrompt: ACPSystemPrompt(content: [.image(ACPImageContent(data: "AAAA", mimeType: "image/png"))])
    )
  ]
  for request in invalid {
    do {
      _ = try await client.newSessionV2(request)
      Issue.record("expected session/new to be rejected")
    } catch let error as ACPError {
      #expect(error.code == ACPErrorCode.invalidParams)
    }
  }
  // A rejected setup creates no session.
  #expect(try await client.listSessions().sessions.isEmpty)
  await client.stop()
}

private actor PromptCapturingExecutor: GatewayExecuting, GatewayModelListing {
  private(set) var executions: [GatewayExecuteParams] = []

  func execute(
    _ params: GatewayExecuteParams, emit: @escaping GatewayEventEmitter
  ) async throws -> GatewayExecuteResult {
    executions.append(params)
    return GatewayExecuteResult(vendor: params.vendor, model: params.model, text: "unstreamed")
  }

  func models(_ params: GatewayModelCatalogParams) async throws -> GatewayModelCatalogResult {
    GatewayModelCatalogResult(vendor: params.vendor, models: [
      GatewayModelInfo(modelId: "gpt-5"), GatewayModelInfo(modelId: "gpt-5-mini", name: "GPT-5 mini")
    ])
  }
}

@Test func v2ModelIsAConfigOptionAndSystemPromptIsAppended() async throws {
  let executor = PromptCapturingExecutor()
  let (client, recorder) = try await makeV2Gateway(
    executor: executor,
    defaults: GatewayAgentDefaults(vendor: .openAI, model: "gpt-5", systemPrompt: "Be brief.")
  )
  let session = try await client.newSessionV2(ACPV2NewSessionRequest(
    cwd: "/tmp", systemPrompt: ACPSystemPrompt(content: text("Answer in French."))
  ))
  let option = try #require(session.configOptions.first)
  #expect(option.configId == "model")
  #expect(option.category == ACPSessionConfigOption.categoryModel)
  #expect(option.kind == .select(currentValue: "gpt-5", options: .ungrouped([
    .init(value: "gpt-5", name: "gpt-5"), .init(value: "gpt-5-mini", name: "GPT-5 mini")
  ])))

  let updated = try await client.setConfigOptionV2(
    sessionId: session.sessionId, configId: "model", value: .id("gpt-5-mini")
  )
  #expect(updated.first?.kind == .select(currentValue: "gpt-5-mini", options: .ungrouped([
    .init(value: "gpt-5", name: "gpt-5"), .init(value: "gpt-5-mini", name: "GPT-5 mini")
  ])))
  let rejected: [(String, ACPSessionConfigValue)] = [
    ("model", .id("not-listed")), ("unknown", .id("gpt-5")), ("model", .boolean(true))
  ]
  for (configId, value) in rejected {
    do {
      _ = try await client.setConfigOptionV2(sessionId: session.sessionId, configId: configId, value: value)
      Issue.record("expected the config change to be rejected")
    } catch let error as ACPError {
      #expect(error.code == ACPErrorCode.invalidParams)
    }
  }

  let turn = try await client.promptTurnCollecting(
    ACPV2PromptRequest(sessionId: session.sessionId, prompt: text("hi"))
  )
  let params = try #require(await executor.executions.first)
  #expect(params.model == "gpt-5-mini")
  #expect(params.systemPrompt == "Be brief.\n\nAnswer in French.")
  // A result the vendor never streamed still reaches the client as a message.
  #expect(turn.messageText == "unstreamed")
  #expect(await recorder.kinds.contains("agent_message"))
  await client.stop()
}

// MARK: - v1 session management on the shared session table

@Test func v1LoadReplaysHistoryAndClosedSessionsRejectPrompts() async throws {
  let agent = GatewayACPAgent(
    defaults: GatewayAgentDefaults(vendor: .codex, model: "gpt-5"), executor: V2ScriptedExecutor()
  )
  let replay = V1ReplayRecorder()
  let (client, _) = await ACPClientConnection.inProcess(v1: agent, v2: agent, delegate: replay)
  let initialized = try await client.initialize()
  #expect(initialized.agentCapabilities.loadSession)
  let session = try await client.newSession(ACPNewSessionRequest(cwd: "/tmp"))
  _ = try await client.prompt(ACPPromptRequest(sessionId: session.sessionId, prompt: text("hi")))

  try await client.closeSession(sessionId: session.sessionId)
  do {
    _ = try await client.prompt(ACPPromptRequest(sessionId: session.sessionId, prompt: text("again")))
    Issue.record("expected the closed session to be rejected")
  } catch let error as ACPError {
    #expect(error.code == ACPErrorCode.resourceNotFound)
  }

  await replay.reset()
  _ = try await client.loadSession(ACPLoadSessionRequest(sessionId: session.sessionId, cwd: "/tmp"))
  #expect(await replay.kinds == ["user_message_chunk", "agent_message_chunk"])
  // Loading made the session active again.
  let response = try await client.prompt(ACPPromptRequest(sessionId: session.sessionId, prompt: text("more")))
  #expect(response.stopReason == .endTurn)
  await client.stop()
}

private actor V1ReplayRecorder: ACPClientDelegate {
  private(set) var kinds: [String] = []

  func sessionUpdate(_ notification: ACPSessionNotification) async {
    switch notification.update {
    case .userMessageChunk: kinds.append("user_message_chunk")
    case .agentMessageChunk: kinds.append("agent_message_chunk")
    case .agentThoughtChunk: kinds.append("agent_thought_chunk")
    default: kinds.append("other")
    }
  }

  func reset() {
    kinds = []
  }
}
