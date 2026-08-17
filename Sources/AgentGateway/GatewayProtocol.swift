import Foundation

public enum GatewayProtocolVersion {
  public static let current = "1.0"
}

public enum GatewayVendor: String, Codable, CaseIterable, Sendable {
  case claudeCode = "claude-code"
  case codex
  case cursor
  case cursorAPI = "cursor-api"
  case openAI = "openai"
  case anthropic
  case gemini
  case openRouter = "openrouter"

  public var isCLI: Bool {
    switch self {
    case .claudeCode, .codex, .cursor:
      true
    case .openAI, .anthropic, .gemini, .openRouter, .cursorAPI:
      false
    }
  }
}

public enum GatewayEventChannel: String, Codable, Sendable {
  case lifecycle
  case assistant
  case thinking
  case tool
  case usage
  case vendor
}

public enum GatewaySessionMode: String, Codable, Sendable {
  case new
  case reuse
}

public struct GatewayCursorAPIOptions: Codable, Equatable, Sendable {
  public var repositoryURL: String?
  public var startingRef: String?
  public var workOnCurrentBranch: Bool?
  public var autoCreatePR: Bool?

  public init(
    repositoryURL: String? = nil,
    startingRef: String? = nil,
    workOnCurrentBranch: Bool? = nil,
    autoCreatePR: Bool? = nil
  ) {
    self.repositoryURL = repositoryURL
    self.startingRef = startingRef
    self.workOnCurrentBranch = workOnCurrentBranch
    self.autoCreatePR = autoCreatePR
  }
}

public struct GatewayImageInput: Codable, Equatable, Sendable {
  public var filePath: String?
  public var mimeType: String?
  public var dataBase64: String?

  public init(filePath: String, mimeType: String? = nil) {
    self.filePath = filePath
    self.mimeType = mimeType
    self.dataBase64 = nil
  }

  public init(dataBase64: String, mimeType: String) {
    self.filePath = nil
    self.mimeType = mimeType
    self.dataBase64 = dataBase64
  }
}

public struct GatewayRetryPolicy: Codable, Equatable, Sendable {
  public var maxAttempts: Int
  public var initialDelayMilliseconds: Int
  public var maximumDelayMilliseconds: Int

  public init(
    maxAttempts: Int = 3,
    initialDelayMilliseconds: Int = 250,
    maximumDelayMilliseconds: Int = 2_000
  ) {
    self.maxAttempts = max(1, min(maxAttempts, 10))
    self.initialDelayMilliseconds = max(0, min(initialDelayMilliseconds, 60_000))
    self.maximumDelayMilliseconds = max(
      self.initialDelayMilliseconds,
      min(maximumDelayMilliseconds, 60_000)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case maxAttempts
    case initialDelayMilliseconds
    case maximumDelayMilliseconds
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      maxAttempts: try container.decodeIfPresent(Int.self, forKey: .maxAttempts) ?? 3,
      initialDelayMilliseconds: try container.decodeIfPresent(Int.self, forKey: .initialDelayMilliseconds) ?? 250,
      maximumDelayMilliseconds: try container.decodeIfPresent(Int.self, forKey: .maximumDelayMilliseconds) ?? 2_000
    )
  }
}

public struct GatewayExecuteParams: Codable, Equatable, Sendable {
  public var protocolVersion: String
  public var vendor: GatewayVendor
  public var model: String
  public var prompt: String
  public var systemPrompt: String?
  public var workingDirectory: String?
  public var executable: String?
  public var arguments: [String]
  public var providerName: String?
  public var apiKeyEnvironment: String?
  public var baseURL: String?
  public var maxTokens: Int?
  public var sessionMode: GatewaySessionMode
  public var sessionId: String?
  public var cursorAPI: GatewayCursorAPIOptions?
  public var images: [GatewayImageInput]
  public var retryPolicy: GatewayRetryPolicy

