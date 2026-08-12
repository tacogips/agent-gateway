import AgentGateway
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public typealias GatewayEventEmitter = @Sendable (
  _ type: String,
  _ channel: GatewayEventChannel,
  _ textDelta: String?,
  _ textSnapshot: String?,
  _ vendorPayload: String?
) -> Void

public protocol GatewayExecuting: Sendable {
  func execute(_ params: GatewayExecuteParams, emit: @escaping GatewayEventEmitter) async throws -> GatewayExecuteResult
}

public struct ProductionGatewayExecutor: GatewayExecuting {
  public init() {}

  public func execute(
    _ params: GatewayExecuteParams,
    emit: @escaping GatewayEventEmitter
  ) async throws -> GatewayExecuteResult {
    guard params.protocolVersion == GatewayProtocolVersion.current else {
      throw GatewayRPCError(code: -32602, message: "unsupported protocol version '\(params.protocolVersion)'")
    }
    if params.vendor.isCLI {
      return try await executeCLI(params, emit: emit)
    }
    return try await executeAPI(params, emit: emit)
  }

  private func executeCLI(
    _ params: GatewayExecuteParams,
    emit: @escaping GatewayEventEmitter
  ) async throws -> GatewayExecuteResult {
    let command = try cliCommand(params)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command.executable] + command.arguments
    process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, routedValue in routedValue }
    process.currentDirectoryURL = params.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
    let input = Pipe()
    let output = Pipe()
    let standardError = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = standardError

    let collector = GatewayProcessCollector(vendor: params.vendor, emit: emit)
    let errorCollector = GatewayDataCollector()
    output.fileHandleForReading.readabilityHandler = { handle in
      collector.consume(handle.availableData)
    }
    standardError.fileHandleForReading.readabilityHandler = { handle in
      errorCollector.consume(handle.availableData)
    }
    do {
      try process.run()
    } catch {
      output.fileHandleForReading.readabilityHandler = nil
      standardError.fileHandleForReading.readabilityHandler = nil
      throw GatewayRPCError(code: -32001, message: "unable to start \(params.vendor.rawValue) client")
    }
    input.fileHandleForWriting.write(Data(command.stdin.utf8))
    try? input.fileHandleForWriting.close()
    process.waitUntilExit()
    output.fileHandleForReading.readabilityHandler = nil
    standardError.fileHandleForReading.readabilityHandler = nil
    collector.consume(output.fileHandleForReading.readDataToEndOfFile())
    errorCollector.consume(standardError.fileHandleForReading.readDataToEndOfFile())
    collector.finish()
    let stderr = String(data: errorCollector.data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      let detail = redactGatewaySensitiveText(stderr.trimmingCharacters(in: .whitespacesAndNewlines), params: params)
      throw GatewayRPCError(
        code: -32002,
        message: "\(params.vendor.rawValue) exited with status \(process.terminationStatus): \(detail)"
      )
    }
    return GatewayExecuteResult(
      vendor: params.vendor,
      model: params.model,
      text: collector.finalText,
      exitCode: process.terminationStatus
    )
  }

  private func executeAPI(
    _ params: GatewayExecuteParams,
    emit: @escaping GatewayEventEmitter
  ) async throws -> GatewayExecuteResult {
    let request = try makeAPIRequest(params)
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw GatewayRPCError(code: -32010, message: "vendor did not return an HTTP response")
    }
    guard (200...299).contains(http.statusCode) else {
      var body = ""
      for try await line in bytes.lines {
        body.append(line)
      }
      let detail = redactGatewaySensitiveText(String(body.prefix(500)), params: params)
      throw GatewayRPCError(code: -32010, message: "vendor HTTP \(http.statusCode): \(detail)")
    }

    var text = ""
    var usage: GatewayUsage?
    for try await line in bytes.lines {
      guard line.hasPrefix("data:") else {
        continue
      }
      let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
      guard payload != "[DONE]", !payload.isEmpty else {
        continue
      }
      let parsed = parseVendorJSON(payload, vendor: params.vendor)
      if let delta = parsed.delta, !delta.isEmpty {
        text.append(delta)
        emit(parsed.type, .assistant, delta, nil, payload)
      } else {
        emit(parsed.type, .vendor, nil, nil, payload)
      }
      usage = parsed.usage ?? usage
    }
    return GatewayExecuteResult(vendor: params.vendor, model: params.model, text: text, usage: usage)
  }
}

private func redactGatewaySensitiveText(_ text: String, params: GatewayExecuteParams) -> String {
  let defaultName: String? = switch params.vendor {
  case .openAI: "OPENAI_API_KEY"
  case .anthropic: "ANTHROPIC_API_KEY"
  case .gemini: "GEMINI_API_KEY"
  case .openRouter: "OPENROUTER_API_KEY"
  case .claudeCode, .codex, .cursor: nil
  }
  guard let name = params.apiKeyEnvironment ?? defaultName,
        let value = ProcessInfo.processInfo.environment[name],
        !value.isEmpty else { return text }
  return text.replacingOccurrences(of: value, with: "<redacted>")
}

private struct GatewayCLICommand {
  var executable: String
  var arguments: [String]
  var environment: [String: String]
  var stdin: String
}

