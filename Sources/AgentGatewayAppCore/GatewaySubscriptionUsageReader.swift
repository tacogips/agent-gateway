import AgentGateway
import Foundation

/// Reads the subscription rate-limit usage reported by a CLI vendor. The
/// vendor CLI answers through its own programmatic interface with its own
/// sign-in: Claude Code's stream-json `get_usage` control request and the
/// Codex app-server `account/rateLimits/read` method.
public protocol GatewaySubscriptionUsageReading: Sendable {
  func subscriptionUsage(_ params: GatewaySubscriptionUsageParams) async throws -> GatewaySubscriptionUsageResult
}

/// Error code for vendors that do not report subscription usage.
public let gatewaySubscriptionUsageUnsupportedCode = -32040
/// Error code for a vendor CLI that is missing, fails, or answers invalidly.
public let gatewaySubscriptionUsageFailureCode = -32041

extension ProductionGatewayExecutor: GatewaySubscriptionUsageReading {
  /// Spawns the vendor CLI as an interactive child that is terminated after
  /// it answers, so `processRunner` (which closes stdin after writing) is
  /// not used. macOS and Linux only.
  public func subscriptionUsage(_ params: GatewaySubscriptionUsageParams) async throws -> GatewaySubscriptionUsageResult {
    guard params.protocolVersion == GatewayProtocolVersion.current else {
      throw GatewayRPCError(code: -32602, message: "unsupported protocol version '\(params.protocolVersion)'")
    }
    let exchange = try subscriptionUsageExchange(params.vendor)
    let timeout = params.timeoutSeconds ?? 60
    guard timeout.isFinite, timeout > 0, timeout < Double(Int64.max) / 1_000_000_000 else {
      throw GatewayRPCError(code: -32602, message: "timeoutSeconds must be a positive number")
    }
    let executable = params.executable ?? defaultGatewayExecutable(params.vendor)
    guard let resolved = resolveGatewayExecutable(executable, environment: environment) else {
      throw GatewayRPCError(code: gatewaySubscriptionUsageFailureCode, message: "\(params.vendor.rawValue) executable unavailable")
    }
    let line: Data
    do {
      line = try await exchangeGatewayJSONLines(
      executable: resolved,
      arguments: exchange.arguments,
      environment: environment,
      requests: exchange.requests,
      timeoutSeconds: timeout,
      isResponse: exchange.isResponse
    )
    } catch let error as GatewayJSONLineExchangeError {
      let name = URL(fileURLWithPath: resolved).lastPathComponent
      let message: String
      switch error {
      case .launchFailed(let detail): message = "\(name) failed to launch: \(detail)"
      case .exitedWithoutAnswer(let tail):
        message = "\(name) exited without answering" + (tail.isEmpty ? "" : ": \(tail)")
      case .timedOut(let seconds): message = "\(name) did not answer within \(seconds)s"
      }
      throw GatewayRPCError(code: gatewaySubscriptionUsageFailureCode, message: message)
    }
    return try exchange.parse(line)
  }
}

struct GatewaySubscriptionUsageExchange {
  var arguments: [String]
  var requests: [Data]
  var isResponse: @Sendable (Data) -> Bool
  var parse: (Data) throws -> GatewaySubscriptionUsageResult
}

private let claudeUsageRequestId = "agent-gateway-subscription-usage"
private let codexUsageRequestId = 2

func subscriptionUsageExchange(_ vendor: GatewayVendor) throws -> GatewaySubscriptionUsageExchange {
  switch vendor {
  case .claudeCode:
    // No prompt is sent, so nothing is billed. Hooks and MCP servers are
    // skipped and no session transcript is written for this read.
    return GatewaySubscriptionUsageExchange(
      arguments: [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--strict-mcp-config", "--no-session-persistence", "--settings", #"{"disableAllHooks":true}"#
      ],
      requests: [try jsonLine([
        "type": "control_request", "request_id": claudeUsageRequestId,
        "request": ["subtype": "get_usage"]
      ])],
      isResponse: { line in
        guard let object = jsonObject(line), object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any] else { return false }
        return response["request_id"] as? String == claudeUsageRequestId
      },
      parse: parseClaudeSubscriptionUsage
    )
  case .codex:
    return GatewaySubscriptionUsageExchange(
      arguments: ["app-server"],
      requests: [
        try jsonLine(["id": 1, "method": "initialize", "params": [
          "clientInfo": ["name": "agent-gateway", "version": Version.current]
        ]]),
        try jsonLine(["method": "initialized"]),
        try jsonLine(["id": codexUsageRequestId, "method": "account/rateLimits/read"])
      ],
      isResponse: { line in
        guard let object = jsonObject(line) else { return false }
        return object["id"] as? Int == codexUsageRequestId && object["method"] == nil
      },
      parse: parseCodexSubscriptionUsage
    )
  case .cursor, .cursorAPI, .openAI, .anthropic, .gemini, .openRouter:
    throw GatewayRPCError(
      code: gatewaySubscriptionUsageUnsupportedCode,
      message: "\(vendor.rawValue) does not report subscription usage"
    )
  }
}

