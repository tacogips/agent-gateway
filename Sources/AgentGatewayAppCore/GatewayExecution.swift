import AgentGateway
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public typealias GatewayEventEmitter = @Sendable (
  _ type: String,
  _ channel: GatewayEventChannel,
  _ textDelta: String?,
  _ textSnapshot: String?,
  _ vendorPayload: String?,
  _ sessionId: String?
) -> Void

public protocol GatewayExecuting: Sendable {
  func execute(_ params: GatewayExecuteParams, emit: @escaping GatewayEventEmitter) async throws -> GatewayExecuteResult
}

public protocol GatewayReadinessChecking: Sendable {
  func readiness(_ params: GatewayReadinessParams) -> GatewayReadinessResult
}

public struct ProductionGatewayExecutor: GatewayExecuting, GatewayReadinessChecking {
  public init() {}

  public func readiness(_ params: GatewayReadinessParams) -> GatewayReadinessResult {
    guard params.protocolVersion == GatewayProtocolVersion.current else {
      return GatewayReadinessResult(
        vendor: params.vendor,
        status: .unavailable,
        detail: "unsupported protocol version"
      )
    }
    if params.vendor.isCLI {
      let executable = params.executable ?? defaultGatewayExecutable(params.vendor)
      let available = resolveGatewayExecutable(executable) != nil
      return GatewayReadinessResult(
        vendor: params.vendor,
        status: available ? .ready : .unavailable,
        detail: available ? "executable available" : "executable unavailable"
      )
    }
    let key = params.apiKeyEnvironment ?? defaultAPIKeyEnvironment(for: params.vendor)
    let available = ProcessInfo.processInfo.environment[key]?.isEmpty == false
    return GatewayReadinessResult(
      vendor: params.vendor,
      status: available ? .ready : .unavailable,
      detail: available ? "credential available" : "credential unavailable"
    )
  }

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
    if params.vendor == .cursorAPI {
      return try await executeCursorAPI(params, emit: emit)
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
    let exitWaiter = GatewayProcessExitWaiter()
    process.terminationHandler = { _ in exitWaiter.complete() }
    do {
      try process.run()
    } catch {
      output.fileHandleForReading.readabilityHandler = nil
      standardError.fileHandleForReading.readabilityHandler = nil
      throw GatewayRPCError(code: -32001, message: "unable to start \(params.vendor.rawValue) client")
    }
    establishGatewayProcessGroup(process)
    input.fileHandleForWriting.write(Data(command.stdin.utf8))
    try? input.fileHandleForWriting.close()
    await withTaskCancellationHandler {
      await exitWaiter.wait()
    } onCancel: {
      terminateGatewayProcessGroup(process)
    }
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
      exitCode: process.terminationStatus,
      sessionId: collector.finalSessionId ?? params.sessionId
    )
  }

  private func executeAPI(
    _ params: GatewayExecuteParams,
    emit: @escaping GatewayEventEmitter
  ) async throws -> GatewayExecuteResult {
    let request = try makeAPIRequest(params)
    var attempt = 1
    while true {
      var emittedEvent = false
      do {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
          throw GatewayRPCError(code: -32010, message: "vendor did not return an HTTP response")
        }
        if gatewayHTTPStatusIsRetryable(http.statusCode), attempt < params.retryPolicy.maxAttempts {
          try await gatewayRetryDelay(policy: params.retryPolicy, attempt: attempt)
          attempt += 1
          continue
        }
        guard (200...299).contains(http.statusCode) else {
          var body = ""
          for try await line in bytes.lines { body.append(line) }
          let detail = redactGatewaySensitiveText(String(body.prefix(500)), params: params)
          throw GatewayRPCError(code: -32010, message: "vendor HTTP \(http.statusCode): \(detail)")
        }

        var text = ""
        var usage: GatewayUsage?
        var sessionId: String?
        for try await line in bytes.lines {
          guard line.hasPrefix("data:") else { continue }
          let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
          guard payload != "[DONE]", !payload.isEmpty else { continue }
          let parsed = parseVendorJSON(payload, vendor: params.vendor)
          if let delta = parsed.delta, !delta.isEmpty {
            text.append(delta)
            emit(parsed.type, .assistant, delta, nil, payload, parsed.sessionId)
          } else {
            emit(parsed.type, .vendor, nil, nil, payload, parsed.sessionId)
          }
          emittedEvent = true
          usage = parsed.usage ?? usage
          sessionId = parsed.sessionId ?? sessionId
        }
        return GatewayExecuteResult(
          vendor: params.vendor,
          model: params.model,
          text: text,
          usage: usage,
          sessionId: sessionId ?? params.sessionId
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as GatewayRPCError {
        throw error
      } catch {
        guard !emittedEvent, attempt < params.retryPolicy.maxAttempts else { throw error }
        try await gatewayRetryDelay(policy: params.retryPolicy, attempt: attempt)
        attempt += 1
      }
    }
  }

  private func executeCursorAPI(
    _ params: GatewayExecuteParams,
    emit: @escaping GatewayEventEmitter
  ) async throws -> GatewayExecuteResult {
    let request = try makeAPIRequest(params)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw GatewayRPCError(code: -32010, message: "Cursor did not return an HTTP response")
    }
    guard (200...299).contains(http.statusCode) else {
      let body = String(bytes: data.prefix(500), encoding: .utf8) ?? "invalid UTF-8 response"
      throw GatewayRPCError(
        code: -32010,
        message: "Cursor HTTP \(http.statusCode): \(redactGatewaySensitiveText(body, params: params))"
      )
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw GatewayRPCError(code: -32010, message: "Cursor returned invalid JSON")
    }
    let text = cursorAgentText(object)
    let payload = String(bytes: data, encoding: .utf8) ?? ""
    emit("agent.created", .assistant, nil, text, payload, object["id"] as? String)
    return GatewayExecuteResult(
      vendor: .cursorAPI,
      model: params.model,
      text: text,
      sessionId: object["id"] as? String
    )
  }
}