private func cliCommand(_ params: GatewayExecuteParams) throws -> GatewayCLICommand {
  let prompt = [params.systemPrompt, params.prompt].compactMap { $0 }.joined(separator: "\n\n")
  let provider = try gatewayProviderConfiguration(params)
  switch params.vendor {
  case .codex:
    let overrides = AgentProviderRouting.codexConfigurationOverrides(for: provider)
      .flatMap { ["-c", $0] }
    return GatewayCLICommand(
      executable: params.executable ?? "codex",
      arguments: ["exec", "--json", "--model", params.model] + overrides + params.arguments + ["-"],
      environment: [:],
      stdin: prompt
    )
  case .claudeCode:
    let routedEnvironment = try AgentProviderRouting.claudeCodeEnvironment(
      for: provider,
      runtimeEnvironment: ProcessInfo.processInfo.environment
    )
    return GatewayCLICommand(
      executable: params.executable ?? "claude",
      arguments: ["-p", "--output-format", "stream-json", "--verbose", "--model", params.model] + params.arguments,
      environment: routedEnvironment,
      stdin: prompt
    )
  case .cursor:
    return GatewayCLICommand(
      executable: params.executable ?? "cursor-agent",
      arguments: ["--print", "--output-format", "stream-json", "--model", params.model]
        + params.arguments + ["--", prompt],
      environment: [:],
      stdin: ""
    )
  case .openAI, .anthropic, .gemini, .openRouter:
    preconditionFailure("API vendor passed to CLI command builder")
  }
}

private func gatewayProviderConfiguration(_ params: GatewayExecuteParams) throws -> AgentProviderConfiguration? {
  guard let name = params.providerName, let baseURL = params.baseURL else { return nil }
  do {
    return try AgentProviderConfiguration(name: name, baseUrl: baseURL, apiKeyEnv: params.apiKeyEnvironment)
  } catch {
    throw GatewayRPCError(code: -32602, message: "invalid provider configuration")
  }
}

private final class GatewayDataCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var collected = Data()

  var data: Data {
    lock.withLock { collected }
  }

  func consume(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.withLock {
      collected.append(data)
    }
  }
}

private final class GatewayProcessCollector: @unchecked Sendable {
  private let lock = NSLock()
  private let vendor: GatewayVendor
  private let emit: GatewayEventEmitter
  private var pending = Data()
  private var text = ""

  init(vendor: GatewayVendor, emit: @escaping GatewayEventEmitter) {
    self.vendor = vendor
    self.emit = emit
  }

  var finalText: String {
    lock.withLock { text }
  }

  func consume(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.withLock {
      pending.append(data)
      while let newline = pending.firstIndex(of: 10) {
        let lineData = pending[..<newline]
        pending.removeSubrange(...newline)
        consumeLine(String(data: lineData, encoding: .utf8) ?? "")
      }
    }
  }

  func finish() {
    lock.withLock {
      if !pending.isEmpty {
        consumeLine(String(data: pending, encoding: .utf8) ?? "")
        pending.removeAll()
      }
    }
  }

  private func consumeLine(_ line: String) {
    guard !line.isEmpty else { return }
    let parsed = parseVendorJSON(line, vendor: vendor)
    if let delta = parsed.delta, !delta.isEmpty {
      text.append(delta)
      emit(parsed.type, .assistant, delta, nil, line)
    } else if let snapshot = parsed.snapshot, !snapshot.isEmpty {
      text = snapshot
      emit(parsed.type, .assistant, nil, snapshot, line)
    } else {
      emit(parsed.type, .vendor, nil, nil, line)
    }
  }
}

struct ParsedVendorEvent {
  var type: String
  var delta: String?
  var snapshot: String?
  var usage: GatewayUsage?
}

func parseVendorJSON(_ line: String, vendor: GatewayVendor) -> ParsedVendorEvent {
  guard let data = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    return ParsedVendorEvent(type: "vendor.output")
  }
  let type = object["type"] as? String ?? "vendor.event"
  switch vendor {
  case .codex:
    if let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message" {
      return ParsedVendorEvent(type: type, snapshot: item["text"] as? String)
    }
    return ParsedVendorEvent(type: type, snapshot: object["content"] as? String)
  case .claudeCode:
    if type == "result" { return ParsedVendorEvent(type: type, snapshot: object["result"] as? String) }
    if let message = object["message"] as? [String: Any],
       let content = message["content"] as? [[String: Any]] {
      let value = content.compactMap { $0["text"] as? String }.joined()
      return ParsedVendorEvent(type: type, snapshot: value.isEmpty ? nil : value)
    }
    return ParsedVendorEvent(type: type)
  case .cursor:
    return ParsedVendorEvent(
      type: type,
      delta: object["subtype"] as? String == "delta" ? object["text"] as? String : nil,
      snapshot: object["result"] as? String ?? object["text"] as? String
    )
  case .openAI:
    return ParsedVendorEvent(type: type, delta: object["delta"] as? String, usage: parseUsage(object["usage"]))
  case .openRouter:
    let choices = object["choices"] as? [[String: Any]]
    let delta = choices?.first?["delta"] as? [String: Any]
    return ParsedVendorEvent(type: type, delta: delta?["content"] as? String, usage: parseUsage(object["usage"]))
  case .anthropic:
    let delta = object["delta"] as? [String: Any]
    return ParsedVendorEvent(type: type, delta: delta?["text"] as? String, usage: parseUsage(object["usage"]))
  case .gemini:
    let candidates = object["candidates"] as? [[String: Any]]
    let content = candidates?.first?["content"] as? [String: Any]
    let parts = content?["parts"] as? [[String: Any]]
    return ParsedVendorEvent(type: type, delta: parts?.compactMap { $0["text"] as? String }.joined())
  }
}

private func parseUsage(_ value: Any?) -> GatewayUsage? {
  guard let object = value as? [String: Any] else { return nil }
  let input = object["input_tokens"] as? Int ?? object["prompt_tokens"] as? Int
  let output = object["output_tokens"] as? Int ?? object["completion_tokens"] as? Int
  let derivedTotal: Int? = if let input, let output { input + output } else { nil }
  let total = object["total_tokens"] as? Int ?? derivedTotal
  return GatewayUsage(inputTokens: input, outputTokens: output, totalTokens: total)
}