// MARK: - Claude Code

/// Parses the `control_response` to a `get_usage` control request.
func parseClaudeSubscriptionUsage(_ line: Data) throws -> GatewaySubscriptionUsageResult {
  guard let response = jsonObject(line)?["response"] as? [String: Any] else {
    throw invalidUsageResponse(.claudeCode)
  }
  if response["subtype"] as? String == "error" {
    let message = response["error"] as? String ?? "unknown error"
    throw GatewayRPCError(code: gatewaySubscriptionUsageFailureCode, message: "claude-code usage request failed: \(message)")
  }
  guard let usage = response["response"] as? [String: Any] else { throw invalidUsageResponse(.claudeCode) }
  let limits = usage["rate_limits"] as? [String: Any] ?? [:]
  func window(_ value: Any?, kind: GatewaySubscriptionUsageWindowKind, scope: String? = nil) -> GatewaySubscriptionUsageWindow? {
    guard let entry = value as? [String: Any], let used = (entry["utilization"] as? NSNumber)?.doubleValue else { return nil }
    return GatewaySubscriptionUsageWindow(
      kind: kind,
      scope: scope,
      windowMinutes: kind == .fiveHour ? 300 : 10080,
      usedPercent: used,
      resetsAt: (entry["resets_at"] as? String).flatMap(parseGatewayISO8601Date)
    )
  }
  var windows = [window(limits["five_hour"], kind: .fiveHour), window(limits["seven_day"], kind: .weekly)]
  // `model_scoped` lists every model-specific weekly limit; older CLIs only
  // report the fixed Opus and Sonnet fields.
  if let scoped = limits["model_scoped"] as? [Any] {
    windows += scoped.map { value in
      let entry = value as? [String: Any]
      return window(entry, kind: .weekly, scope: entry?["display_name"] as? String)
    }
  } else {
    windows += [
      window(limits["seven_day_opus"], kind: .weekly, scope: "Opus"),
      window(limits["seven_day_sonnet"], kind: .weekly, scope: "Sonnet")
    ]
  }
  let available = usage["rate_limits_available"] as? Bool ?? !limits.isEmpty
  return GatewaySubscriptionUsageResult(
    vendor: .claudeCode,
    planType: usage["subscription_type"] as? String,
    available: available,
    windows: available ? windows.compactMap { $0 } : []
  )
}

// MARK: - Codex

/// Parses the JSON-RPC response to `account/rateLimits/read`.
func parseCodexSubscriptionUsage(_ line: Data) throws -> GatewaySubscriptionUsageResult {
  guard let object = jsonObject(line) else { throw invalidUsageResponse(.codex) }
  if let error = object["error"] as? [String: Any] {
    let message = error["message"] as? String ?? "unknown error"
    throw GatewayRPCError(code: gatewaySubscriptionUsageFailureCode, message: "codex usage request failed: \(message)")
  }
  guard let result = object["result"] as? [String: Any] else { throw invalidUsageResponse(.codex) }
  let buckets = result["rateLimitsByLimitId"] as? [String: Any] ?? [:]
  // The default `codex` bucket is the plan-wide limit; other buckets are
  // listed after it in a stable order.
  let snapshots = buckets.isEmpty
    ? [result["rateLimits"] as? [String: Any]].compactMap { $0 }
    : buckets.keys.sorted { ($0 == "codex" ? 0 : 1, $0) < ($1 == "codex" ? 0 : 1, $1) }.compactMap { buckets[$0] as? [String: Any] }
  var windows: [GatewaySubscriptionUsageWindow] = []
  for snapshot in snapshots {
    let limitId = snapshot["limitId"] as? String
    let scope = limitId == nil || limitId == "codex" ? nil : (snapshot["limitName"] as? String ?? limitId)
    for key in ["primary", "secondary"] {
      guard let entry = snapshot[key] as? [String: Any],
            let used = (entry["usedPercent"] as? NSNumber)?.doubleValue else { continue }
      let minutes = (entry["windowDurationMins"] as? NSNumber)?.intValue
      windows.append(GatewaySubscriptionUsageWindow(
        kind: .classify(windowMinutes: minutes),
        scope: scope,
        windowMinutes: minutes,
        usedPercent: used,
        resetsAt: (entry["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
      ))
    }
  }
  let planType = snapshots.lazy.compactMap { $0["planType"] as? String }.first
  return GatewaySubscriptionUsageResult(vendor: .codex, planType: planType, available: !windows.isEmpty, windows: windows)
}

// MARK: - Helpers

private func invalidUsageResponse(_ vendor: GatewayVendor) -> GatewayRPCError {
  GatewayRPCError(code: gatewaySubscriptionUsageFailureCode, message: "\(vendor.rawValue) returned an invalid usage response")
}

private func jsonObject(_ line: Data) -> [String: Any]? {
  try? JSONSerialization.jsonObject(with: line) as? [String: Any]
}

private func jsonLine(_ object: [String: Any]) throws -> Data {
  try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
