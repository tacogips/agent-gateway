import ACP
import Foundation
import Testing
@testable import AgentGateway
@testable import AgentGatewayAppCore

private struct ScriptedExecutor: GatewayExecuting {
  enum Step: Sendable {
    case delta(String)
    case snapshot(String)
    case thinking(String)
    case vendorEvent(String)
  }

  var steps: [Step]
  var resultText: String
  var vendorSessionId: String?
  var usage: GatewayUsage?

  func execute(
    _ params: GatewayExecuteParams, emit: @escaping GatewayEventEmitter
  ) async throws -> GatewayExecuteResult {
    for step in steps {
      switch step {
      case .delta(let text):
        emit("assistant.delta", .assistant, text, nil, "{}", nil)
      case .snapshot(let text):
        emit("assistant.message", .assistant, nil, text, "{}", nil)
      case .thinking(let text):
        emit("thinking.delta", .thinking, text, nil, "{}", nil)
      case .vendorEvent(let payload):
        emit("vendor.event", .vendor, nil, nil, payload, nil)
      }
    }
    return GatewayExecuteResult(
      vendor: params.vendor,
      model: params.model,
      text: resultText,
      usage: usage,
      sessionId: vendorSessionId
    )
  }
}

private struct HangingExecutor: GatewayExecuting {
  func execute(
    _ params: GatewayExecuteParams, emit: @escaping GatewayEventEmitter
  ) async throws -> GatewayExecuteResult {
    emit("assistant.delta", .assistant, "partial", nil, "{}", nil)
    try await Task.sleep(for: .seconds(30))
    return GatewayExecuteResult(vendor: params.vendor, model: params.model, text: "never")
  }
}

private actor RecordingDelegate: ACPClientDelegate {
  private(set) var notifications: [ACPSessionNotification] = []

  func sessionUpdate(_ notification: ACPSessionNotification) async {
    notifications.append(notification)
  }

  func messageChunks() -> [String] {
    notifications.compactMap {
      if case .agentMessageChunk(.text(let content)) = $0.update { return content.text }
      return nil
    }
  }

  func thoughtChunks() -> [String] {
    notifications.compactMap {
      if case .agentThoughtChunk(.text(let content)) = $0.update { return content.text }
      return nil
    }
  }
}

private func makeConnectedGateway(
  executor: any GatewayExecuting,
  defaults: GatewayAgentDefaults = GatewayAgentDefaults(vendor: .codex, model: "gpt-5")
) async -> (ACPClientConnection, RecordingDelegate) {
  let (clientSide, agentSide) = ACPInMemoryTransport.pair()
  let server = ACPAgentServer(
    agent: GatewayACPAgent(defaults: defaults, executor: executor),
    transport: agentSide
  )
  await server.start()
  let delegate = RecordingDelegate()
  let client = ACPClientConnection(transport: clientSide, delegate: delegate)
  await client.start()
  return (client, delegate)
}

@Test func streamingTokensArriveAsOrderedAgentMessageChunks() async throws {
  let executor = ScriptedExecutor(
    steps: [.delta("he"), .delta("l"), .delta("lo"), .snapshot("hello")],
    resultText: "hello",
    vendorSessionId: "vendor-1",
    usage: GatewayUsage(inputTokens: 3, outputTokens: 5, totalTokens: 8)
  )
  let (client, delegate) = await makeConnectedGateway(executor: executor)
  _ = try await client.initialize()
  let session = try await client.newSession(ACPNewSessionRequest(cwd: "/tmp"))
  let response = try await client.prompt(
    ACPPromptRequest(sessionId: session.sessionId, prompt: [.text("hi")])
  )
  #expect(response.stopReason == .endTurn)
  let chunks = await delegate.messageChunks()
  #expect(chunks == ["he", "l", "lo"])
  let meta = response.meta?["agentGateway"]
  #expect(meta?["vendorSessionId"]?.stringValue == "vendor-1")
  #expect(meta?["usage"]?["totalTokens"]?.integerValue == 8)
  await client.stop()
}

