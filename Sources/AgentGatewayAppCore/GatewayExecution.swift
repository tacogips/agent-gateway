import ACP
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

/// One streaming event observed while a vendor executes.
///
/// `textDelta` carries incremental text; `textSnapshot` carries a whole
/// message from snapshot-oriented vendors and may repeat text already
/// delivered as deltas (`GatewayACPStreamBridge` performs the dedup).
public struct GatewayEvent: Equatable, Sendable {
  public var type: String
  public var channel: GatewayEventChannel
  public var textDelta: String?
  public var textSnapshot: String?
  /// Raw vendor JSON line/SSE payload for consumers that need it verbatim.
  public var vendorPayload: String?
  public var sessionId: String?
  public var usage: GatewayUsage?

  public init(
    type: String,
    channel: GatewayEventChannel,
    textDelta: String? = nil,
    textSnapshot: String? = nil,
    vendorPayload: String? = nil,
    sessionId: String? = nil,
    usage: GatewayUsage? = nil
  ) {
    self.type = type
    self.channel = channel
    self.textDelta = textDelta
    self.textSnapshot = textSnapshot
    self.vendorPayload = vendorPayload
    self.sessionId = sessionId
    self.usage = usage
  }
}

public typealias GatewayEventEmitter = @Sendable (GatewayEvent) -> Void

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
    // EOF is observed on the reader side (empty availableData) so all bytes
    // flow through one handler in order; mixing readDataToEndOfFile with an
    // active readabilityHandler could interleave chunks and corrupt lines.
    let outputEOF = GatewayProcessExitWaiter()
    let errorEOF = GatewayProcessExitWaiter()
    output.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        outputEOF.complete()
      } else {
        collector.consume(data)
      }
    }
    standardError.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        errorEOF.complete()
      } else {
        errorCollector.consume(data)
      }
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
      await outputEOF.wait()
      await errorEOF.wait()
    } onCancel: {
      terminateGatewayProcessGroup(process)
    }
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
      usage: collector.finalUsage,
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
          emit(parsed.event(vendorPayload: payload))
          emittedEvent = true
          if let delta = parsed.delta {
            text.append(delta)
          }
          usage = GatewayUsage.merge(usage, parsed.usage)
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
    emit(GatewayEvent(
      type: "agent.created",
      channel: .assistant,
      textSnapshot: text,
      vendorPayload: payload,
      sessionId: object["id"] as? String
    ))
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
  let name = params.apiKeyEnvironment ?? defaultAPIKeyEnvironment(for: params.vendor)
  guard !name.isEmpty,
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
  let model = provider?.name == CustomProvider.name ? CustomProvider.modelName : params.model
  let executable = params.executable ?? defaultGatewayExecutable(params.vendor)
  switch params.vendor {
  case .codex:
    let overrides = AgentProviderRouting.codexConfigurationOverrides(for: provider)
      .flatMap { ["-c", $0] }
    let arguments = if params.sessionMode == .reuse, let sessionId = params.sessionId {
      ["exec", "resume", "--json", "--model", model] + overrides + params.arguments + ["--", sessionId, "-"]
    } else {
      ["exec", "--json", "--model", model] + overrides + params.arguments + ["-"]
    }
    return GatewayCLICommand(
      executable: executable,
      arguments: arguments,
      environment: [:],
      stdin: prompt
    )
  case .claudeCode:
    let routedEnvironment = try AgentProviderRouting.claudeCodeEnvironment(
      for: provider,
      runtimeEnvironment: ProcessInfo.processInfo.environment
    )
    // --include-partial-messages surfaces token-level stream_event deltas;
    // without it text would only arrive per completed assistant message.
    let arguments = ["-p", "--output-format", "stream-json", "--include-partial-messages", "--verbose"]
      + (params.sessionMode == .reuse ? params.sessionId.map { ["--resume", $0] } ?? [] : [])
      + ["--model", model] + params.arguments
    return GatewayCLICommand(
      executable: executable,
      arguments: arguments,
      environment: routedEnvironment,
      stdin: prompt
    )
  case .cursor:
    let arguments = ["--print", "--output-format", "stream-json"]
      + (params.sessionMode == .reuse ? params.sessionId.map { ["--resume", $0] } ?? [] : [])
      + ["--model", params.model] + params.arguments + ["--", prompt]
    return GatewayCLICommand(
      executable: executable,
      arguments: arguments,
      environment: [:],
      stdin: ""
    )
  case .openAI, .anthropic, .gemini, .openRouter, .cursorAPI:
    preconditionFailure("API vendor passed to CLI command builder")
  }
}