  public init(
    protocolVersion: String = GatewayProtocolVersion.current,
    vendor: GatewayVendor,
    model: String,
    prompt: String,
    systemPrompt: String? = nil,
    workingDirectory: String? = nil,
    executable: String? = nil,
    arguments: [String] = [],
    providerName: String? = nil,
    apiKeyEnvironment: String? = nil,
    baseURL: String? = nil,
    maxTokens: Int? = nil,
    sessionMode: GatewaySessionMode = .new,
    sessionId: String? = nil,
    cursorAPI: GatewayCursorAPIOptions? = nil,
    images: [GatewayImageInput] = [],
    retryPolicy: GatewayRetryPolicy = GatewayRetryPolicy()
  ) {
    self.protocolVersion = protocolVersion
    self.vendor = vendor
    self.model = model
    self.prompt = prompt
    self.systemPrompt = systemPrompt
    self.workingDirectory = workingDirectory
    self.executable = executable
    self.arguments = arguments
    self.providerName = providerName
    self.apiKeyEnvironment = apiKeyEnvironment
    self.baseURL = baseURL
    self.maxTokens = maxTokens
    self.sessionMode = sessionMode
    self.sessionId = sessionId
    self.cursorAPI = cursorAPI
    self.images = images
    self.retryPolicy = retryPolicy
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case vendor
    case model
    case prompt
    case systemPrompt
    case workingDirectory
    case executable
    case arguments
    case providerName
    case apiKeyEnvironment
    case baseURL
    case maxTokens
    case sessionMode
    case sessionId
    case cursorAPI
    case images
    case retryPolicy
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      protocolVersion: try container.decodeIfPresent(String.self, forKey: .protocolVersion)
        ?? GatewayProtocolVersion.current,
      vendor: try container.decode(GatewayVendor.self, forKey: .vendor),
      model: try container.decode(String.self, forKey: .model),
      prompt: try container.decode(String.self, forKey: .prompt),
      systemPrompt: try container.decodeIfPresent(String.self, forKey: .systemPrompt),
      workingDirectory: try container.decodeIfPresent(String.self, forKey: .workingDirectory),
      executable: try container.decodeIfPresent(String.self, forKey: .executable),
      arguments: try container.decodeIfPresent([String].self, forKey: .arguments) ?? [],
      providerName: try container.decodeIfPresent(String.self, forKey: .providerName),
      apiKeyEnvironment: try container.decodeIfPresent(String.self, forKey: .apiKeyEnvironment),
      baseURL: try container.decodeIfPresent(String.self, forKey: .baseURL),
      maxTokens: try container.decodeIfPresent(Int.self, forKey: .maxTokens),
      sessionMode: try container.decodeIfPresent(GatewaySessionMode.self, forKey: .sessionMode) ?? .new,
      sessionId: try container.decodeIfPresent(String.self, forKey: .sessionId),
      cursorAPI: try container.decodeIfPresent(GatewayCursorAPIOptions.self, forKey: .cursorAPI),
      images: try container.decodeIfPresent([GatewayImageInput].self, forKey: .images) ?? [],
      retryPolicy: try container.decodeIfPresent(GatewayRetryPolicy.self, forKey: .retryPolicy) ?? GatewayRetryPolicy()
    )
  }
}

public struct GatewayReadinessParams: Codable, Equatable, Sendable {
  public var protocolVersion: String
  public var vendor: GatewayVendor
  public var executable: String?
  public var apiKeyEnvironment: String?

  public init(
    protocolVersion: String = GatewayProtocolVersion.current,
    vendor: GatewayVendor,
    executable: String? = nil,
    apiKeyEnvironment: String? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.vendor = vendor
    self.executable = executable
    self.apiKeyEnvironment = apiKeyEnvironment
  }
}

// MARK: - Model catalog

public struct GatewayModelCatalogParams: Codable, Equatable, Sendable {
  public var protocolVersion: String
  public var vendor: GatewayVendor
  public var apiKeyEnvironment: String?
  public var baseURL: String?

  public init(
    protocolVersion: String = GatewayProtocolVersion.current,
    vendor: GatewayVendor,
    apiKeyEnvironment: String? = nil,
    baseURL: String? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.vendor = vendor
    self.apiKeyEnvironment = apiKeyEnvironment
    self.baseURL = baseURL
  }
}

/// Cost per token for one model, using LiteLLM's field naming
/// (`input_cost_per_token` etc. from `model_prices_and_context_window.json`).
/// ACP defines no per-model pricing (its only price type is the
/// session-cumulative `Cost`), so this is a gateway extension; `currency`
/// follows ACP `Cost.currency`'s ISO 4217 convention. All cost fields are
/// optional: pricing is best-effort metadata and its absence must never
/// block a gateway feature.
public struct GatewayModelPricing: Codable, Equatable, Sendable {
  /// ISO 4217 currency code applying to every cost field.
  public var currency: String
  public var inputCostPerToken: Double?
  public var outputCostPerToken: Double?
  public var cacheReadInputTokenCost: Double?
  public var cacheCreationInputTokenCost: Double?

