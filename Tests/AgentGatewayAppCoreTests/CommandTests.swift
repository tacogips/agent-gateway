import Testing
@testable import AgentGateway
@testable import AgentGatewayAppCore

@Test func commandReportsVersion() throws {
  let command = AppCommand(arguments: ["--version"])
  #expect(try command.run() == Version.current)
}

@Test func clientCommandBuildsTypedCursorAPIAndSessionOptions() throws {
  let request = try AppCommand(arguments: []).clientRequest([
    "--vendor", "cursor-api",
    "--model", "composer-1",
    "--prompt", "implement it",
    "--session-id", "agent-123",
    "--cursor-repository-url", "https://github.com/example/project.git",
    "--cursor-starting-ref", "main",
    "--cursor-work-on-current-branch", "true",
    "--cursor-auto-create-pr", "false"
  ])
  #expect(request.params.vendor == .cursorAPI)
  #expect(request.params.sessionMode == .reuse)
  #expect(request.params.sessionId == "agent-123")
  #expect(request.params.cursorAPI == GatewayCursorAPIOptions(
    repositoryURL: "https://github.com/example/project.git",
    startingRef: "main",
    workOnCurrentBranch: true,
    autoCreatePR: false
  ))
}

@Test func readinessCommandBuildsTypedRequest() throws {
  let request = try AppCommand(arguments: []).readinessRequest([
    "--vendor", "anthropic",
    "--api-key-environment", "ANTHROPIC_TOKEN"
  ])
  #expect(request.method == "agent/readiness")
  #expect(request.params.vendor == .anthropic)
  #expect(request.params.apiKeyEnvironment == "ANTHROPIC_TOKEN")
}

@Test func commandReportsUsage() throws {
  let command = AppCommand(arguments: ["--help"])
  #expect(try command.run().contains("Usage: agent-gateway"))
}

@Test func commandRejectsUnknownFlags() throws {
  let command = AppCommand(arguments: ["--unknown"])
  do {
    _ = try command.run()
    Issue.record("Expected an unknown argument error")
  } catch AppCommand.Error.unknownArgument(let argument) {
    #expect(argument == "--unknown")
  } catch {
    Issue.record("Unexpected error: \(error)")
  }
}
