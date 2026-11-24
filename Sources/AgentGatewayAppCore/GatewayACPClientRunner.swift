import ACP
import AgentGateway
import Foundation

/// Image inputs for `agent-gateway client`, resolved into ACP image content
/// blocks before the prompt turn.
public enum GatewayClientImageInput: Equatable, Sendable {
  case filePath(String)
  case data(mimeType: String, base64: String)
}

/// Options for `agent-gateway client`: spawns an ACP agent (this executable's
/// `server` mode by default, or any external ACP agent) and runs one prompt
/// turn, echoing the raw ACP JSONL traffic received from the agent to stdout.
public struct GatewayACPClientOptions: Sendable {
  /// `-` reads the prompt text from stdin.
  public var prompt: String
  public var cwd: String
  public var images: [GatewayClientImageInput]
  /// When true, stdin carries a JSON array of ACP content blocks that
  /// becomes the whole prompt; `prompt` and `images` are ignored.
  public var promptBlocksFromStdin: Bool
  public var agentExecutable: String?
  public var agentArguments: [String]
  public var serverOptions: [String]
  public var sessionMeta: ACPJSONValue?
  /// ACP protocol version to request. Version 2 falls back to version 1
  /// when the agent selects it.
  public var protocolVersion: Int
  /// How `session/request_permission` requests from the agent are answered.
  public var permissionPolicy: GatewayClientPermissionPolicy

  public init(
    prompt: String,
    cwd: String,
    images: [GatewayClientImageInput] = [],
    promptBlocksFromStdin: Bool = false,
    agentExecutable: String? = nil,
    agentArguments: [String] = [],
    serverOptions: [String] = [],
    sessionMeta: ACPJSONValue? = nil,
    protocolVersion: Int = ACPProtocol.versionV1,
    permissionPolicy: GatewayClientPermissionPolicy = .cancel
  ) {
    self.prompt = prompt
    self.cwd = cwd
    self.images = images
    self.promptBlocksFromStdin = promptBlocksFromStdin
    self.agentExecutable = agentExecutable
    self.agentArguments = agentArguments
    self.serverOptions = serverOptions
    self.sessionMeta = sessionMeta
    self.protocolVersion = protocolVersion
    self.permissionPolicy = permissionPolicy
  }
}

/// How the non-interactive `client` command answers an agent's
/// `session/request_permission`. There is no user to ask, so the answer is
/// a fixed policy.
public enum GatewayClientPermissionPolicy: String, Equatable, Sendable {
  /// Decline by policy with the `cancelled` outcome (default). The agent
  /// must not proceed with the operation.
  case cancel
  /// Select the first `allow_once` option, else the first `allow_always`.
  case allow
  /// Select the first `reject_once` option, else the first `reject_always`.
  case reject
}

/// Answers `session/request_permission`, the one request every ACP client
/// must handle in both protocol versions. The options and the response have
/// the same shape in v1 and v2, so one responder serves both.
public struct GatewayClientPermissionResponder: ACPClientDelegate {
  public var policy: GatewayClientPermissionPolicy

  public init(policy: GatewayClientPermissionPolicy = .cancel) {
    self.policy = policy
  }

  public func sessionUpdate(_ notification: ACPSessionNotification) async {}

  public func handleRequest(method: String, params: Data) async throws -> Data {
    guard method == ACPMethod.sessionRequestPermission else {
      throw ACPError.methodNotFound(method)
    }
    struct Params: Decodable {
      var options: [ACPPermissionOption]
    }
    let request = try ACPConnection.decodeParams(Params.self, from: params)
    return try ACPConnection.encodeResult(ACPRequestPermissionResponse(outcome: outcome(for: request.options)))
  }

  /// Only an option the agent offered is ever selected; when the policy's
  /// kinds are not offered the request is declined.
  func outcome(for options: [ACPPermissionOption]) -> ACPRequestPermissionResponse.Outcome {
    let preferredKinds: [String]
    switch policy {
    case .cancel: return .cancelled
    case .allow: preferredKinds = [ACPPermissionOption.allowOnce, ACPPermissionOption.allowAlways]
    case .reject: preferredKinds = [ACPPermissionOption.rejectOnce, ACPPermissionOption.rejectAlways]
    }
    for kind in preferredKinds {
      if let option = options.first(where: { $0.kind == kind }) {
        return .selected(optionId: option.optionId)
      }
    }
    return .cancelled
  }
}

public struct GatewayACPClientRunner: Sendable {
  public init() {}