private func gatewayProviderConfiguration(_ params: GatewayExecuteParams) throws -> AgentProviderConfiguration? {
  guard let baseURL = params.baseURL else { return nil }
  do {
    if let name = params.providerName {
      return try AgentProviderConfiguration(name: name, baseUrl: baseURL, apiKeyEnv: params.apiKeyEnvironment)
    }
    guard [.codex, .claudeCode].contains(params.vendor) else { return nil }
    return try CustomProvider.configuration(
      baseURL: baseURL,
      apiKeyEnvironmentName: params.apiKeyEnvironment
    )
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
  private var buffer = ACPLineBuffer()
  private var text = ""
  private var usage: GatewayUsage?
  private var sessionId: String?

  init(vendor: GatewayVendor, emit: @escaping GatewayEventEmitter) {
    self.vendor = vendor
    self.emit = emit
  }

  var finalText: String {
    lock.withLock { text }
  }

  var finalUsage: GatewayUsage? {
    lock.withLock { usage }
  }

  var finalSessionId: String? {
    lock.withLock { sessionId }
  }

  func consume(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.withLock {
      for line in buffer.append(data) {
        consumeLine(String(data: line, encoding: .utf8) ?? "")
      }
    }
  }

  func finish() {
    lock.withLock {
      if let rest = buffer.flush() {
        consumeLine(String(data: rest, encoding: .utf8) ?? "")
      }
    }
  }

  private func consumeLine(_ line: String) {
    guard !line.isEmpty else { return }
    let parsed = parseVendorJSON(line, vendor: vendor)
    sessionId = parsed.sessionId ?? sessionId
    usage = GatewayUsage.merge(usage, parsed.usage)
    if let delta = parsed.delta, !delta.isEmpty {
      text.append(delta)
    } else if let snapshot = parsed.snapshot, !snapshot.isEmpty {
      // Whole-message snapshots are authoritative: the vendor's final
      // result event (claude-code `result`, codex `agent_message`)
      // replaces any partial delta accumulation.
      text = snapshot
    }
    emit(parsed.event(vendorPayload: line))
  }
}

struct ParsedVendorEvent {
  var type: String
  var delta: String?
  var snapshot: String?
  var thinkingDelta: String?
  var usage: GatewayUsage?
  var sessionId: String?

  /// Classifies this parse into the event delivered to emitters.
  func event(vendorPayload: String) -> GatewayEvent {
    var event = GatewayEvent(
      type: type,
      channel: .vendor,
      vendorPayload: vendorPayload,
      sessionId: sessionId,
      usage: usage
    )
    if let delta, !delta.isEmpty {
      event.channel = .assistant
      event.textDelta = delta
    } else if let snapshot, !snapshot.isEmpty {
      event.channel = .assistant
      event.textSnapshot = snapshot
    } else if let thinkingDelta, !thinkingDelta.isEmpty {
      event.channel = .thinking
      event.textDelta = thinkingDelta
    } else if usage != nil {
      event.channel = .usage
    }
    return event
  }
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
    if let item = object["item"] as? [String: Any] {
      switch item["type"] as? String {
      case "agent_message":
        return ParsedVendorEvent(type: type, snapshot: item["text"] as? String, sessionId: sessionId)
      case "reasoning":
        return ParsedVendorEvent(type: type, thinkingDelta: item["text"] as? String, sessionId: sessionId)
      default:
        return ParsedVendorEvent(type: type, sessionId: sessionId)
      }
    }
    // Legacy `content` snapshots and `turn.completed` usage reports.
    return ParsedVendorEvent(
      type: type,
      snapshot: object["content"] as? String,
      usage: parseUsage(object["usage"]),
      sessionId: sessionId
    )
  case .claudeCode:
    // `stream_event` wraps Anthropic SSE events when the CLI runs with
    // --include-partial-messages: token-level text/thinking deltas.
    if type == "stream_event" {
      let event = object["event"] as? [String: Any]
      let delta = event?["delta"] as? [String: Any]
      return ParsedVendorEvent(
        type: type,
        delta: delta?["text"] as? String,
        thinkingDelta: delta?["thinking"] as? String,
        sessionId: sessionId
      )
    }
    if type == "result" {
      return ParsedVendorEvent(
        type: type,
        snapshot: object["result"] as? String,
        usage: parseUsage(object["usage"]),
        sessionId: sessionId
      )
    }
    if let message = object["message"] as? [String: Any],
       let content = message["content"] as? [[String: Any]] {
      let value = content.compactMap { $0["text"] as? String }.joined()
      return ParsedVendorEvent(
        type: type,
        snapshot: value.isEmpty ? nil : value,
        usage: parseUsage(message["usage"]),
        sessionId: sessionId
      )
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
    // The Responses SSE stream reports several `delta`-carrying events;
    // only output_text belongs in the answer, reasoning summaries are
    // thoughts, and usage arrives on `response.completed`.
    let response = object["response"] as? [String: Any]
    return ParsedVendorEvent(
      type: type,
      delta: type == "response.output_text.delta" ? object["delta"] as? String : nil,
      thinkingDelta: type == "response.reasoning_summary_text.delta" ? object["delta"] as? String : nil,
      usage: parseUsage(object["usage"]) ?? parseUsage(response?["usage"]),
      sessionId: response?["id"] as? String ?? object["id"] as? String
    )
  case .openRouter:
    let choices = object["choices"] as? [[String: Any]]
    let delta = choices?.first?["delta"] as? [String: Any]
    return ParsedVendorEvent(
      type: type,
      delta: delta?["content"] as? String,
      thinkingDelta: delta?["reasoning"] as? String,
      usage: parseUsage(object["usage"]),
      sessionId: object["id"] as? String
    )
  case .anthropic:
    // input tokens arrive on message_start (nested in message), output
    // tokens on message_delta (top level); GatewayUsage.merge combines them.
    let delta = object["delta"] as? [String: Any]
    let message = object["message"] as? [String: Any]
    return ParsedVendorEvent(
      type: type,
      delta: delta?["text"] as? String,
      thinkingDelta: delta?["thinking"] as? String,
      usage: parseUsage(object["usage"]) ?? parseUsage(message?["usage"]),
      sessionId: message?["id"] as? String ?? object["id"] as? String
    )
  case .gemini:
    let candidates = object["candidates"] as? [[String: Any]]
    let content = candidates?.first?["content"] as? [String: Any]
    let parts = content?["parts"] as? [[String: Any]]
    return ParsedVendorEvent(
      type: type,
      delta: parts?.compactMap { $0["text"] as? String }.joined(),
      usage: parseUsage(object["usageMetadata"]),
      sessionId: object["responseId"] as? String
    )
  case .cursorAPI:
    return ParsedVendorEvent(type: type, snapshot: cursorAgentText(object), sessionId: sessionId)
  }
}

private func parseUsage(_ value: Any?) -> GatewayUsage? {
  guard let object = value as? [String: Any] else { return nil }
  let input = object["input_tokens"] as? Int
    ?? object["prompt_tokens"] as? Int
    ?? object["promptTokenCount"] as? Int
  let output = object["output_tokens"] as? Int
    ?? object["completion_tokens"] as? Int
    ?? object["candidatesTokenCount"] as? Int
  let total = object["total_tokens"] as? Int ?? object["totalTokenCount"] as? Int
  guard input != nil || output != nil || total != nil else { return nil }
  return GatewayUsage.merge(GatewayUsage(inputTokens: input, outputTokens: output, totalTokens: total), nil)
}
