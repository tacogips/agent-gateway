import ACP
import AgentGateway
import Foundation

/// Options for `agent-gateway client`: spawns an ACP agent (this executable's
/// `server` mode by default, or any external ACP agent) and runs one prompt
/// turn, echoing the raw ACP JSONL traffic received from the agent to stdout.
public struct GatewayACPClientOptions: Sendable {
  public var prompt: String
  public var cwd: String
  public var agentExecutable: String?
  public var agentArguments: [String]
  public var serverOptions: [String]
  public var sessionMeta: ACPJSONValue?

  public init(
    prompt: String,
    cwd: String,
    agentExecutable: String? = nil,
    agentArguments: [String] = [],
    serverOptions: [String] = [],
    sessionMeta: ACPJSONValue? = nil
  ) {
    self.prompt = prompt
    self.cwd = cwd
    self.agentExecutable = agentExecutable
    self.agentArguments = agentArguments
    self.serverOptions = serverOptions
    self.sessionMeta = sessionMeta
  }
}

public struct GatewayACPClientRunner: Sendable {
  public init() {}

  public func run(options: GatewayACPClientOptions) async throws -> Int32 {
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
    let client = ACPClientConnection(transport: transport)
    // The raw agent-to-client ACP messages are the CLI's stdout stream:
    // one JSON-RPC message per line (session/update notifications followed
    // by each request's response).
    await client.connection.setRawLineObserver { line, outgoing in
      guard !outgoing else { return }
      FileHandle.standardOutput.write(line + Data([10]))
    }
    await client.start()

    do {
      _ = try await client.initialize(
        ACPInitializeRequest(
          clientInfo: ACPImplementation(name: "agent-gateway-client", version: Version.current)
        )
      )
      let session = try await client.newSession(
        ACPNewSessionRequest(cwd: options.cwd, mcpServers: [], meta: options.sessionMeta)
      )
      let response = try await client.prompt(
        ACPPromptRequest(sessionId: session.sessionId, prompt: [.text(options.prompt)])
      )
      await client.stop()
      process.waitUntilExit()
      return response.stopReason == .endTurn ? 0 : 1
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
