import ACP
import Foundation
import Testing
@testable import AgentGateway
@testable import AgentGatewayAppCore

/// Writes an executable stand-in vendor CLI and returns its path. The script
/// echoes one claude-code `result` line whose text is the value of
/// `RIELA_GATEWAY_TEST_TOKEN`, so a test can prove which environment the
/// child process actually inherited.
private func makeEnvironmentEchoingVendorScript() throws -> (directory: URL, executable: String) {
  let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("gateway-env-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let script = directory.appendingPathComponent("fake-vendor")
  try """
  #!/bin/sh
  printf '{"type":"result","result":"%s","session_id":"vendor-session"}\\n' "$RIELA_GATEWAY_TEST_TOKEN"
  """.write(to: script, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
  return (directory, script.path)
}

@Test func executorPassesItsEnvironmentToTheVendorProcess() async throws {
  let (directory, executable) = try makeEnvironmentEchoingVendorScript()
  defer { try? FileManager.default.removeItem(at: directory) }

  let executor = ProductionGatewayExecutor(environment: [
    "PATH": "/usr/bin:/bin",
    "RIELA_GATEWAY_TEST_TOKEN": "scoped-to-this-call"
  ])
  let result = try await executor.execute(
    GatewayExecuteParams(
      vendor: .claudeCode,
      model: "sonnet",
      prompt: "hello",
      executable: executable
    ),
    emit: { _ in }
  )

  #expect(result.text == "scoped-to-this-call")
  #expect(result.sessionId == "vendor-session")
  // The host process never learns the value, so concurrent callers cannot
  // collide through a mutated global environment.
  #expect(ProcessInfo.processInfo.environment["RIELA_GATEWAY_TEST_TOKEN"] == nil)
}

@Test func executorResolvesExecutablesOnTheSuppliedPath() throws {
  let (directory, executable) = try makeEnvironmentEchoingVendorScript()
  defer { try? FileManager.default.removeItem(at: directory) }
  let name = URL(fileURLWithPath: executable).lastPathComponent

  let onPath = ProductionGatewayExecutor(environment: ["PATH": directory.path])
    .readiness(GatewayReadinessParams(vendor: .claudeCode, executable: name))
  #expect(onPath.status == .ready)

  let offPath = ProductionGatewayExecutor(environment: ["PATH": "/nonexistent"])
    .readiness(GatewayReadinessParams(vendor: .claudeCode, executable: name))
  #expect(offPath.status == .unavailable)
}

@Test func executorReadsCredentialsFromTheSuppliedEnvironment() throws {
  let readiness = ProductionGatewayExecutor(environment: ["ANTHROPIC_API_KEY": "sk-test"])
    .readiness(GatewayReadinessParams(vendor: .anthropic))
  #expect(readiness.status == .ready)

  let missing = ProductionGatewayExecutor(environment: [:])
    .readiness(GatewayReadinessParams(vendor: .anthropic))
  #expect(missing.status == .unavailable)
}

@Test func cliCommandRoutesProvidersThroughTheSuppliedEnvironment() throws {
  let command = try cliCommand(
    GatewayExecuteParams(
      vendor: .claudeCode,
      model: "custom",
      prompt: "hi",
      apiKeyEnvironment: "CUSTOM_TOKEN",
      baseURL: "https://example.test/v1"
    ),
    environment: ["CUSTOM_TOKEN": "routed-value"]
  )
  #expect(command.environment["ANTHROPIC_BASE_URL"] == "https://example.test/v1")
  #expect(command.environment.values.contains("routed-value"))
}

@Test func inProcessClientRunsAPromptTurnWithoutSpawningTheGateway() async throws {
  let (directory, executable) = try makeEnvironmentEchoingVendorScript()
  defer { try? FileManager.default.removeItem(at: directory) }

  let agent = GatewayACPAgent(
    defaults: GatewayAgentDefaults(vendor: .claudeCode, model: "sonnet", executable: executable),
    executor: ProductionGatewayExecutor(environment: [
      "PATH": "/usr/bin:/bin",
      "RIELA_GATEWAY_TEST_TOKEN": "in-process"
    ])
  )
  let (client, server) = await ACPClientConnection.inProcess(agent: agent)
  defer { Task { await server.connection.stop() } }

  _ = try await client.initialize()
  let session = try await client.newSession(ACPNewSessionRequest(cwd: directory.path, mcpServers: []))
  let turn = try await client.promptCollecting(
    ACPPromptRequest(sessionId: session.sessionId, prompt: [.text("hello")])
  )
  await client.stop()

  #expect(turn.response.stopReason == .endTurn)
  #expect(turn.messageText == "in-process")
  let meta = turn.response.meta?["agentGateway"]
  #expect(meta?["resultText"]?.stringValue == "in-process")
  #expect(meta?["vendorSessionId"]?.stringValue == "vendor-session")
}
