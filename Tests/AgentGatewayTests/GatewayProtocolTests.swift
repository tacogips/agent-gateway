import Foundation
import Testing
@testable import AgentGateway
@testable import AgentGatewayAppCore

@Test func executeParamsRoundTripVendorSelection() throws {
  let params = GatewayExecuteParams(vendor: .openRouter, model: "openai/gpt-5", prompt: "hello")
  let data = try JSONEncoder().encode(params)
  let decoded = try JSONDecoder().decode(GatewayExecuteParams.self, from: data)
  #expect(decoded == params)
  #expect(decoded.protocolVersion == "1.0")
  #expect(GatewayVendor.allCases.map(\.rawValue) == [
    "claude-code", "codex", "cursor", "cursor-api", "openai", "anthropic", "gemini", "openrouter"
  ])
}

@Test func executeParamsDecodeMinimalPayloadWithTypedDefaults() throws {
  let data = Data(#"{"vendor":"codex","model":"gpt-5","prompt":"hello"}"#.utf8)
  let params = try JSONDecoder().decode(GatewayExecuteParams.self, from: data)
  #expect(params.protocolVersion == GatewayProtocolVersion.current)
  #expect(params.arguments.isEmpty)
  #expect(params.sessionMode == .new)
  #expect(params.cursorAPI == nil)
  #expect(params.retryPolicy == GatewayRetryPolicy())
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