  public func run(options: GatewayACPClientOptions) async throws -> Int32 {
    #if os(macOS) || os(Linux)
    let process = Process()
    if let agentExecutable = options.agentExecutable {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [agentExecutable] + options.agentArguments
    } else {
      process.executableURL = URL(fileURLWithPath: selfExecutablePath())
      process.arguments = ["server"] + options.serverOptions
    }
    let input = Pipe()
    let output = Pipe()
    let standardError = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = standardError
    standardError.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
      } else {
        FileHandle.standardError.write(data)
      }
    }
    try process.run()

    let transport = ACPFileHandleTransport(
      input: output.fileHandleForReading,
      output: input.fileHandleForWriting
    )
    let client = ACPClientConnection(
      transport: transport, delegate: GatewayClientPermissionResponder(policy: options.permissionPolicy)
    )
    // The raw agent-to-client ACP messages are the CLI's stdout stream:
    // one JSON-RPC message per line (session/update notifications followed
    // by each request's response).
    await client.connection.setRawLineObserver { line, outgoing in
      guard !outgoing else { return }
      FileHandle.standardOutput.write(line + Data([10]))
    }
    await client.start()

    do {
      let prompt = try promptBlocks(options)
      let succeeded = try await runTurn(client: client, options: options, prompt: prompt)
      await client.stop()
      process.waitUntilExit()
      return succeeded ? 0 : 1
    } catch {
      await client.stop()
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      if let acpError = error as? ACPError {
        FileHandle.standardError.write(Data("agent error \(acpError.code): \(acpError.message)\n".utf8))
        return 1
      }
      throw error
    }
    #else
    throw GatewayProcessError.launchFailed(ENOTSUP)
    #endif
  }
}

/// Runs initialize → session/new → one prompt turn in the requested
/// protocol version. Returns whether the turn ended with `end_turn`.
private func runTurn(
  client: ACPClientConnection, options: GatewayACPClientOptions, prompt: [ACPContentBlock]
) async throws -> Bool {
  let info = ACPImplementation(name: "agent-gateway-client", version: Version.current)
  if options.protocolVersion >= ACPProtocol.versionV2 {
    let negotiated = try await client.negotiate(
      ACPV2InitializeRequest(info: info), v1Fallback: ACPInitializeRequest(clientInfo: info)
    )
    if case .v2 = negotiated {
      let session = try await client.newSessionV2(
        ACPV2NewSessionRequest(cwd: options.cwd, meta: options.sessionMeta)
      )
      // In v2 the prompt response only acknowledges insertion; the turn
      // ends with the idle state update that carries the stop reason.
      let turn = try await client.promptTurnCollecting(
        ACPV2PromptRequest(sessionId: session.sessionId, prompt: prompt)
      )
      if turn.stopReason == .error, let error = turn.finalState.error {
        FileHandle.standardError.write(Data("agent error \(error.code): \(error.message)\n".utf8))
      }
      return turn.stopReason == .endTurn
    }
    // The agent selected v1: continue with the v1 lifecycle below.
  } else {
    _ = try await client.initialize(ACPInitializeRequest(clientInfo: info))
  }
  let session = try await client.newSession(
    ACPNewSessionRequest(cwd: options.cwd, mcpServers: [], meta: options.sessionMeta)
  )
  let response = try await client.prompt(ACPPromptRequest(sessionId: session.sessionId, prompt: prompt))
  return response.stopReason == .endTurn
}

private func promptBlocks(_ options: GatewayACPClientOptions) throws -> [ACPContentBlock] {
  if options.promptBlocksFromStdin {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    do {
      let blocks = try JSONDecoder().decode([ACPContentBlock].self, from: data)
      guard !blocks.isEmpty else { throw AppCommand.Error.missingValue("--prompt-blocks") }
      return blocks
    } catch let error as AppCommand.Error {
      throw error
    } catch {
      throw AppCommand.Error.missingValue("--prompt-blocks stdin must be a JSON array of ACP content blocks")
    }
  }
  let text: String
  if options.prompt == "-" {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let decoded = String(bytes: data, encoding: .utf8) else {
      throw AppCommand.Error.missingValue("--prompt")
    }
    text = decoded
  } else {
    text = options.prompt
  }
  do {
    return try [.text(text)] + gatewayImageContentBlocks(options.images)
  } catch let error as GatewayRPCError {
    throw AppCommand.Error.missingValue("--image: \(error.message)")
  }
}

/// Resolves image inputs into ACP image content blocks, loading and
/// validating file-backed images. Public so hosts that embed the gateway as a
/// library build prompts exactly the way `agent-gateway client` does instead
/// of reimplementing image loading.
public func gatewayImageContentBlocks(_ images: [GatewayClientImageInput]) throws -> [ACPContentBlock] {
  try images.map { image in
    switch image {
    case .data(let mimeType, let base64):
      return .image(ACPImageContent(data: base64, mimeType: mimeType))
    case .filePath(let path):
      let resolved = try loadGatewayImageFile(path)
      return .image(ACPImageContent(
        data: resolved.dataBase64,
        mimeType: resolved.mimeType,
        uri: URL(fileURLWithPath: path).absoluteString
      ))
    }
  }
}

/// Resolves this executable even when it was launched through a PATH lookup,
/// in which case argv[0] has no directory component.
private func selfExecutablePath() -> String {
  let argv0 = CommandLine.arguments[0]
  if argv0.contains("/") { return argv0 }
  for directory in ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? [] {
    let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
      .appendingPathComponent(argv0).path
    if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
  }
  return argv0
}