private func gatewayHTTPStatusIsRetryable(_ status: Int) -> Bool {
  status == 408 || status == 409 || status == 429 || (500...599).contains(status)
}

private func gatewayRetryDelay(policy: GatewayRetryPolicy, attempt: Int) async throws {
  let multiplier = 1 << min(max(0, attempt - 1), 16)
  let milliseconds = min(
    policy.maximumDelayMilliseconds,
    policy.initialDelayMilliseconds * multiplier
  )
  try await Task.sleep(for: .milliseconds(milliseconds))
}

private func defaultGatewayExecutable(_ vendor: GatewayVendor) -> String {
  switch vendor {
  case .codex: "codex"
  case .claudeCode: "claude"
  case .cursor: "cursor-agent"
  case .openAI, .anthropic, .gemini, .openRouter, .cursorAPI: ""
  }
}

private func resolveGatewayExecutable(_ executable: String) -> String? {
  if executable.contains("/") {
    return FileManager.default.isExecutableFile(atPath: executable) ? executable : nil
  }
  for directory in ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? [] {
    let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
      .appendingPathComponent(executable).path
    if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
  }
  return nil
}

private final class GatewayProcessExitWaiter: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var completed = false

  func wait() async {
    await withCheckedContinuation { continuation in
      let resumeImmediately = lock.withLock {
        if completed { return true }
        self.continuation = continuation
        return false
      }
      if resumeImmediately { continuation.resume() }
    }
  }

  func complete() {
    let continuation = lock.withLock {
      guard !completed else { return nil as CheckedContinuation<Void, Never>? }
      completed = true
      defer { self.continuation = nil }
      return self.continuation
    }
    continuation?.resume()
  }
}

private func establishGatewayProcessGroup(_ process: Process) {
  let identifier = process.processIdentifier
  guard identifier > 0 else { return }
  _ = setpgid(identifier, identifier)
}

private func terminateGatewayProcessGroup(_ process: Process) {
  let identifier = process.processIdentifier
  guard identifier > 0 else { return }
  if kill(-identifier, SIGTERM) != 0, process.isRunning {
    process.terminate()
  }
  DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
    guard process.isRunning else { return }
    _ = kill(-identifier, SIGKILL)
  }
}

private func cursorAgentText(_ object: [String: Any]) -> String {
  if let result = object["result"] as? String, !result.isEmpty { return result }
  return [
    (object["id"] as? String).map { "Cursor agent \($0)" },
    (object["status"] as? String).map { "status: \($0)" },
    (object["latestRunId"] as? String).map { "latest run: \($0)" },
    object["url"] as? String
  ].compactMap { $0 }.joined(separator: "\n")
}

private func redactGatewaySensitiveText(_ text: String, params: GatewayExecuteParams) -> String {
  let defaultName: String? = switch params.vendor {
  case .openAI: "OPENAI_API_KEY"
  case .anthropic: "ANTHROPIC_API_KEY"
  case .gemini: "GEMINI_API_KEY"
  case .openRouter: "OPENROUTER_API_KEY"
  case .cursorAPI: "CURSOR_API_KEY"
  case .claudeCode, .codex, .cursor: nil
  }
  guard let name = params.apiKeyEnvironment ?? defaultName,
        let value = ProcessInfo.processInfo.environment[name],
        !value.isEmpty else { return text }
  return text.replacingOccurrences(of: value, with: "<redacted>")
}

struct GatewayCLICommand {
  var executable: String
  var arguments: [String]
  var environment: [String: String]
  var stdin: String
}

