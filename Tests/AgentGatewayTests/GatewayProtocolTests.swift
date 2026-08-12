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
    "claude-code", "codex", "cursor", "openai", "anthropic", "gemini", "openrouter"
  ])
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

private struct StubGatewayExecutor: GatewayExecuting {
  func execute(_ params: GatewayExecuteParams, emit: @escaping GatewayEventEmitter) async throws -> GatewayExecuteResult {
    emit("assistant.delta", .assistant, "hel", nil, #"{"delta":"hel"}"#)
    emit("assistant.delta", .assistant, "lo", nil, #"{"delta":"lo"}"#)
    return GatewayExecuteResult(vendor: params.vendor, model: params.model, text: "hello")
  }
}

private final class LockedData: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  var string: String { lock.withLock { String(bytes: data, encoding: .utf8) ?? "" } }
  func append(_ value: Data) { lock.withLock { data.append(value) } }
}
