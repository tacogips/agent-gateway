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

@Test func claudeCustomRoutingClearsConflictingAnthropicKey() throws {
  let provider = try CustomProvider.configuration(
    baseURL: "https://api.kimi.example",
    apiKeyEnvironmentName: "KIMI_API_KEY"
  )
  let environment = try AgentProviderRouting.claudeCodeEnvironment(
    for: provider,
    runtimeEnvironment: ["KIMI_API_KEY": "secret-value"]
  )
  #expect(environment == [
    "ANTHROPIC_BASE_URL": "https://api.kimi.example",
    "ANTHROPIC_AUTH_TOKEN": "secret-value",
    "ANTHROPIC_API_KEY": ""
  ])
}

@Test func openRouterUsesBackendSpecificBaseURLs() throws {
  #expect(try OpenRouterProvider.configuration(for: .codexAgent).baseUrl == "https://openrouter.ai/api/v1")
  #expect(try OpenRouterProvider.configuration(for: .claudeCodeAgent).baseUrl == "https://openrouter.ai/api")
}

@Test func customProviderUsesStableProviderAndModelNames() throws {
  let provider = try CustomProvider.configuration(
    baseURL: "https://api.kimi.example/v1",
    apiKeyEnvironmentName: "KIMI_API_KEY"
  )
  #expect(provider.name == "custom")
  #expect(CustomProvider.modelName == "custom")
  #expect(provider.baseUrl == "https://api.kimi.example/v1")
  #expect(provider.apiKeyEnv == "KIMI_API_KEY")
}
