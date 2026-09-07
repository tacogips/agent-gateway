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
  /// Environment used to resolve vendor executables on `PATH`, read
  /// credential variables, and seed the child vendor process. Defaults to
  /// this process's environment; hosts that embed the gateway as a library
  /// pass a per-call environment so caller-scoped variables reach the vendor
  /// without mutating the host process.
  public let environment: [String: String]
  public let processRunner: any GatewayProcessRunning
  public let processOwnership: GatewayProcessOwnership

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    processRunner: any GatewayProcessRunning = POSIXGatewayProcessRunner(),
    processOwnership: GatewayProcessOwnership = .foregroundProcessGroup
  ) {
    self.environment = environment
    self.processRunner = processRunner
    self.processOwnership = processOwnership
  }

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
      let available = resolveGatewayExecutable(executable, environment: environment) != nil
      return GatewayReadinessResult(
        vendor: params.vendor,
        status: available ? .ready : .unavailable,
        detail: available ? "executable available" : "executable unavailable"
      )
    }
    let key = params.apiKeyEnvironment ?? defaultAPIKeyEnvironment(for: params.vendor)
    let available = environment[key]?.isEmpty == false
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
    let command = try cliCommand(params, environment: environment)
    guard processRunner.supportedOwnership.contains(processOwnership) else {
      throw GatewayProcessError.unsupportedOwnership(processOwnership)
    }
    let collector = GatewayProcessCollector(vendor: params.vendor, emit: emit)
    let result = try await processRunner.run(GatewayProcessRequest(
      executable: "/usr/bin/env", arguments: [command.executable] + command.arguments,
      environment: environment.merging(command.environment) { _, routedValue in routedValue },
      workingDirectory: params.workingDirectory, stdin: Data(command.stdin.utf8), ownership: processOwnership
    )) { output in
      if output.stream == .stdout { collector.consume(output.data) }
    }
    collector.finish()
    guard !result.outputTruncated else {
      throw GatewayRPCError(code: -32002, message: "\(params.vendor.rawValue) exceeded the process output limit")
    }
    let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
    guard result.exitCode == 0 else {
      let detail = redactGatewaySensitiveText(environment: environment, stderr.trimmingCharacters(in: .whitespacesAndNewlines), params: params)
      throw GatewayRPCError(
        code: -32002,
        message: "\(params.vendor.rawValue) exited with status \(result.exitCode): \(detail)"
      )
    }
    return GatewayExecuteResult(
      vendor: params.vendor,
      model: params.model,
      text: collector.finalText,
      exitCode: result.exitCode,
      usage: collector.finalUsage,
      sessionId: collector.finalSessionId ?? params.sessionId
    )
  }

  private func executeAPI(
    _ params: GatewayExecuteParams,
    emit: @escaping GatewayEventEmitter
  ) async throws -> GatewayExecuteResult {
    let request = try makeAPIRequest(params, environment: environment)
    var attempt = 1
    while true {
      var emittedEvent = false
      do {
        let (lines, http) = try await gatewayResponseLines(for: request)
        if gatewayHTTPStatusIsRetryable(http.statusCode), attempt < params.retryPolicy.maxAttempts {
          try await gatewayRetryDelay(policy: params.retryPolicy, attempt: attempt)
          attempt += 1
          continue
        }
        guard (200...299).contains(http.statusCode) else {
          var body = ""
          for try await line in lines { body.append(line) }
          let detail = redactGatewaySensitiveText(environment: environment, String(body.prefix(500)), params: params)
          throw GatewayRPCError(code: -32010, message: "vendor HTTP \(http.statusCode): \(detail)")
        }

        var text = ""
        var usage: GatewayUsage?
        var sessionId: String?
        for try await line in lines {
          guard line.hasPrefix("data:") else { continue }
          // `Substring.trimmingCharacters` is Darwin-only; go through String
          // so the SSE reader also builds on Linux.
          let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
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
    let request = try makeAPIRequest(params, environment: environment)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw GatewayRPCError(code: -32010, message: "Cursor did not return an HTTP response")
    }
    guard (200...299).contains(http.statusCode) else {
      let body = String(bytes: data.prefix(500), encoding: .utf8) ?? "invalid UTF-8 response"
      throw GatewayRPCError(
        code: -32010,
        message: "Cursor HTTP \(http.statusCode): \(redactGatewaySensitiveText(environment: environment, body, params: params))"
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

/// The response's lines, for the server-sent-event readers.
///
/// Darwin streams them as they arrive. swift-corelibs-foundation has no
/// streaming `URLSession` API, so on other platforms the body is read first and
/// its lines replayed: an API-vendor turn produces the same events and the same
/// result there, just not incrementally.
private func gatewayResponseLines(
  for request: URLRequest
) async throws -> (lines: AsyncThrowingStream<String, any Error>, response: HTTPURLResponse) {
  #if canImport(Darwin)
  let (bytes, response) = try await URLSession.shared.bytes(for: request)
  guard let http = response as? HTTPURLResponse else {
    throw GatewayRPCError(code: -32010, message: "vendor did not return an HTTP response")
  }
  let stream = AsyncThrowingStream<String, any Error> { continuation in
    let task = Task {
      do {
        for try await line in bytes.lines { continuation.yield(line) }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { _ in task.cancel() }
  }
  return (stream, http)
  #else
  let (data, response) = try await URLSession.shared.data(for: request)
  guard let http = response as? HTTPURLResponse else {
    throw GatewayRPCError(code: -32010, message: "vendor did not return an HTTP response")
  }
  let body = String(data: data, encoding: .utf8) ?? ""
  let stream = AsyncThrowingStream<String, any Error> { continuation in
    for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
      continuation.yield(String(line))
    }
    continuation.finish()
  }
  return (stream, http)
  #endif
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

private func resolveGatewayExecutable(
  _ executable: String,
  environment: [String: String] = ProcessInfo.processInfo.environment
) -> String? {
  if executable.contains("/") {
    return FileManager.default.isExecutableFile(atPath: executable) ? executable : nil
  }
  for directory in environment["PATH"]?.split(separator: ":") ?? [] {
    let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
      .appendingPathComponent(executable).path
    if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
  }
  return nil
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

private func redactGatewaySensitiveText(
  environment: [String: String],
  _ text: String,
  params: GatewayExecuteParams
) -> String {
  let name = params.apiKeyEnvironment ?? defaultAPIKeyEnvironment(for: params.vendor)
  guard !name.isEmpty,
        let value = environment[name],
        !value.isEmpty else { return text }
  return text.replacingOccurrences(of: value, with: "<redacted>")
}

struct GatewayCLICommand {
  var executable: String
  var arguments: [String]
  var environment: [String: String]
  var stdin: String
}

func cliCommand(
  _ params: GatewayExecuteParams,
  environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> GatewayCLICommand {
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
      runtimeEnvironment: environment
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
