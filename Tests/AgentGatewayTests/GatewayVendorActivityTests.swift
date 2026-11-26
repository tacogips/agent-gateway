import ACP
import Foundation
import Testing
@testable import AgentGateway
@testable import AgentGatewayAppCore

// What the vendor line parsers read as tool calls, plans, and context
// usage, and how the stream bridge merges repeated reports.

private func activity(_ line: String, _ vendor: GatewayVendor) -> ParsedVendorActivity {
  parseVendorJSON(line, vendor: vendor).activity
}

@Test func claudeCodeToolUseCarriesInputTitleKindAndLocation() {
  let line = #"""
    {"type":"assistant","message":{"model":"m","content":[{"type":"tool_use","id":"toolu_1","name":"Read",\#
    "input":{"file_path":"/repo/note.txt","offset":12}}]},"parent_tool_use_id":null,"session_id":"s1"}
    """#
  let parsed = parseVendorJSON(line, vendor: .claudeCode)
  #expect(parsed.activity.toolCalls == [GatewayToolCallEvent(
    toolCallId: "toolu_1", name: "Read", title: "Read /repo/note.txt", kind: .read, status: .inProgress,
    rawInput: .object(["file_path": .string("/repo/note.txt"), "offset": .integer(12)]),
    locations: [ACPToolCallLocation(path: "/repo/note.txt", line: 12)]
  )])
  // A line with tool calls and no text is delivered on the tool channel.
  let event = parsed.event(vendorPayload: line)
  #expect(event.channel == .tool)
  #expect(event.toolCalls.count == 1)
}

@Test func claudeCodeToolResultsReportFailureAndTextBlocks() {
  // Two results in one message: the structured `tool_use_result` cannot be
  // attributed to either, so each keeps its own content as raw output.
  let line = #"""
    {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1",\#
    "content":"boom","is_error":true},{"type":"tool_result","tool_use_id":"toolu_2","content":[{"type":"text",\#
    "text":"a"},{"type":"text","text":"b"}]}]},"parent_tool_use_id":null,"tool_use_result":{"x":1}}
    """#
  #expect(activity(line, .claudeCode).toolCalls == [
    GatewayToolCallEvent(toolCallId: "toolu_1", status: .failed, rawOutput: .string("boom"), outputText: "boom"),
    GatewayToolCallEvent(
      toolCallId: "toolu_2", status: .completed,
      rawOutput: .array([
        .object(["type": .string("text"), "text": .string("a")]),
        .object(["type": .string("text"), "text": .string("b")])
      ]),
      outputText: "a\nb"
    )
  ])
}

@Test func claudeCodeTodoWriteIsThePlan() {
  let line = #"""
    {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"TodoWrite",\#
    "input":{"todos":[{"content":"Build","status":"completed","activeForm":"Building"},{"content":"Test",\#
    "status":"in_progress","activeForm":"Testing"},{"content":"Ship","status":"pending",\#
    "activeForm":"Shipping"}]}}]},"parent_tool_use_id":null}
    """#
  let parsed = activity(line, .claudeCode)
  #expect(parsed.plan == GatewayPlanEvent(entries: [
    ACPPlanEntry(content: "Build", priority: .medium, status: .completed),
    ACPPlanEntry(content: "Test", priority: .medium, status: .inProgress),
    ACPPlanEntry(content: "Ship", priority: .medium, status: .pending)
  ]))
  #expect(parsed.toolCalls.first?.kind == .think)
}

@Test func claudeCodeSubagentMessagesDoNotMoveTheSessionContext() {
  let line = #"{"type":"stream_event","event":{"type":"message_delta","usage":{"input_tokens":5,"output_tokens":5}},"parent_tool_use_id":"toolu_9"}"#
  #expect(activity(line, .claudeCode).context == nil)
  let main = #"{"type":"stream_event","event":{"type":"message_delta","usage":{"input_tokens":5,"output_tokens":5}},"parent_tool_use_id":null}"#
  #expect(activity(main, .claudeCode).context == GatewayContextUsage(usedTokens: 10))
}

@Test func codexItemsMapToToolCalls() {
  let failed = #"""
    {"type":"item.completed","item":{"id":"item_5","type":"mcp_tool_call","server":"docs","tool":"search",\#
    "arguments":{"q":"acp"},"result":null,"error":{"message":"timeout"},"status":"failed"}}
    """#
  #expect(activity(failed, .codex).toolCalls == [GatewayToolCallEvent(
    toolCallId: "item_5", name: "search", title: "docs.search", kind: .other, status: .failed,
    rawInput: .object(["q": .string("acp")]), rawOutput: .object(["message": .string("timeout")]),
    outputText: "timeout"
  )])

  // `web_search` items carry no status: finishing is completing.
  let search = #"{"type":"item.completed","item":{"id":"item_6","type":"web_search","query":"swift 6"}}"#
  #expect(activity(search, .codex).toolCalls == [GatewayToolCallEvent(
    toolCallId: "item_6", name: "web_search", title: "swift 6", kind: .fetch, status: .completed,
    rawInput: .object(["query": .string("swift 6")])
  )])

  let declined = #"{"type":"item.completed","item":{"id":"item_7","type":"command_execution","command":"rm -rf /","aggregated_output":"","exit_code":null,"status":"declined"}}"#
  #expect(activity(declined, .codex).toolCalls.first?.status == .failed)

  // A relative path is reported as a change but is no ACP location.
  let relative = #"{"type":"item.completed","item":{"id":"item_8","type":"file_change","changes":[{"path":"docs/a.md","kind":"delete"}],"status":"completed"}}"#
  let call = activity(relative, .codex).toolCalls.first
  #expect(call?.locations == nil)
  #expect(call?.kind == .delete)
  #expect(call?.fileChanges == [GatewayToolCallEvent.FileChange(path: "docs/a.md", operation: "delete")])

  // Messages and reasoning are text, not tool calls.
  let message = #"{"type":"item.completed","item":{"id":"item_9","type":"agent_message","text":"hi"}}"#
  #expect(activity(message, .codex) == ParsedVendorActivity())
}

@Test func cursorToolCallLinesMapToToolCalls() {
  let started = #"{"type":"tool_call","subtype":"started","call_id":"c1","tool_call":{"readToolCall":{"args":{"path":"/repo/README.md"}}},"session_id":"s1"}"#
  #expect(activity(started, .cursor).toolCalls == [GatewayToolCallEvent(
    toolCallId: "c1", name: "readToolCall", title: "read /repo/README.md", kind: .read, status: .inProgress,
    rawInput: .object(["path": .string("/repo/README.md")]),
    locations: [ACPToolCallLocation(path: "/repo/README.md")]
  )])
  let completed = #"{"type":"tool_call","subtype":"completed","call_id":"c1","tool_call":{"readToolCall":{"args":{"path":"/repo/README.md"},"result":{"success":{"totalLines":3}}}},"session_id":"s1"}"#
  let done = activity(completed, .cursor).toolCalls.first
  #expect(done?.status == .completed)
  #expect(done?.rawOutput == .object(["success": .object(["totalLines": .integer(3)])]))
  let rejected = #"{"type":"tool_call","subtype":"completed","call_id":"c2","tool_call":{"shellToolCall":{"args":{"command":"ls"},"result":{"rejected":{"reason":"denied"}}}}}"#
  #expect(activity(rejected, .cursor).toolCalls.first?.status == .failed)
  let function = #"{"type":"tool_call","subtype":"started","call_id":"c3","tool_call":{"function":{"name":"lookup","arguments":"{\"q\":1}"}}}"#
  #expect(activity(function, .cursor).toolCalls == [GatewayToolCallEvent(
    toolCallId: "c3", name: "lookup", title: "lookup", kind: .other, status: .inProgress, rawInput: .string(#"{"q":1}"#)
  )])
}

@Test func antigravityToolStepsMapToToolCalls() {
  let started = #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"read_file","tool_info":{"name":"read_file","parameters":{"Path":"/repo/Package.swift"}}}}"#
  #expect(activity(started, .antigravity).toolCalls == [GatewayToolCallEvent(
    toolCallId: "step-2", name: "read_file", title: "read_file /repo/Package.swift", kind: .read, status: .inProgress,
    rawInput: .object(["Path": .string("/repo/Package.swift")]),
    locations: [ACPToolCallLocation(path: "/repo/Package.swift")]
  )])

  let completed = #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":2,"state":"DONE","step_type":"tool","tool_name":"read_file","tool_info":{"name":"read_file","parameters":{"Path":"/repo/Package.swift"},"output":"10 lines"}}}"#
  let done = activity(completed, .antigravity).toolCalls.first
  #expect(done?.status == .completed)
  #expect(done?.outputText == "10 lines")
}

@Test func apiVendorLinesCarryNoActivity() {
  let line = #"{"type":"tool_call","subtype":"started","call_id":"c1","tool_call":{"readToolCall":{"args":{}}}}"#
  #expect(activity(line, .openAI) == ParsedVendorActivity())
}

// MARK: - Bridge

private final class ChunkLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [GatewayStreamChunk] = []
  func append(_ chunk: GatewayStreamChunk) { lock.withLock { stored.append(chunk) } }
  var chunks: [GatewayStreamChunk] { lock.withLock { stored } }
}

private func toolEvent(_ call: GatewayToolCallEvent) -> GatewayEvent {
  GatewayEvent(type: "tool", channel: .tool, toolCalls: [call])
}

@Test func bridgeMergesToolCallReportsAndNeverReopensAFinishedCall() {
  let log = ChunkLog()
  let bridge = GatewayACPStreamBridge(scope: "t3-") { log.append($0) }
  bridge.consume(toolEvent(GatewayToolCallEvent(toolCallId: "a", title: "A", status: .inProgress)))
  // A repeat, and a report that would move the status backwards.
  bridge.consume(toolEvent(GatewayToolCallEvent(toolCallId: "a", title: "A", status: .inProgress)))
  bridge.consume(toolEvent(GatewayToolCallEvent(toolCallId: "a", status: .pending)))
  bridge.consume(toolEvent(GatewayToolCallEvent(toolCallId: "a", status: .failed, outputText: "no")))
  // Reports after the final status are dropped.
  bridge.consume(toolEvent(GatewayToolCallEvent(toolCallId: "a", title: "late", status: .completed)))
  // A call whose first report has no status starts pending.
  bridge.consume(toolEvent(GatewayToolCallEvent(toolCallId: "b", name: "x")))
  bridge.settleOpenToolCalls(.failed)
  bridge.settleOpenToolCalls(.completed)
  #expect(log.chunks == [
    .toolCall(GatewayToolCallChunk(isNew: true, toolCallId: "t3-a", title: "A", status: .inProgress)),
    .toolCall(GatewayToolCallChunk(isNew: false, toolCallId: "t3-a", status: .failed, outputText: "no")),
    .toolCall(GatewayToolCallChunk(isNew: true, toolCallId: "t3-b", name: "x", status: .pending)),
    // Only the open call is settled, and only once.
    .toolCall(GatewayToolCallChunk(isNew: false, toolCallId: "t3-b", status: .failed))
  ])
}

@Test func bridgeReportsContextSizeOnlyWhenItCanBeAttributed() {
  let log = ChunkLog()
  let bridge = GatewayACPStreamBridge { log.append($0) }
  func usage(_ context: GatewayContextUsage) -> GatewayEvent {
    GatewayEvent(type: "usage", channel: .usage, context: context)
  }
  bridge.consume(usage(GatewayContextUsage(usedTokens: 10, model: "main")))
  // Two windows, neither for the measured model: the size stays unknown.
  bridge.consume(usage(GatewayContextUsage(windowSizes: ["helper": 100, "other": 200])))
  bridge.consume(usage(GatewayContextUsage(windowSizes: ["main[1m]": 1_000])))
  #expect(log.chunks == [
    .usage(GatewayUsageChunk(contextUsed: 10)),
    .usage(GatewayUsageChunk(contextUsed: 10, contextSize: 1_000))
  ])
  // Without a size there is no ACP update: `used` and `size` are both required.
  #expect(GatewayUsageChunk(contextUsed: 10).v1Update(priorCostUSD: 0) == nil)
  #expect(GatewayUsageChunk(contextUsed: 10).v2Update(priorCostUSD: 0) == nil)
  // Cost is cumulative for the session: earlier turns plus this one.
  let update = GatewayUsageChunk(contextUsed: 1, contextSize: 2, costUSD: 0.25).v2Update(priorCostUSD: 0.5)
  #expect(update == .usageUpdate(ACPV2UsageUpdate(used: 1, size: 2, cost: .set(ACPCost(amount: 0.75, currency: "USD")))))
}
