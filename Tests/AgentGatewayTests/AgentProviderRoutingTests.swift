import Testing
@testable import AgentGateway

@Test func codexRoutingBuildsConfigOverridesWithoutSecretValues() throws {
  let provider = try AgentProviderConfiguration(
    name: "openrouter",
    baseUrl: "https://openrouter.ai/api/v1",
    apiKeyEnv: "OPENROUTER_API_KEY"
  )
  let overrides = AgentProviderRouting.codexConfigurationOverrides(for: provider)
  #expect(overrides == [
    "model_provider=openrouter",
    "model_providers.openrouter.name=openrouter",
    "model_providers.openrouter.base_url=https://openrouter.ai/api/v1",
    "model_providers.openrouter.env_key=OPENROUTER_API_KEY"
  ])
  #expect(!overrides.contains { $0.contains("secret-value") })
}

@Test func claudeRoutingBuildsEnvironmentAndClearsConflictingAnthropicKey() throws {
  let provider = try OpenRouterProvider.configuration(for: .claudeCodeAgent)
  let environment = try AgentProviderRouting.claudeCodeEnvironment(
    for: provider,
    runtimeEnvironment: ["OPENROUTER_API_KEY": "secret-value"]
  )
  #expect(environment == [
    "ANTHROPIC_BASE_URL": "https://openrouter.ai/api",
    "ANTHROPIC_AUTH_TOKEN": "secret-value",
    "ANTHROPIC_API_KEY": ""
  ])
}

@Test func claudeRoutingRequiresConfiguredCredential() throws {
  let provider = try OpenRouterProvider.configuration(for: .claudeCodeAgent)
  #expect(throws: AgentProviderRoutingError.missingRuntimeEnvironment("OPENROUTER_API_KEY")) {
    try AgentProviderRouting.claudeCodeEnvironment(for: provider, runtimeEnvironment: [:])
  }
}

@Test func openRouterUsesBackendSpecificBaseURLs() throws {
  #expect(try OpenRouterProvider.configuration(for: .codexAgent).baseUrl == "https://openrouter.ai/api/v1")
  #expect(try OpenRouterProvider.configuration(for: .claudeCodeAgent).baseUrl == "https://openrouter.ai/api")
}
