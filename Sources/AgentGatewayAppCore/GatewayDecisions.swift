import AgentGateway
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol GatewayDeciding: Sendable {
  func decide(_ request: GatewayDecisionRequest) async throws -> GatewayDecisionResult
}

/// Jev uses OpenRouter's alpha Decisions endpoint, independently of chat/ACP sessions.
public struct GatewayDecisionClient: GatewayDeciding {
  public let environment: [String: String]
  public let apiKeyEnvironment: String
  /// Base URL includes `/api/alpha`; `decisions` is appended to it.
  public let baseURL: String
  public let retryPolicy: GatewayRetryPolicy
  private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    apiKeyEnvironment: String = "OPENROUTER_API_KEY",
    baseURL: String = "https://openrouter.ai/api/alpha",
    retryPolicy: GatewayRetryPolicy = GatewayRetryPolicy(),
    session: URLSession = .shared
  ) {
    self.init(environment: environment, apiKeyEnvironment: apiKeyEnvironment, baseURL: baseURL, retryPolicy: retryPolicy) {
      try await session.data(for: $0)
    }
  }

  init(
    environment: [String: String],
    apiKeyEnvironment: String = "OPENROUTER_API_KEY",
    baseURL: String = "https://openrouter.ai/api/alpha",
    retryPolicy: GatewayRetryPolicy = GatewayRetryPolicy(),
    send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
  ) {
    self.environment = environment
    self.apiKeyEnvironment = apiKeyEnvironment
    self.baseURL = baseURL
    self.retryPolicy = retryPolicy
    self.send = send
  }

  func makeRequest(_ decision: GatewayDecisionRequest) throws -> URLRequest {
    try decision.validate()
    guard let key = environment[apiKeyEnvironment], !key.isEmpty else {
      throw GatewayRPCError(code: -32011, message: "missing credential environment '\(apiKeyEnvironment)'")
    }
    guard let url = URL(string: appendPath(baseURL, "decisions")),
          let host = url.host, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
          url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else {
      throw GatewayRPCError(code: -32602, message: "decision base URL requires HTTPS or loopback HTTP")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    try applyGatewayAPIKeyHeaders(&request, vendor: .openRouter, apiKey: key)
    request.httpBody = try JSONEncoder().encode(decision)
    return request
  }

  public func decide(_ decision: GatewayDecisionRequest) async throws -> GatewayDecisionResult {
    let request = try makeRequest(decision)
    var attempt = 1
    while true {
      try Task.checkCancellation()
      let data: Data
      let response: URLResponse
      do {
        (data, response) = try await send(request)
      } catch {
        if Task.isCancelled || error is CancellationError { throw CancellationError() }
        guard attempt < retryPolicy.maxAttempts else {
          // Transport errors may contain request URLs or credential values.
          throw GatewayRPCError(code: -32030, message: "OpenRouter decision transport failed")
        }
        try await gatewayRetryDelay(policy: retryPolicy, attempt: attempt)
        attempt += 1
        continue
      }
      try Task.checkCancellation()
      guard let http = response as? HTTPURLResponse else {
        throw GatewayRPCError(code: -32030, message: "OpenRouter decisions did not return an HTTP response")
      }
      if gatewayHTTPStatusIsRetryable(http.statusCode), attempt < retryPolicy.maxAttempts {
        try await gatewayRetryDelay(policy: retryPolicy, attempt: attempt)
        attempt += 1
        continue
      }
      guard (200...299).contains(http.statusCode) else {
        var detail = String(data: data, encoding: .utf8) ?? "non-UTF8 error response"
        if let key = environment[apiKeyEnvironment], !key.isEmpty {
          detail = detail.replacingOccurrences(of: key, with: "<redacted>")
        }
        throw GatewayRPCError(code: -32030, message: "OpenRouter decisions HTTP \(http.statusCode): \(detail.prefix(500))")
      }
      let result: GatewayDecisionResult
      do { result = try JSONDecoder().decode(GatewayDecisionResult.self, from: data) } catch {
        throw GatewayRPCError(code: -32031, message: "invalid OpenRouter decision response")
      }
      try result.validate(for: decision)
      return result
    }
  }
}