func cliCommand(_ params: GatewayExecuteParams) throws -> GatewayCLICommand {
  let prompt = [params.systemPrompt, params.prompt].compactMap { $0 }.joined(separator: "\n\n")
  let provider = try gatewayProviderConfiguration(params)
  switch params.vendor {
  case .codex:
    let overrides = AgentProviderRouting.codexConfigurationOverrides(for: provider)
      .flatMap { ["-c", $0] }
    let arguments = if params.sessionMode == .reuse, let sessionId = params.sessionId {
      ["exec", "resume", "--json", "--model", params.model] + overrides + params.arguments + ["--", sessionId, "-"]
    } else {
      ["exec", "--json", "--model", params.model] + overrides + params.arguments + ["-"]
    }
    return GatewayCLICommand(
      executable: params.executable ?? "codex",
      arguments: arguments,
      environment: [:],
      stdin: prompt
    )
  case .claudeCode:
    let routedEnvironment = try AgentProviderRouting.claudeCodeEnvironment(
      for: provider,
      runtimeEnvironment: ProcessInfo.processInfo.environment
    )
    let arguments = ["-p", "--output-format", "stream-json", "--verbose"]
      + (params.sessionMode == .reuse ? params.sessionId.map { ["--resume", $0] } ?? [] : [])
      + ["--model", params.model] + params.arguments
    return GatewayCLICommand(
      executable: params.executable ?? "claude",
      arguments: arguments,
      environment: routedEnvironment,
      stdin: prompt
    )
  case .cursor:
    let arguments = ["--print", "--output-format", "stream-json"]
      + (params.sessionMode == .reuse ? params.sessionId.map { ["--resume", $0] } ?? [] : [])
      + ["--model", params.model] + params.arguments + ["--", prompt]
    return GatewayCLICommand(
      executable: params.executable ?? "cursor-agent",
      arguments: arguments,
      environment: [:],
      stdin: ""
    )
  case .openAI, .anthropic, .gemini, .openRouter, .cursorAPI:
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
  private var sessionId: String?

  init(vendor: GatewayVendor, emit: @escaping GatewayEventEmitter) {
    self.vendor = vendor
    self.emit = emit
  }

  var finalText: String {
    lock.withLock { text }
  }

  var finalSessionId: String? {
    lock.withLock { sessionId }
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
    sessionId = parsed.sessionId ?? sessionId
    if let delta = parsed.delta, !delta.isEmpty {
      text.append(delta)
      emit(parsed.type, .assistant, delta, nil, line, parsed.sessionId)
    } else if let snapshot = parsed.snapshot, !snapshot.isEmpty {
      text = snapshot
      emit(parsed.type, .assistant, nil, snapshot, line, parsed.sessionId)
    } else {
      emit(parsed.type, .vendor, nil, nil, line, parsed.sessionId)
    }
  }
}

struct ParsedVendorEvent {
  var type: String
  var delta: String?
  var snapshot: String?
  var usage: GatewayUsage?
  var sessionId: String?
}

func parseVendorJSON(_ line: String, vendor: GatewayVendor) -> ParsedVendorEvent {
  guard let data = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    return ParsedVendorEvent(type: "vendor.output")
  }
  let type = object["type"] as? String ?? "vendor.event"
  let sessionId = object["session_id"] as? String
    ?? object["sessionId"] as? String
    ?? object["thread_id"] as? String
    ?? object["threadId"] as? String
  switch vendor {
  case .codex:
    if let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message" {
      return ParsedVendorEvent(type: type, snapshot: item["text"] as? String, sessionId: sessionId)
    }
    return ParsedVendorEvent(type: type, snapshot: object["content"] as? String, sessionId: sessionId)
  case .claudeCode:
    if type == "result" {
      return ParsedVendorEvent(type: type, snapshot: object["result"] as? String, sessionId: sessionId)
    }
    if let message = object["message"] as? [String: Any],
       let content = message["content"] as? [[String: Any]] {
      let value = content.compactMap { $0["text"] as? String }.joined()
      return ParsedVendorEvent(type: type, snapshot: value.isEmpty ? nil : value, sessionId: sessionId)
    }
    return ParsedVendorEvent(type: type, sessionId: sessionId)
  case .cursor:
    return ParsedVendorEvent(
      type: type,
      delta: object["subtype"] as? String == "delta" ? object["text"] as? String : nil,
      snapshot: object["result"] as? String ?? object["text"] as? String,
      sessionId: sessionId
    )
  case .openAI:
    let response = object["response"] as? [String: Any]
    return ParsedVendorEvent(
      type: type,
      delta: object["delta"] as? String,
      usage: parseUsage(object["usage"]),
      sessionId: response?["id"] as? String ?? object["id"] as? String
    )
  case .openRouter:
    let choices = object["choices"] as? [[String: Any]]
    let delta = choices?.first?["delta"] as? [String: Any]
    return ParsedVendorEvent(
      type: type,
      delta: delta?["content"] as? String,
      usage: parseUsage(object["usage"]),
      sessionId: object["id"] as? String
    )
  case .anthropic:
    let delta = object["delta"] as? [String: Any]
    let message = object["message"] as? [String: Any]
    return ParsedVendorEvent(
      type: type,
      delta: delta?["text"] as? String,
      usage: parseUsage(object["usage"]),
      sessionId: message?["id"] as? String ?? object["id"] as? String
    )
  case .gemini:
    let candidates = object["candidates"] as? [[String: Any]]
    let content = candidates?.first?["content"] as? [String: Any]
    let parts = content?["parts"] as? [[String: Any]]
    return ParsedVendorEvent(
      type: type,
      delta: parts?.compactMap { $0["text"] as? String }.joined(),
      sessionId: object["responseId"] as? String
    )
  case .cursorAPI:
    return ParsedVendorEvent(type: type, snapshot: cursorAgentText(object), sessionId: sessionId)
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
