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

@Test func customBaseURLDefaultsModelForClientAndServer() throws {
  let command = AppCommand(arguments: [])
  let defaults = try command.serverDefaults([
    "--vendor", "codex",
    "--base-url", "https://api.kimi.example/v1"
  ])
  #expect(defaults.model == "custom")

  let client = try command.clientOptions([
    "--vendor", "claude-code",
    "--base-url", "https://api.kimi.example",
    "--prompt", "hello"
  ])
  let modelIndex = try #require(client.serverOptions.firstIndex(of: "--model"))
  #expect(client.serverOptions[modelIndex + 1] == "custom")
}

@Test func APIBaseURLStillRequiresAnExplicitModel() throws {
  #expect(throws: AppCommand.Error.missingValue("--model")) {
    try AppCommand(arguments: []).clientOptions([
      "--vendor", "openai",
      "--base-url", "https://api.example/v1",
      "--prompt", "hello"
    ])
  }
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

@Test func clientCommandDefaultsToACPVersion1AndAcceptsVersion2() throws {
  let command = AppCommand(arguments: [])
  let base = ["--vendor", "codex", "--model", "gpt-5", "--prompt", "hi", "--session-id", "thread-1"]
  let v1 = try command.clientOptions(base)
  #expect(v1.protocolVersion == 1)
  #expect(v1.sessionMeta?["agentGateway"]?["vendorSessionId"]?.stringValue == "thread-1")

  let v2 = try command.clientOptions(base + ["--acp-version", "2"])
  #expect(v2.protocolVersion == 2)
  // ACP v2 reserves unprefixed _meta keys, so the namespaced key is used.
  #expect(v2.sessionMeta?[GatewayACPMetaKey.v2]?["vendorSessionId"]?.stringValue == "thread-1")
  #expect(v2.sessionMeta?["agentGateway"] == nil)
  // The version flag is a client concern and is not forwarded to the server.
  #expect(!v2.serverOptions.contains("--acp-version"))

  #expect(throws: AppCommand.Error.self) {
    _ = try command.clientOptions(base + ["--acp-version", "3"])
  }
}

@Test func serverCommandServesBothACPVersionsUnlessRestricted() throws {
  let command = AppCommand(arguments: [])
  #expect(try command.serverProtocolVersions(["--vendor", "codex"]) == [1, 2])
  #expect(try command.serverProtocolVersions(["--acp-versions", "1"]) == [1])
  #expect(try command.serverProtocolVersions(["--acp-versions", "2, 1"]) == [1, 2])
  for invalid in ["", "0", "1,3", "two"] {
    #expect(throws: AppCommand.Error.self) {
      _ = try command.serverProtocolVersions(["--acp-versions", invalid])
    }
  }
}
