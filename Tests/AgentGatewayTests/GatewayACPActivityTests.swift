import ACP
import Foundation
import Testing
@testable import AgentGateway
@testable import AgentGatewayAppCore

// Tool-call, plan, and usage reporting of the ACP agent: scripted vendor
// lines in, exact ACP updates out, on protocol v1 and v2.

// MARK: - Fixtures

/// Vendor lines as the CLIs print them (trimmed to the fields that matter).
private enum ClaudeLine {
  static let messageStart = #"""
    {"type":"stream_event","event":{"type":"message_start","message":{"model":"claude-x",\#
    "usage":{"input_tokens":2,"cache_creation_input_tokens":10,"cache_read_input_tokens":20,"output_tokens":1}}},\#
    "parent_tool_use_id":null,"session_id":"s1"}
    """#
  static func text(_ text: String) -> String {
    #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"\#(text)"}},"session_id":"s1"}"#
  }
  static let toolAnnounced = #"""
    {"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use",\#
    "id":"toolu_01","name":"Bash","input":{}}},"parent_tool_use_id":null,"session_id":"s1"}
    """#
  static let toolInput = #"""
    {"type":"assistant","message":{"model":"claude-x","content":[{"type":"tool_use","id":"toolu_01","name":"Bash",\#
    "input":{"command":"echo hi","description":"Print hi"}}],"usage":{"input_tokens":2,\#
    "cache_creation_input_tokens":10,"cache_read_input_tokens":20,"output_tokens":7}},"parent_tool_use_id":null,\#
    "session_id":"s1"}
    """#
  static let toolResult = #"""
    {"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01","type":"tool_result",\#
    "content":"hi","is_error":false}]},"parent_tool_use_id":null,"session_id":"s1",\#
    "tool_use_result":{"stdout":"hi","interrupted":false}}
    """#
  static let messageDelta = #"""
    {"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn"},\#
    "usage":{"input_tokens":2,"cache_creation_input_tokens":10,"cache_read_input_tokens":20,"output_tokens":8}},\#
    "parent_tool_use_id":null,"session_id":"s1"}
    """#
  static let result = #"""
    {"type":"result","subtype":"success","result":"done","total_cost_usd":0.25,"usage":{"input_tokens":6,\#
    "output_tokens":48},"modelUsage":{"claude-x":{"contextWindow":200000},\#
    "claude-helper":{"contextWindow":100000}},"session_id":"s1"}
    """#

  /// One turn: text, a Bash call through its three reports (the input
  /// report twice), more text, and the final result.
  static let turn = [
    messageStart, text("Hi"), toolAnnounced, toolInput, toolInput, toolResult, messageDelta, text("done"), result
  ]
}

private enum CodexLine {
  static let commandStarted = #"""
    {"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'echo hi'",\#
    "aggregated_output":"","exit_code":null,"status":"in_progress"}}
    """#
  static let commandCompleted = #"""
    {"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'echo hi'",\#
    "aggregated_output":"hi\n","exit_code":0,"status":"completed"}}
    """#
  static let todoStarted = #"{"type":"item.started","item":{"id":"item_2","type":"todo_list","items":[{"text":"Run it","completed":true},{"text":"Report","completed":false}]}}"#
  static let message = #"{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"done"}}"#
}

/// Emits the events its vendor lines parse to, then returns, fails, or
/// waits to be cancelled.
private struct LineExecutor: GatewayExecuting {
  enum Ending: Sendable {
    case finish
    case fail(GatewayRPCError)
    case hang
  }

  var vendor: GatewayVendor
  var lines: [String]
  var ending = Ending.finish
  /// Signalled once every line has been emitted.
  var emitted: AsyncStream<Void>.Continuation?

  func execute(
    _ params: GatewayExecuteParams, emit: @escaping GatewayEventEmitter
  ) async throws -> GatewayExecuteResult {
    for line in lines {
      emit(parseVendorJSON(line, vendor: vendor).event(vendorPayload: line))
    }
    emitted?.yield()
    switch ending {
    case .finish: break
    case .fail(let error): throw error
    case .hang: try await Task.sleep(for: .seconds(30))
    }
    return GatewayExecuteResult(vendor: params.vendor, model: params.model, text: "done")
  }
}

private actor V1Recorder: ACPClientDelegate {
  private(set) var updates: [ACPSessionUpdate] = []

  func sessionUpdate(_ notification: ACPSessionNotification) async {
    updates.append(notification.update)
  }
}

private actor V2ActivityRecorder: ACPClientDelegate {
  private(set) var updates: [ACPV2SessionUpdate] = []
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func sessionUpdate(_ notification: ACPSessionNotification) async {}

  func sessionUpdate(_ notification: ACPV2SessionNotification) async {
    updates.append(notification.update)
    guard isIdle else { return }
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }

  private var isIdle: Bool {
    updates.contains {
      if case .stateUpdate(let state) = $0 { return state.state == .idle }
      return false
    }
  }

  func waitForIdle() async {
    guard !isIdle else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  /// The turn's updates between the `running` and `idle` state updates.
  var activity: [ACPV2SessionUpdate] {
    updates.filter {
      switch $0 {
      case .stateUpdate, .userMessage, .sessionInfoUpdate: false
      default: true
      }
    }
  }

  var lastState: ACPV2StateUpdate? {
    updates.reversed().lazy.compactMap {
      if case .stateUpdate(let state) = $0 { return state }
      return nil
    }.first
  }
}

/// A connected gateway with one new session.
private struct Harness<Recorder> {
  var client: ACPClientConnection
  var recorder: Recorder
  var sessionId: ACPSessionID
}

private func makeV1(_ executor: LineExecutor) async throws -> Harness<V1Recorder> {
  let recorder = V1Recorder()
  let (client, _) = await ACPClientConnection.inProcess(
    agent: GatewayACPAgent(defaults: GatewayAgentDefaults(vendor: executor.vendor, model: "m"), executor: executor),
    delegate: recorder
  )
  _ = try await client.initialize()
  let session = try await client.newSession(ACPNewSessionRequest(cwd: "/tmp"))
  return Harness(client: client, recorder: recorder, sessionId: session.sessionId)
}

private func makeV2(_ executor: LineExecutor) async throws -> Harness<V2ActivityRecorder> {
  let recorder = V2ActivityRecorder()
  let agent = GatewayACPAgent(defaults: GatewayAgentDefaults(vendor: executor.vendor, model: "m"), executor: executor)
  let (client, _) = await ACPClientConnection.inProcess(v1: agent, v2: agent, delegate: recorder)
  _ = try await client.negotiate(ACPV2InitializeRequest(info: ACPImplementation(name: "test", version: "1")))
  let session = try await client.newSessionV2(ACPV2NewSessionRequest(cwd: "/tmp"))
  return Harness(client: client, recorder: recorder, sessionId: session.sessionId)
}

private let bashInput = ACPJSONValue.object(["command": .string("echo hi"), "description": .string("Print hi")])
private let bashOutput = ACPJSONValue.object(["stdout": .string("hi"), "interrupted": .bool(false)])
private let codexCommand = "/bin/zsh -lc 'echo hi'"

// MARK: - v1

@Test func v1ClaudeCodeTurnReportsToolCallThenUpdatesInOrderWithText() async throws {
  let harness = try await makeV1(LineExecutor(vendor: .claudeCode, lines: ClaudeLine.turn))
  let (client, recorder, sessionId) = (harness.client, harness.recorder, harness.sessionId)
  let response = try await client.prompt(ACPPromptRequest(sessionId: sessionId, prompt: [.text("go")]))
  #expect(response.stopReason == .endTurn)
  #expect(await recorder.updates == [
    .agentMessageChunk(.text("Hi")),
    .toolCall(ACPToolCall(
      toolCallId: "t1-toolu_01", title: "Bash", kind: .execute, status: .pending, name: "Bash"
    )),
    // The repeated input report and the result's echo of "done" add nothing.
    .toolCallUpdate(ACPToolCallUpdate(
      toolCallId: "t1-toolu_01", title: "echo hi", status: .inProgress, rawInput: bashInput
    )),
    .toolCallUpdate(ACPToolCallUpdate(
      toolCallId: "t1-toolu_01", status: .completed, content: [.content(.text("hi"))], rawOutput: bashOutput
    )),
    .agentMessageChunk(.text("done")),
    // Context use of the main model's last call against that model's
    // window (not the helper model's), reported once the window is known.
    .other(.object([
      "sessionUpdate": .string("usage_update"),
      "used": .integer(40),
      "size": .integer(200_000),
      "cost": .object(["amount": .number(0.25), "currency": .string("USD")]),
      "_meta": .object(["agentGateway": .object([
        "inputTokens": .integer(6), "outputTokens": .integer(48), "totalTokens": .integer(54)
      ])])
    ]))
  ])
  await client.stop()
}

@Test func v1CodexTurnReportsCommandAndPlanAndScopesIdsPerTurn() async throws {
  let lines = [CodexLine.commandStarted, CodexLine.commandCompleted, CodexLine.todoStarted, CodexLine.todoStarted, CodexLine.message]
  let harness = try await makeV1(LineExecutor(vendor: .codex, lines: lines))
  let (client, recorder, sessionId) = (harness.client, harness.recorder, harness.sessionId)
  _ = try await client.prompt(ACPPromptRequest(sessionId: sessionId, prompt: [.text("go")]))
  let firstTurn: [ACPSessionUpdate] = [
    .toolCall(ACPToolCall(
      toolCallId: "t1-item_1", title: codexCommand, kind: .execute, status: .inProgress,
      rawInput: .object(["command": .string(codexCommand)]), name: "command_execution"
    )),
    .toolCallUpdate(ACPToolCallUpdate(
      toolCallId: "t1-item_1", status: .completed, content: [.content(.text("hi\n"))],
      rawOutput: .object(["aggregated_output": .string("hi\n"), "exit_code": .integer(0)])
    )),
    .plan([
      ACPPlanEntry(content: "Run it", priority: .medium, status: .completed),
      ACPPlanEntry(content: "Report", priority: .medium, status: .pending)
    ]),
    .agentMessageChunk(.text("done"))
  ]
  #expect(await recorder.updates == firstTurn)

  // Codex numbers its items from zero on every run; the turn scope keeps
  // the second turn's call from colliding with the first one's.
  _ = try await client.prompt(ACPPromptRequest(sessionId: sessionId, prompt: [.text("again")]))
  let second = await recorder.updates.dropFirst(firstTurn.count).first
  guard case .toolCall(let call) = second else {
    Issue.record("expected the second turn to start a new tool call, got \(String(describing: second))")
    return
  }
  #expect(call.toolCallId == "t2-item_1")
  await client.stop()
}

@Test func v1SettlesOpenToolCallsOnCompletionErrorAndCancel() async throws {
  let open = [CodexLine.commandStarted]
  let started = ACPSessionUpdate.toolCall(ACPToolCall(
    toolCallId: "t1-item_1", title: codexCommand, kind: .execute, status: .inProgress,
    rawInput: .object(["command": .string(codexCommand)]), name: "command_execution"
  ))

  // The vendor finished without reporting the call's end.
  do {
    let harness = try await makeV1(LineExecutor(vendor: .codex, lines: open))
    let (client, recorder, sessionId) = (harness.client, harness.recorder, harness.sessionId)
    _ = try await client.prompt(ACPPromptRequest(sessionId: sessionId, prompt: [.text("go")]))
    #expect(await recorder.updates == [
      started, .toolCallUpdate(ACPToolCallUpdate(toolCallId: "t1-item_1", status: .completed))
    ])
    await client.stop()
  }

  // The vendor failed.
  do {
    let failure = GatewayRPCError(code: gatewayVendorProcessFailureCode, message: "codex exited with status 1")
    let harness = try await makeV1(
      LineExecutor(vendor: .codex, lines: open, ending: .fail(failure))
    )
    let (client, recorder, sessionId) = (harness.client, harness.recorder, harness.sessionId)
    await #expect(throws: ACPError.self) {
      _ = try await client.prompt(ACPPromptRequest(sessionId: sessionId, prompt: [.text("go")]))
    }
    #expect(await recorder.updates == [
      started, .toolCallUpdate(ACPToolCallUpdate(toolCallId: "t1-item_1", status: .failed))
    ])
    await client.stop()
  }

  // The client cancelled while the call was running.
  do {
    let (emitted, signal) = AsyncStream.makeStream(of: Void.self)
    let harness = try await makeV1(
      LineExecutor(vendor: .codex, lines: open, ending: .hang, emitted: signal)
    )
    let (client, recorder, sessionId) = (harness.client, harness.recorder, harness.sessionId)
    async let pending = client.prompt(ACPPromptRequest(sessionId: sessionId, prompt: [.text("go")]))
    for await _ in emitted { break }
    try await client.cancel(sessionId: sessionId)
    #expect(try await pending.stopReason == .cancelled)
    #expect(await recorder.updates == [
      started, .toolCallUpdate(ACPToolCallUpdate(toolCallId: "t1-item_1", status: .failed))
    ])
    await client.stop()
  }
}

// MARK: - v2

@Test func v2ClaudeCodeTurnReportsToolCallUpsertsAndUsageInOrderWithText() async throws {
  let harness = try await makeV2(LineExecutor(vendor: .claudeCode, lines: ClaudeLine.turn))
  let (client, recorder, sessionId) = (harness.client, harness.recorder, harness.sessionId)
  _ = try await client.promptV2(ACPV2PromptRequest(sessionId: sessionId, prompt: [.text("go")]))
  await recorder.waitForIdle()
  let activity = await recorder.activity
  guard case .agentMessageChunk(let first) = activity.first else {
    Issue.record("expected the turn to start with a message chunk")
    return
  }
  let messageId = first.messageId
  #expect(activity == [
    .agentMessageChunk(ACPV2ContentChunk(messageId: messageId, content: .text("Hi"))),
    .toolCallUpdate(ACPV2ToolCallUpdate(
      toolCallId: "t1-toolu_01", name: .set("Bash"), title: .set("Bash"), kind: .set("execute"), status: .set("pending")
    )),
    .toolCallUpdate(ACPV2ToolCallUpdate(
      toolCallId: "t1-toolu_01", title: .set("echo hi"), status: .set("in_progress"), rawInput: .set(bashInput)
    )),
    .toolCallUpdate(ACPV2ToolCallUpdate(
      toolCallId: "t1-toolu_01", status: .set("completed"), content: .set([.content(.text("hi"))]),
      rawOutput: .set(bashOutput)
    )),
    .agentMessageChunk(ACPV2ContentChunk(messageId: messageId, content: .text("done"))),
    .usageUpdate(ACPV2UsageUpdate(
      used: 40, size: 200_000, cost: .set(ACPCost(amount: 0.25, currency: "USD")),
      meta: .set(.object([GatewayACPMetaKey.v2: .object([
        "inputTokens": .integer(6), "outputTokens": .integer(48), "totalTokens": .integer(54)
      ])]))
    ))
  ])
  #expect(await recorder.lastState?.stopReason == .endTurn)
  await client.stop()
}

@Test func v2CodexTurnReportsCommandFileChangeAndPlan() async throws {
  let fileChange = #"{"type":"item.completed","item":{"id":"item_4","type":"file_change","changes":[{"path":"/repo/a.txt","kind":"add"},{"path":"/repo/b.txt","kind":"update"}],"status":"completed"}}"#
  let lines = [CodexLine.commandStarted, CodexLine.commandCompleted, CodexLine.todoStarted, fileChange]
  let harness = try await makeV2(LineExecutor(vendor: .codex, lines: lines))
  let (client, recorder, sessionId) = (harness.client, harness.recorder, harness.sessionId)
  _ = try await client.promptV2(ACPV2PromptRequest(sessionId: sessionId, prompt: [.text("go")]))
  await recorder.waitForIdle()
  let changes: ACPJSONValue = .array([
    .object(["path": .string("/repo/a.txt"), "kind": .string("add")]),
    .object(["path": .string("/repo/b.txt"), "kind": .string("update")])
  ])
  #expect(await recorder.activity.dropLast() == [
    .toolCallUpdate(ACPV2ToolCallUpdate(
      toolCallId: "t1-item_1", name: .set("command_execution"), title: .set(codexCommand), kind: .set("execute"),
      status: .set("in_progress"), rawInput: .set(.object(["command": .string(codexCommand)]))
    )),
    .toolCallUpdate(ACPV2ToolCallUpdate(
      toolCallId: "t1-item_1", status: .set("completed"), content: .set([.content(.text("hi\n"))]),
      rawOutput: .set(.object(["aggregated_output": .string("hi\n"), "exit_code": .integer(0)]))
    )),
    .planUpdate(.items(planId: "t1-item_2", entries: [
      ACPV2PlanEntry(content: "Run it", priority: "medium", status: "completed"),
      ACPV2PlanEntry(content: "Report", priority: "medium", status: "pending")
    ])),
    // A call first seen finished is created with its final status.
    .toolCallUpdate(ACPV2ToolCallUpdate(
      toolCallId: "t1-item_4", name: .set("file_change"), title: .set("Edit 2 files"), kind: .set("edit"),
      status: .set("completed"),
      content: .set([.diff(ACPV2Diff(changes: [
        ACPV2Diff.Change(operation: "add", path: "/repo/a.txt"),
        ACPV2Diff.Change(operation: "modify", path: "/repo/b.txt")
      ]))]),
      locations: .set([ACPToolCallLocation(path: "/repo/a.txt"), ACPToolCallLocation(path: "/repo/b.txt")]),
      rawInput: .set(.object(["changes": changes]))
    ))
  ])
  await client.stop()
}

@Test func v2SettlesOpenToolCallsBeforeIdleOnCompletionErrorAndCancel() async throws {
  let open = [CodexLine.commandStarted]
  func settled(_ status: String) -> ACPV2SessionUpdate {
    .toolCallUpdate(ACPV2ToolCallUpdate(toolCallId: "t1-item_1", status: .set(status)))
  }

  do {
    let harness = try await makeV2(LineExecutor(vendor: .codex, lines: open))
    let (client, recorder, sessionId) = (harness.client, harness.recorder, harness.sessionId)
    _ = try await client.promptV2(ACPV2PromptRequest(sessionId: sessionId, prompt: [.text("go")]))
    await recorder.waitForIdle()
    // The settlement is the last activity; the idle state follows it.
    #expect(await recorder.activity.dropLast().last == settled("completed"))
    #expect(await recorder.updates.last?.kind == "state_update")
    await client.stop()
  }

  do {
    let failure = GatewayRPCError(code: gatewayVendorProcessFailureCode, message: "codex exited with status 1")
    let harness = try await makeV2(
      LineExecutor(vendor: .codex, lines: open, ending: .fail(failure))
    )
    let (client, recorder, sessionId) = (harness.client, harness.recorder, harness.sessionId)
    _ = try await client.promptV2(ACPV2PromptRequest(sessionId: sessionId, prompt: [.text("go")]))
    await recorder.waitForIdle()
    #expect(await recorder.activity.last == settled("failed"))
    #expect(await recorder.lastState?.stopReason == .error)
    await client.stop()
  }

  do {
    let (emitted, signal) = AsyncStream.makeStream(of: Void.self)
    let harness = try await makeV2(
      LineExecutor(vendor: .codex, lines: open, ending: .hang, emitted: signal)
    )
    let (client, recorder, sessionId) = (harness.client, harness.recorder, harness.sessionId)
    _ = try await client.promptV2(ACPV2PromptRequest(sessionId: sessionId, prompt: [.text("go")]))
    for await _ in emitted { break }
    try await client.cancel(sessionId: sessionId)
    await recorder.waitForIdle()
    #expect(await recorder.activity.last == settled("failed"))
    #expect(await recorder.lastState?.stopReason == .cancelled)
    await client.stop()
  }
}
