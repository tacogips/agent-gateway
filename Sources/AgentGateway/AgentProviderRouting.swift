import Foundation

public enum AgentGatewayBackend: String, Codable, CaseIterable, Sendable {
  case codexAgent = "codex-agent"
  case claudeCodeAgent = "claude-code-agent"
}

public enum AgentProviderRoutingError: Error, Equatable, LocalizedError, Sendable {
  case missingRuntimeEnvironment(String)

  public var errorDescription: String? {
    switch self {
    case let .missingRuntimeEnvironment(name):
      "provider.apiKeyEnv requires runtime environment '\(name)'"
    }
  }
}

public enum AgentProviderRouting {
  public static func codexConfigurationOverrides(
    for provider: AgentProviderConfiguration?
  ) -> [String] {
    guard let provider else {
      return []
    }
    var overrides = [
      "model_provider=\(provider.name)",
      "model_providers.\(provider.name).name=\(provider.name)",
      "model_providers.\(provider.name).base_url=\(provider.baseUrl)"
    ]
    if let apiKeyEnv = provider.apiKeyEnv {
      overrides.append("model_providers.\(provider.name).env_key=\(apiKeyEnv)")
    }
    return overrides
  }

  public static func claudeCodeEnvironment(
    for provider: AgentProviderConfiguration?,
    runtimeEnvironment: [String: String]
  ) throws -> [String: String] {
    guard let provider else {
      return [:]
    }
    var environment = ["ANTHROPIC_BASE_URL": provider.baseUrl]
    if let apiKeyEnv = provider.apiKeyEnv {
      guard let runtimeValue = provider.credentialValue(in: runtimeEnvironment),
        !runtimeValue.isEmpty else {
        throw AgentProviderRoutingError.missingRuntimeEnvironment(apiKeyEnv)
      }
      environment["ANTHROPIC_AUTH_TOKEN"] = runtimeValue
    }
    if provider.name == OpenRouterProvider.name {
      environment["ANTHROPIC_API_KEY"] = ""
    }
    return environment
  }
}

public enum OpenRouterProvider {
  public static let name = "openrouter"
  public static let apiKeyEnvironmentName = "OPENROUTER_API_KEY"
  public static let codexBaseURL = "https://openrouter.ai/api/v1"
  public static let claudeCodeBaseURL = "https://openrouter.ai/api"

  public static func configuration(
    for backend: AgentGatewayBackend,
    apiKeyEnvironmentName: String = apiKeyEnvironmentName
  ) throws -> AgentProviderConfiguration {
    let baseURL = switch backend {
    case .codexAgent: codexBaseURL
    case .claudeCodeAgent: claudeCodeBaseURL
    }
    return try AgentProviderConfiguration(
      name: name,
      baseUrl: baseURL,
      apiKeyEnv: apiKeyEnvironmentName
    )
  }
}
