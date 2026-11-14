import ACP
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

    if ["server", "client", "readiness", "models"].contains(arguments.first) {
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
      let defaults = try serverDefaults(Array(arguments.dropFirst()))
      let server = ACPAgentServer(
        agent: GatewayACPAgent(defaults: defaults),
        transport: ACPFileHandleTransport.standardIO()
      )
      await server.serve()
      return 0
    case "client":
      let options = try clientOptions(Array(arguments.dropFirst()))
      return try await GatewayACPClientRunner().run(options: options)
    case "readiness":
      let params = try readinessParams(Array(arguments.dropFirst()))
      let result = ProductionGatewayExecutor().readiness(params)
      try writeJSONLine(result)
      return result.status == .ready ? 0 : 1
    case "models":
      let (params, pricingMode) = try modelCatalogParams(Array(arguments.dropFirst()))
      do {
        let catalog = try await ProductionGatewayExecutor().models(params)
        try writeJSONLine(await attachGatewayModelPricing(to: catalog, mode: pricingMode))
        return 0
      } catch let error as GatewayRPCError {
        FileHandle.standardError.write(
          Data("model listing failed (\(error.code)): \(error.message)\n".utf8)
        )
        return 1
      }
    default:
      return 0
    }
  }

  private func writeJSONLine<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(value) + Data([10]))
  }

  public var usage: String {
    """
    Usage: agent-gateway <command> [options]

      agent-gateway server [--vendor <vendor> --model <model>] [options]
      agent-gateway client --vendor <vendor> --model <model> --prompt <text> [options] [-- <vendor-args>]
      agent-gateway client --agent <path> --prompt <text> [-- <agent-args>]
      agent-gateway readiness --vendor <vendor> [--executable <path>] [--api-key-environment <name>]
      agent-gateway models --vendor <vendor> [--api-key-environment <name>] [--base-url <url>] [--pricing <auto|offline|off>]
      agent-gateway --help

    Vendors: claude-code, codex, cursor, cursor-api, openai, anthropic, gemini, openrouter

    Protocol: Agent Client Protocol (ACP, https://agentclientprotocol.com).
    `server` serves the ACP agent side over stdio: JSON-RPC 2.0 messages,
    one JSON object per line (initialize, session/new, session/prompt;
    streaming output as session/update notifications). Vendor and model can
    be fixed with server options or supplied per session by the ACP client
    via `_meta.agentGateway` on session/new. Diagnostics use stderr only.
    `client` spawns an ACP agent (this binary's server mode, or --agent) and
    echoes the agent's raw ACP JSONL messages to stdout. `--prompt -` reads
    the prompt text from stdin; repeatable `--image <path>` and
    `--image-data <mimeType>:<base64>` attach ACP image content blocks.
    `models` lists an API vendor's available models as JSON; API-vendor ACP
    sessions also advertise them in the session/new response (`models`) and
    accept session/set_model. CLI vendors do not support enumeration.
    `models` also attaches best-effort per-token pricing (ISO 4217 currency,
    USD) from the LiteLLM pricing database, falling back to the pricing
    table published in the agent-gateway GitHub repository when LiteLLM is
    unavailable. Both sources are cached on disk for ~24h so repeat runs
    make no requests. `--pricing auto` (default) resolves cache, remote,
    stale cache, then the fallback table the same way; `offline` uses only
    the caches; `off` skips pricing. Models without pricing are still
    listed, and pricing failures never fail the command.
    For Codex or Claude Code, --base-url selects the custom provider and
    defaults --model to custom; --provider-name can select a named provider.
    """
  }

  func modelCatalogParams(
    _ arguments: [String]
  ) throws -> (params: GatewayModelCatalogParams, pricingMode: GatewayModelPricingMode) {
    let (options, _) = try parseOptions(arguments)
    guard let vendorValue = options.vendor, let vendor = GatewayVendor(rawValue: vendorValue) else {
      throw Error.missingValue("--vendor")
    }
    var pricingMode = GatewayModelPricingMode.auto
    if let pricingValue = options.pricing {
      guard let mode = GatewayModelPricingMode(rawValue: pricingValue) else {
        throw Error.missingValue("--pricing")
      }
      pricingMode = mode
    }
    let params = GatewayModelCatalogParams(
      vendor: vendor,
      apiKeyEnvironment: options.apiKeyEnvironment,
      baseURL: options.baseURL
    )
    return (params, pricingMode)
  }

  /// Parses `--key value` pairs into `GatewayClientOptions`; everything
  /// after a literal `--` is returned untouched as vendor/agent arguments.
  private func parseOptions(
    _ arguments: [String]
  ) throws -> (options: GatewayClientOptions, vendorArguments: [String]) {
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
    return (options, vendorArguments)
  }

  func serverDefaults(_ arguments: [String]) throws -> GatewayAgentDefaults {
    let (options, vendorArguments) = try parseOptions(arguments)
    if let vendorValue = options.vendor, GatewayVendor(rawValue: vendorValue) == nil {
      throw Error.missingValue("--vendor")
    }
    return options.defaults(vendorArguments: vendorArguments)
  }

  func clientOptions(_ arguments: [String]) throws -> GatewayACPClientOptions {
    let (options, vendorArguments) = try parseOptions(arguments)
    let promptBlocksFromStdin = options.promptBlocksSource == "-"
    guard let prompt = options.prompt ?? (promptBlocksFromStdin ? "" : nil) else {
      throw Error.missingValue("--prompt")
    }
    let cwd = options.workingDirectory ?? FileManager.default.currentDirectoryPath
    if let agent = options.agentExecutable {
      return GatewayACPClientOptions(
        prompt: prompt,
        cwd: cwd,
        images: options.images,
        promptBlocksFromStdin: promptBlocksFromStdin,
        agentExecutable: agent,
        agentArguments: vendorArguments
      )
    }
    guard let vendorValue = options.vendor, GatewayVendor(rawValue: vendorValue) != nil else {
      throw Error.missingValue("--vendor")
    }
    guard options.resolvedModel != nil else { throw Error.missingValue("--model") }
    return GatewayACPClientOptions(
      prompt: prompt,
      cwd: cwd,
      images: options.images,
      promptBlocksFromStdin: promptBlocksFromStdin,
      serverOptions: options.serverArguments(vendorArguments: vendorArguments),
      sessionMeta: options.sessionMeta()
    )
  }

  func readinessParams(_ arguments: [String]) throws -> GatewayReadinessParams {
    let (options, _) = try parseOptions(arguments)
    guard let vendorValue = options.vendor, let vendor = GatewayVendor(rawValue: vendorValue) else {
      throw Error.missingValue("--vendor")
    }
    return GatewayReadinessParams(
      vendor: vendor,
      executable: options.executable,
      apiKeyEnvironment: options.apiKeyEnvironment
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
  var agentExecutable: String?
  var providerName: String?
  var apiKeyEnvironment: String?
  var baseURL: String?
  var maxTokens: Int?
  var sessionId: String?
  var images: [GatewayClientImageInput] = []
  var promptBlocksSource: String?
  var cursorRepositoryURL: String?
  var cursorStartingRef: String?
  var cursorWorkOnCurrentBranch: Bool?
  var cursorAutoCreatePR: Bool?
  var pricing: String?

  var usesImplicitCustomProvider: Bool {
    baseURL != nil
      && providerName == nil
      && [GatewayVendor.codex.rawValue, GatewayVendor.claudeCode.rawValue].contains(vendor)
  }

  var resolvedModel: String? {
    model ?? (usesImplicitCustomProvider ? CustomProvider.modelName : nil)
  }

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

  func defaults(vendorArguments: [String]) -> GatewayAgentDefaults {
    GatewayAgentDefaults(
      vendor: vendor.flatMap(GatewayVendor.init(rawValue:)),
      model: resolvedModel,
      systemPrompt: systemPrompt,
      executable: executable,
      arguments: vendorArguments,
      providerName: providerName,
      apiKeyEnvironment: apiKeyEnvironment,
      baseURL: baseURL,
      maxTokens: maxTokens,
      cursorAPI: cursorAPIOptions
    )
  }

  /// Recreates the `server` mode flags equivalent to these client options so
  /// the spawned agent starts with the same defaults.
  func serverArguments(vendorArguments: [String]) -> [String] {
    var arguments: [String] = []
    func flag(_ name: String, _ value: String?) {
      if let value { arguments += [name, value] }
    }
    flag("--vendor", vendor)
    flag("--model", resolvedModel)
    flag("--system", systemPrompt)
    flag("--executable", executable)
    flag("--provider-name", providerName)
    flag("--api-key-environment", apiKeyEnvironment)
    flag("--base-url", baseURL)
    flag("--max-tokens", maxTokens.map(String.init))
    flag("--cursor-repository-url", cursorRepositoryURL)
    flag("--cursor-starting-ref", cursorStartingRef)
    flag("--cursor-work-on-current-branch", cursorWorkOnCurrentBranch.map(String.init))
    flag("--cursor-auto-create-pr", cursorAutoCreatePR.map(String.init))
    if !vendorArguments.isEmpty {
      arguments += ["--"] + vendorArguments
    }
    return arguments
  }

  /// `meta` for session/new, carrying an existing vendor session to resume.
  func sessionMeta() -> ACPJSONValue? {
    guard let sessionId else { return nil }
    return .object(["agentGateway": .object(["vendorSessionId": .string(sessionId)])])
  }

  mutating func assign(key: String, value: String) throws {
    switch key {
    case "--vendor": vendor = value
    case "--model": model = value
    case "--prompt": prompt = value
    case "--system": systemPrompt = value
    case "--working-directory", "--cwd": workingDirectory = value
    case "--executable": executable = value
    case "--agent": agentExecutable = value
    case "--provider-name": providerName = value
    case "--api-key-environment": apiKeyEnvironment = value
    case "--base-url": baseURL = value
    case "--max-tokens": maxTokens = Int(value)
    case "--session-id": sessionId = value
    case "--prompt-blocks": promptBlocksSource = value
    case "--image": images.append(.filePath(value))
    case "--image-data":
      guard let separator = value.firstIndex(of: ":") else {
        throw AppCommand.Error.missingValue("--image-data expects <mimeType>:<base64>")
      }
      images.append(.data(
        mimeType: String(value[..<separator]),
        base64: String(value[value.index(after: separator)...])
      ))
    case "--pricing": pricing = value
    case "--cursor-repository-url": cursorRepositoryURL = value
    case "--cursor-starting-ref": cursorStartingRef = value
    case "--cursor-work-on-current-branch": cursorWorkOnCurrentBranch = Bool(value)
    case "--cursor-auto-create-pr": cursorAutoCreatePR = Bool(value)
    default: throw AppCommand.Error.unknownArgument(key)
    }
  }
}
