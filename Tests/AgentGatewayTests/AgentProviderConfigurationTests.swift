import Foundation
import Testing
@testable import AgentGateway

@Test func providerConfigurationRoundTrips() throws {
  let provider = try AgentProviderConfiguration(
    name: "openrouter_1",
    baseUrl: "https://provider.example/v1",
    apiKeyEnv: "PROVIDER_API_KEY"
  )
  let decoded = try JSONDecoder().decode(
    AgentProviderConfiguration.self,
    from: JSONEncoder().encode(provider)
  )
  #expect(decoded == provider)
}

@Test func providerConfigurationRejectsUnsafeValues() {
  #expect(throws: AgentProviderConfigurationError.invalidName) {
    try AgentProviderConfiguration(name: "OpenRouter", baseUrl: "https://provider.example/v1")
  }
  #expect(throws: AgentProviderConfigurationError.invalidBaseURL) {
    try AgentProviderConfiguration(name: "openrouter", baseUrl: "http://provider.example/v1")
  }
  #expect(throws: AgentProviderConfigurationError.invalidAPIKeyEnvironmentName) {
    try AgentProviderConfiguration(
      name: "openrouter",
      baseUrl: "https://provider.example/v1",
      apiKeyEnv: "INVALID-NAME"
    )
  }
  #expect(throws: AgentProviderConfigurationError.reservedAPIKeyEnvironmentName("RIELA_AGENT_BACKEND")) {
    try AgentProviderConfiguration(
      name: "openrouter",
      baseUrl: "https://provider.example/v1",
      apiKeyEnv: "RIELA_AGENT_BACKEND"
    )
  }
}

@Test func providerConfigurationAcceptsLoopbackHTTP() throws {
  for baseURL in [
    "http://localhost:11434/v1",
    "http://127.0.0.1:8000/v1",
    "http://[::1]:8000/v1"
  ] {
    _ = try AgentProviderConfiguration(name: "local", baseUrl: baseURL)
  }
}
