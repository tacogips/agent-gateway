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

    if arguments.first == "server" || arguments.first == "client" {
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
    default:
      return 0
    }
  }

  public var usage: String {
    """
    Usage: agent-gateway <command> [options]

      agent-gateway server
      agent-gateway client --vendor <vendor> --model <model> --prompt <text> [options] [-- <vendor-args>]
      agent-gateway --help

    Vendors: claude-code, codex, cursor, openai, anthropic, gemini, openrouter

    Protocol: JSON-RPC 2.0-shaped messages, one JSON object per line. The server
    reads agent/execute requests from stdin and writes agent/event notifications
    followed by one terminal response to stdout. Diagnostics use stderr only.
    """
  }

  private func clientRequest(_ arguments: [String]) throws -> GatewayRPCRequest {
    var values: [String: String] = [:]
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
      values[key] = arguments[index + 1]
      index += 2
    }
    guard let vendorValue = values["--vendor"], let vendor = GatewayVendor(rawValue: vendorValue) else {
      throw Error.missingValue("--vendor")
    }
    guard let model = values["--model"] else { throw Error.missingValue("--model") }
    guard let prompt = values["--prompt"] else { throw Error.missingValue("--prompt") }
    return GatewayRPCRequest(
      id: UUID().uuidString,
      params: GatewayExecuteParams(
        vendor: vendor,
        model: model,
        prompt: prompt,
        systemPrompt: values["--system"],
        workingDirectory: values["--working-directory"],
        executable: values["--executable"],
        arguments: vendorArguments,
        providerName: values["--provider-name"],
        apiKeyEnvironment: values["--api-key-environment"],
        baseURL: values["--base-url"],
        maxTokens: values["--max-tokens"].flatMap(Int.init)
      )
    )
  }
}
