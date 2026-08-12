import Testing
@testable import AgentGateway
@testable import AgentGatewayAppCore

@Test func commandReportsVersion() throws {
  let command = AppCommand(arguments: ["--version"])
  #expect(try command.run() == Version.current)
}

@Test func clientCommandBuildsACPOptionsWithServerDefaults() throws {
  let options = try AppCommand(arguments: []).clientOptions([
    "--vendor", "cursor-api",
    "--model", "composer-1",
    "--prompt", "implement it",
    "--cwd", "/work/project",
    "--session-id", "agent-123",
    "--cursor-repository-url", "https://github.com/example/project.git"
  ])
  #expect(options.prompt == "implement it")
  #expect(options.cwd == "/work/project")
  #expect(options.agentExecutable == nil)
  #expect(options.serverOptions.contains("--vendor"))
  #expect(options.serverOptions.contains("cursor-api"))
  #expect(options.serverOptions.contains("--cursor-repository-url"))
  #expect(
    options.sessionMeta?["agentGateway"]?["vendorSessionId"]?.stringValue == "agent-123"
  )
}

@Test func clientCommandSupportsExternalACPAgents() throws {
  let options = try AppCommand(arguments: []).clientOptions([
    "--agent", "/usr/local/bin/some-acp-agent",
    "--prompt", "hello",
    "--", "--flag", "value"
  ])
  #expect(options.agentExecutable == "/usr/local/bin/some-acp-agent")
  #expect(options.agentArguments == ["--flag", "value"])
  #expect(options.serverOptions.isEmpty)
}

@Test func serverCommandBuildsAgentDefaults() throws {
  let defaults = try AppCommand(arguments: []).serverDefaults([
    "--vendor", "claude-code",
    "--model", "claude-sonnet-5",
    "--system", "be brief",
    "--", "--allowed-tools", "Bash"
  ])
  #expect(defaults.vendor == .claudeCode)
  #expect(defaults.model == "claude-sonnet-5")
  #expect(defaults.systemPrompt == "be brief")
  #expect(defaults.arguments == ["--allowed-tools", "Bash"])
}

@Test func readinessCommandBuildsTypedParams() throws {
  let params = try AppCommand(arguments: []).readinessParams([
    "--vendor", "anthropic",
    "--api-key-environment", "ANTHROPIC_TOKEN"
  ])
  #expect(params.vendor == .anthropic)
  #expect(params.apiKeyEnvironment == "ANTHROPIC_TOKEN")
}

@Test func commandReportsUsage() throws {
  let command = AppCommand(arguments: ["--help"])
  let usage = try command.run()
  #expect(usage.contains("Usage: agent-gateway"))
  #expect(usage.contains("Agent Client Protocol"))
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