  public init(
    currency: String = "USD",
    inputCostPerToken: Double? = nil,
    outputCostPerToken: Double? = nil,
    cacheReadInputTokenCost: Double? = nil,
    cacheCreationInputTokenCost: Double? = nil
  ) {
    self.currency = currency
    self.inputCostPerToken = inputCostPerToken
    self.outputCostPerToken = outputCostPerToken
    self.cacheReadInputTokenCost = cacheReadInputTokenCost
    self.cacheCreationInputTokenCost = cacheCreationInputTokenCost
  }
}

/// Where the pricing attached to a model catalog came from.
public enum GatewayModelPricingSource: String, Codable, Sendable {
  /// Fetched from the LiteLLM pricing database over the network.
  case liteLLMRemote = "litellm-remote"
  /// Served from the on-disk copy of an earlier LiteLLM fetch.
  case liteLLMCache = "litellm-cache"
  /// Fetched from the fallback pricing table published in the
  /// agent-gateway GitHub repository.
  case fallbackTableRemote = "fallback-table-remote"
  /// Served from the on-disk copy of an earlier fallback-table fetch.
  case fallbackTableCache = "fallback-table-cache"
}

public struct GatewayModelInfo: Codable, Equatable, Sendable {
  public var modelId: String
  public var name: String?
  public var description: String?
  public var pricing: GatewayModelPricing?

  public init(
    modelId: String,
    name: String? = nil,
    description: String? = nil,
    pricing: GatewayModelPricing? = nil
  ) {
    self.modelId = modelId
    self.name = name
    self.description = description
    self.pricing = pricing
  }
}

public struct GatewayModelCatalogResult: Codable, Equatable, Sendable {
  public var protocolVersion: String
  public var vendor: GatewayVendor
  public var models: [GatewayModelInfo]
  public var pricingSource: GatewayModelPricingSource?

  public init(
    protocolVersion: String = GatewayProtocolVersion.current,
    vendor: GatewayVendor,
    models: [GatewayModelInfo],
    pricingSource: GatewayModelPricingSource? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.vendor = vendor
    self.models = models
    self.pricingSource = pricingSource
  }
}

public enum GatewayReadinessStatus: String, Codable, Sendable {
  case ready
  case unavailable
}

public struct GatewayReadinessResult: Codable, Equatable, Sendable {
  public var protocolVersion: String
  public var vendor: GatewayVendor
  public var status: GatewayReadinessStatus
  public var detail: String

  public init(
    protocolVersion: String = GatewayProtocolVersion.current,
    vendor: GatewayVendor,
    status: GatewayReadinessStatus,
    detail: String
  ) {
    self.protocolVersion = protocolVersion
    self.vendor = vendor
    self.status = status
    self.detail = detail
  }
}

public struct GatewayUsage: Codable, Equatable, Sendable {
  public var inputTokens: Int?
  public var outputTokens: Int?
  public var totalTokens: Int?

  public init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.totalTokens = totalTokens
  }

  /// Combines partial usage reports field-wise; newer fields win. Vendors
  /// split usage across events (e.g. Anthropic reports input tokens on
  /// `message_start` and output tokens on `message_delta`), so replacing
  /// whole values would lose counts. Derives the total when both sides
  /// are known but no vendor total was reported.
  public static func merge(_ older: GatewayUsage?, _ newer: GatewayUsage?) -> GatewayUsage? {
    guard older != nil || newer != nil else { return nil }
    var merged = older ?? GatewayUsage()
    merged.inputTokens = newer?.inputTokens ?? merged.inputTokens
    merged.outputTokens = newer?.outputTokens ?? merged.outputTokens
    merged.totalTokens = newer?.totalTokens ?? merged.totalTokens
    if merged.totalTokens == nil, let input = merged.inputTokens, let output = merged.outputTokens {
      merged.totalTokens = input + output
    }
    return merged
  }
}

public struct GatewayExecuteResult: Codable, Equatable, Sendable {
  public var protocolVersion: String
  public var vendor: GatewayVendor
  public var model: String
  public var text: String
  public var exitCode: Int32?
  public var usage: GatewayUsage?
  public var sessionId: String?

  public init(
    protocolVersion: String = GatewayProtocolVersion.current,
    vendor: GatewayVendor,
    model: String,
    text: String,
    exitCode: Int32? = nil,
    usage: GatewayUsage? = nil,
    sessionId: String? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.vendor = vendor
    self.model = model
    self.text = text
    self.exitCode = exitCode
    self.usage = usage
    self.sessionId = sessionId
  }
}

public struct GatewayRPCError: Codable, Equatable, Error, Sendable {
  public var code: Int
  public var message: String

  public init(code: Int, message: String) {
    self.code = code
    self.message = message
  }
}
