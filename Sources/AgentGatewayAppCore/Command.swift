import AgentGateway
import Foundation

public struct AppCommand: Sendable {
  public enum Error: Swift.Error, Equatable, Sendable {
    case unknownArgument(String)
    case missingValue(String)
  }

  public let arguments: [String]

  public init(arguments: [String]) {
    self.arguments = arguments
  }

  public func run() throws -> String {
    if arguments.contains("--version") {
      return Version.current
    }

    if arguments.contains("--help") || arguments.contains("-h") {
      return usage
    }

    if arguments.first == "server" || arguments.first == "client" || arguments.first == "readiness" {
      return ""
    }

    if let firstUnknown = arguments.first(where: { $0.hasPrefix("-") }) {
      throw Error.unknownArgument(firstUnknown)
    }

    return usage
  }

  public func runStreaming() async throws -> Int32 {
    switch arguments.first {
    case "server":
      return await GatewayJSONLServer().serveStandardIO()
    case "client":
      let request = try clientRequest(Array(arguments.dropFirst()))
      return try GatewaySubprocessClient().run(request: request)
    case "readiness":
      let request = try readinessRequest(Array(arguments.dropFirst()))
      return try GatewaySubprocessClient().run(request: request)
    default:
      return 0
    }
  }

  public var usage: String {
    """
    Usage: agent-gateway <command> [options]

      agent-gateway server
      agent-gateway client --vendor <vendor> --model <model> --prompt <text> [options] [-- <vendor-args>]
      agent-gateway readiness --vendor <vendor> [--executable <path>] [--api-key-environment <name>]
      agent-gateway --help

    Vendors: claude-code, codex, cursor, cursor-api, openai, anthropic, gemini, openrouter

    Protocol: JSON-RPC 2.0-shaped messages, one JSON object per line. The server
    reads agent/execute requests from stdin and writes agent/event notifications
    followed by one terminal response to stdout. Diagnostics use stderr only.
    """
  }

  func clientRequest(_ arguments: [String]) throws -> GatewayRPCRequest {
    var options = GatewayClientOptions()
    var vendorArguments: [String] = []
    var index = 0
    while index < arguments.count {
      if arguments[index] == "--" {
        vendorArguments = Array(arguments.dropFirst(index + 1))
        break
      }
      let key = arguments[index]
      guard key.hasPrefix("--") else { throw Error.unknownArgument(key) }
      guard index + 1 < arguments.count else { throw Error.missingValue(key) }
      try options.assign(key: key, value: arguments[index + 1])
      index += 2
    }
    guard let vendorValue = options.vendor, let vendor = GatewayVendor(rawValue: vendorValue) else {
      throw Error.missingValue("--vendor")
    }
    guard let model = options.model else { throw Error.missingValue("--model") }
    guard let prompt = options.prompt else { throw Error.missingValue("--prompt") }
    return GatewayRPCRequest(
      id: UUID().uuidString,
      params: GatewayExecuteParams(
        vendor: vendor,
        model: model,
        prompt: prompt,
        systemPrompt: options.systemPrompt,
        workingDirectory: options.workingDirectory,
        executable: options.executable,
        arguments: vendorArguments,
        providerName: options.providerName,
        apiKeyEnvironment: options.apiKeyEnvironment,
        baseURL: options.baseURL,
        maxTokens: options.maxTokens,
        sessionMode: options.sessionId == nil ? .new : .reuse,
        sessionId: options.sessionId,
        cursorAPI: options.cursorAPIOptions
      )
    )
  }

  func readinessRequest(_ arguments: [String]) throws -> GatewayReadinessRPCRequest {
    var options = GatewayClientOptions()
    var index = 0
    while index < arguments.count {
      let key = arguments[index]
      guard key.hasPrefix("--") else { throw Error.unknownArgument(key) }
      guard index + 1 < arguments.count else { throw Error.missingValue(key) }
      try options.assign(key: key, value: arguments[index + 1])
      index += 2
    }
    guard let vendorValue = options.vendor, let vendor = GatewayVendor(rawValue: vendorValue) else {
      throw Error.missingValue("--vendor")
    }
    return GatewayReadinessRPCRequest(
      id: UUID().uuidString,
      params: GatewayReadinessParams(
        vendor: vendor,
        executable: options.executable,
        apiKeyEnvironment: options.apiKeyEnvironment
      )
    )
  }
}

struct GatewayClientOptions: Equatable, Sendable {
  var vendor: String?
  var model: String?
  var prompt: String?
  var systemPrompt: String?
  var workingDirectory: String?
  var executable: String?
  var providerName: String?
  var apiKeyEnvironment: String?
  var baseURL: String?
  var maxTokens: Int?
  var sessionId: String?
  var cursorRepositoryURL: String?
  var cursorStartingRef: String?
  var cursorWorkOnCurrentBranch: Bool?
  var cursorAutoCreatePR: Bool?

  var cursorAPIOptions: GatewayCursorAPIOptions? {
    guard cursorRepositoryURL != nil || cursorStartingRef != nil
      || cursorWorkOnCurrentBranch != nil || cursorAutoCreatePR != nil else { return nil }
    return GatewayCursorAPIOptions(
      repositoryURL: cursorRepositoryURL,
      startingRef: cursorStartingRef,
      workOnCurrentBranch: cursorWorkOnCurrentBranch,
      autoCreatePR: cursorAutoCreatePR
    )
  }

  mutating func assign(key: String, value: String) throws {
    switch key {
    case "--vendor": vendor = value
    case "--model": model = value
    case "--prompt": prompt = value
    case "--system": systemPrompt = value
    case "--working-directory": workingDirectory = value
    case "--executable": executable = value
    case "--provider-name": providerName = value
    case "--api-key-environment": apiKeyEnvironment = value
    case "--base-url": baseURL = value
    case "--max-tokens": maxTokens = Int(value)
    case "--session-id": sessionId = value
    case "--cursor-repository-url": cursorRepositoryURL = value
    case "--cursor-starting-ref": cursorStartingRef = value
    case "--cursor-work-on-current-branch": cursorWorkOnCurrentBranch = Bool(value)
    case "--cursor-auto-create-pr": cursorAutoCreatePR = Bool(value)
    default: throw AppCommand.Error.unknownArgument(key)
    }
  }
}