@Test func nonStreamingSnapshotsBecomeSingleChunkWithoutFinalEcho() async throws {
  // Snapshot-only vendors (claude-code messages, cursor-api, codex
  // agent_message): whole messages arrive as one chunk each, and the
  // trailing result echo of the last message is not re-emitted.
  let executor = ScriptedExecutor(
    steps: [
      .vendorEvent(#"{"type":"system.init"}"#),
      .snapshot("first answer"),
      .snapshot("second answer"),
      .snapshot("second answer")
    ],
    resultText: "second answer"
  )
  let (client, delegate) = await makeConnectedGateway(executor: executor)
  _ = try await client.initialize()
  let session = try await client.newSession(ACPNewSessionRequest(cwd: "/tmp"))
  _ = try await client.prompt(ACPPromptRequest(sessionId: session.sessionId, prompt: [.text("hi")]))
  let chunks = await delegate.messageChunks()
  #expect(chunks == ["first answer", "second answer"])
  await client.stop()
}

@Test func growingSnapshotsEmitOnlyTheSuffixDelta() async throws {
  let executor = ScriptedExecutor(
    steps: [.snapshot("hel"), .snapshot("hello"), .thinking("pondering")],
    resultText: "hello"
  )
  let (client, delegate) = await makeConnectedGateway(executor: executor)
  _ = try await client.initialize()
  let session = try await client.newSession(ACPNewSessionRequest(cwd: "/tmp"))
  _ = try await client.prompt(ACPPromptRequest(sessionId: session.sessionId, prompt: [.text("hi")]))
  #expect(await delegate.messageChunks() == ["hel", "lo"])
  #expect(await delegate.thoughtChunks() == ["pondering"])
  await client.stop()
}

@Test func sessionMetaOverridesDefaultsAndThreadsVendorSession() async throws {
  let executor = ScriptedExecutor(steps: [.delta("ok")], resultText: "ok", vendorSessionId: "next-id")
  let (client, _) = await makeConnectedGateway(
    executor: executor,
    defaults: GatewayAgentDefaults(vendor: .codex, model: "gpt-5")
  )
  _ = try await client.initialize()
  let session = try await client.newSession(ACPNewSessionRequest(
    cwd: "/tmp",
    meta: .object(["agentGateway": .object([
      "vendor": .string("claude-code"),
      "model": .string("claude-sonnet-5"),
      "vendorSessionId": .string("resume-me")
    ])])
  ))
  let meta = session.meta?["agentGateway"]
  #expect(meta?["vendor"]?.stringValue == "claude-code")
  #expect(meta?["model"]?.stringValue == "claude-sonnet-5")
  _ = try await client.prompt(ACPPromptRequest(sessionId: session.sessionId, prompt: [.text("hi")]))
  await client.stop()
}

@Test func newSessionWithoutVendorConfigurationIsRejected() async throws {
  let executor = ScriptedExecutor(steps: [], resultText: "")
  let (client, _) = await makeConnectedGateway(
    executor: executor,
    defaults: GatewayAgentDefaults()
  )
  _ = try await client.initialize()
  await #expect(throws: ACPError.self) {
    _ = try await client.newSession(ACPNewSessionRequest(cwd: "/tmp"))
  }
  await #expect(throws: ACPError.self) {
    _ = try await client.newSession(ACPNewSessionRequest(
      cwd: "relative/path",
      meta: .object(["agentGateway": .object([
        "vendor": .string("codex"), "model": .string("gpt-5")
      ])])
    ))
  }
  await client.stop()
}

@Test func cancelNotificationYieldsCancelledStopReason() async throws {
  let (client, _) = await makeConnectedGateway(executor: HangingExecutor())
  _ = try await client.initialize()
  let session = try await client.newSession(ACPNewSessionRequest(cwd: "/tmp"))
  async let pending = client.prompt(
    ACPPromptRequest(sessionId: session.sessionId, prompt: [.text("hi")])
  )
  try await Task.sleep(for: .milliseconds(100))
  try await client.cancel(sessionId: session.sessionId)
  let response = try await pending
  #expect(response.stopReason == .cancelled)
  await client.stop()
}

@Test func promptForUnknownSessionFailsWithInvalidParams() async throws {
  let executor = ScriptedExecutor(steps: [], resultText: "")
  let (client, _) = await makeConnectedGateway(executor: executor)
  _ = try await client.initialize()
  do {
    _ = try await client.prompt(ACPPromptRequest(sessionId: "missing", prompt: [.text("hi")]))
    Issue.record("expected an error for the unknown session")
  } catch let error as ACPError {
    #expect(error.code == -32602)
  }
  await client.stop()
}
