import Foundation

public enum GatewayProtocolVersion {
  public static let current = "1.0"
  public static let jsonRPC = "2.0"
}

public enum GatewayVendor: String, Codable, CaseIterable, Sendable {
  case claudeCode = "claude-code"
  case codex
  case cursor
  case openAI = "openai"
  case anthropic
  case gemini
  case openRouter = "openrouter"

  public var isCLI: Bool {
    switch self {
    case .claudeCode, .codex, .cursor:
      true
    case .openAI, .anthropic, .gemini, .openRouter:
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
    maxTokens: Int? = nil
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
  }
}

public struct GatewayRPCRequest: Codable, Equatable, Sendable {
  public var jsonrpc: String
  public var id: String
  public var method: String
  public var params: GatewayExecuteParams

  public init(id: String, params: GatewayExecuteParams) {
    self.jsonrpc = GatewayProtocolVersion.jsonRPC
    self.id = id
    self.method = "agent/execute"
    self.params = params
  }
}

public struct GatewayStreamEvent: Codable, Equatable, Sendable {
  public var requestId: String
  public var sequence: Int
  public var vendor: GatewayVendor
  public var type: String
  public var channel: GatewayEventChannel
  public var textDelta: String?
  public var textSnapshot: String?
  public var vendorPayload: String?

  public init(
    requestId: String,
    sequence: Int,
    vendor: GatewayVendor,
    type: String,
    channel: GatewayEventChannel,
    textDelta: String? = nil,
    textSnapshot: String? = nil,
    vendorPayload: String? = nil
  ) {
    self.requestId = requestId
    self.sequence = sequence
    self.vendor = vendor
    self.type = type
    self.channel = channel
    self.textDelta = textDelta
    self.textSnapshot = textSnapshot
    self.vendorPayload = vendorPayload
  }
}

public struct GatewayRPCNotification: Codable, Equatable, Sendable {
  public var jsonrpc: String
  public var method: String
  public var params: GatewayStreamEvent

  public init(event: GatewayStreamEvent) {
    self.jsonrpc = GatewayProtocolVersion.jsonRPC
    self.method = "agent/event"
    self.params = event
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
}

public struct GatewayExecuteResult: Codable, Equatable, Sendable {
  public var protocolVersion: String
  public var vendor: GatewayVendor
  public var model: String
  public var text: String
  public var exitCode: Int32?
  public var usage: GatewayUsage?

  public init(
    protocolVersion: String = GatewayProtocolVersion.current,
    vendor: GatewayVendor,
    model: String,
    text: String,
    exitCode: Int32? = nil,
    usage: GatewayUsage? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.vendor = vendor
    self.model = model
    self.text = text
    self.exitCode = exitCode
    self.usage = usage
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

public struct GatewayRPCResponse: Codable, Equatable, Sendable {
  public var jsonrpc: String
  public var id: String
  public var result: GatewayExecuteResult?
  public var error: GatewayRPCError?

  public init(id: String, result: GatewayExecuteResult) {
    self.jsonrpc = GatewayProtocolVersion.jsonRPC
    self.id = id
    self.result = result
    self.error = nil
  }

  public init(id: String, error: GatewayRPCError) {
    self.jsonrpc = GatewayProtocolVersion.jsonRPC
    self.id = id
    self.result = nil
    self.error = error
  }
}
