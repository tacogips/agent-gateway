import Foundation
import Testing
@testable import AgentGateway
@testable import AgentGatewayAppCore

@Test func protocolRoundTripsVendorSelectedRequest() throws {
  let request = GatewayRPCRequest(
    id: "request-1",
    params: GatewayExecuteParams(vendor: .openRouter, model: "openai/gpt-5", prompt: "hello")
  )
  let data = try JSONEncoder().encode(request)
  let decoded = try JSONDecoder().decode(GatewayRPCRequest.self, from: data)
  #expect(decoded == request)
  #expect(decoded.params.protocolVersion == "1.0")
  #expect(GatewayVendor.allCases.map(\.rawValue) == [
    "claude-code", "codex", "cursor", "cursor-api", "openai", "anthropic", "gemini", "openrouter"
  ])
}

@Test func protocolDecodesMinimalVersionOneRequestWithTypedDefaults() throws {
  let data = Data(#"{"jsonrpc":"2.0","id":"step-1","method":"agent/execute","params":{"vendor":"codex","model":"gpt-5","prompt":"hello"}}"#.utf8)
  let request = try JSONDecoder().decode(GatewayRPCRequest.self, from: data)
  #expect(request.params.protocolVersion == GatewayProtocolVersion.current)
  #expect(request.params.arguments.isEmpty)
  #expect(request.params.sessionMode == .new)
  #expect(request.params.cursorAPI == nil)
  #expect(request.params.retryPolicy == GatewayRetryPolicy())
}

@Test func retryPolicyClampsUntrustedProtocolValues() {
  let policy = GatewayRetryPolicy(
    maxAttempts: 100,
    initialDelayMilliseconds: -1,
    maximumDelayMilliseconds: 100_000
  )
  #expect(policy.maxAttempts == 10)
  #expect(policy.initialDelayMilliseconds == 0)
  #expect(policy.maximumDelayMilliseconds == 60_000)
}

@Test func serverWritesOrderedJSONLEventsBeforeTerminalResponse() async throws {
  let executor = StubGatewayExecutor()
  let server = GatewayJSONLServer(executor: executor)
  let output = LockedData()
  let writer = GatewayJSONLWriter { output.append($0) }
  await server.handle(
    request: GatewayRPCRequest(
      id: "request-2",
      params: GatewayExecuteParams(vendor: .codex, model: "gpt-5", prompt: "hello")
    ),
    writer: writer
  )
  let lines = output.string.split(whereSeparator: \.isNewline).map(String.init)
  #expect(lines.count == 3)
  let first = try JSONDecoder().decode(GatewayRPCNotification.self, from: Data(lines[0].utf8))
  let second = try JSONDecoder().decode(GatewayRPCNotification.self, from: Data(lines[1].utf8))
  let terminal = try JSONDecoder().decode(GatewayRPCResponse.self, from: Data(lines[2].utf8))
  #expect(first.params.sequence == 1)
  #expect(first.params.textDelta == "hel")
  #expect(second.params.sequence == 2)
  #expect(second.params.textDelta == "lo")
  #expect(terminal.result?.text == "hello")
  #expect(terminal.error == nil)
}

@Test func serverRejectsMalformedJSONWithoutWritingPlainTextToStdout() async throws {
  let output = LockedData()
  let writer = GatewayJSONLWriter { output.append($0) }
  await GatewayJSONLServer(executor: StubGatewayExecutor()).handle(line: "not-json", writer: writer)
  let response = try JSONDecoder().decode(GatewayRPCResponse.self, from: Data(output.string.utf8))
  #expect(response.error?.code == -32700)
}

@Test func serverHandlesTypedReadinessRequestAsOneJSONLResponse() async throws {
  let output = LockedData()
  let writer = GatewayJSONLWriter { output.append($0) }
  let request = GatewayReadinessRPCRequest(
    id: "readiness-1",
    params: GatewayReadinessParams(vendor: .codex, executable: "/usr/bin/true")
  )
  let line = try #require(String(data: JSONEncoder().encode(request), encoding: .utf8))
  await GatewayJSONLServer(executor: ReadinessStubGatewayExecutor()).handle(line: line, writer: writer)
  let response = try JSONDecoder().decode(GatewayReadinessRPCResponse.self, from: Data(output.string.utf8))
  #expect(response.id == "readiness-1")
  #expect(response.result?.vendor == .codex)
  #expect(response.result?.status == .ready)
}

@Test func cliSessionReuseUsesVendorSpecificResumeArguments() throws {
  let codex = try cliCommand(GatewayExecuteParams(
    vendor: .codex,
    model: "gpt-5",
    prompt: "continue",
    sessionMode: .reuse,
    sessionId: "codex-session"
  ))
  #expect(codex.arguments.contains("resume"))
  #expect(codex.arguments.contains("codex-session"))

  let claude = try cliCommand(GatewayExecuteParams(
    vendor: .claudeCode,
    model: "sonnet",
    prompt: "continue",
    sessionMode: .reuse,
    sessionId: "claude-session"
  ))
  #expect(claude.arguments.contains("--resume"))
  #expect(claude.arguments.contains("claude-session"))

  let cursor = try cliCommand(GatewayExecuteParams(
    vendor: .cursor,
    model: "composer-1",
    prompt: "continue",
    sessionMode: .reuse,
    sessionId: "cursor-session"
  ))
  #expect(cursor.arguments.contains("--resume"))
  #expect(cursor.arguments.contains("cursor-session"))
}

@Test func cliParserExtractsBackendSessionID() {
  let parsed = parseVendorJSON(#"{"type":"thread.started","thread_id":"thread-123"}"#, vendor: .codex)
  #expect(parsed.sessionId == "thread-123")
}

private struct StubGatewayExecutor: GatewayExecuting {
  func execute(_ params: GatewayExecuteParams, emit: @escaping GatewayEventEmitter) async throws -> GatewayExecuteResult {
    emit("assistant.delta", .assistant, "hel", nil, #"{"delta":"hel"}"#, "session-1")
    emit("assistant.delta", .assistant, "lo", nil, #"{"delta":"lo"}"#, "session-1")
    return GatewayExecuteResult(vendor: params.vendor, model: params.model, text: "hello")
  }
}

private struct ReadinessStubGatewayExecutor: GatewayExecuting, GatewayReadinessChecking {
  func execute(
    _ params: GatewayExecuteParams,
    emit: @escaping GatewayEventEmitter
  ) async throws -> GatewayExecuteResult {
    GatewayExecuteResult(vendor: params.vendor, model: params.model, text: "")
  }

  func readiness(_ params: GatewayReadinessParams) -> GatewayReadinessResult {
    GatewayReadinessResult(vendor: params.vendor, status: .ready, detail: "ready")
  }
}

private final class LockedData: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  var string: String { lock.withLock { String(bytes: data, encoding: .utf8) ?? "" } }
  func append(_ value: Data) { lock.withLock { data.append(value) } }
}
