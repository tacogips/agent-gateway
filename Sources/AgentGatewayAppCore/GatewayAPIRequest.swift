import AgentGateway
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

func makeAPIRequest(
  _ params: GatewayExecuteParams,
  environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> URLRequest {
  let keyName = params.apiKeyEnvironment ?? defaultAPIKeyEnvironment(for: params.vendor)
  guard let apiKey = environment[keyName], !apiKey.isEmpty else {
    throw GatewayRPCError(code: -32011, message: "missing credential environment '\(keyName)'")
  }
  let url = try apiURL(params, apiKey: apiKey)
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  switch params.vendor {
  case .anthropic:
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
  case .gemini:
    break
  case .openAI, .openRouter:
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
  case .claudeCode, .codex, .cursor:
    throw GatewayRPCError(code: -32602, message: "CLI vendor cannot create an API request")
  }
  request.httpBody = try JSONSerialization.data(withJSONObject: apiBody(params))
  return request
}

private func defaultAPIKeyEnvironment(for vendor: GatewayVendor) -> String {
  switch vendor {
  case .openAI: "OPENAI_API_KEY"
  case .anthropic: "ANTHROPIC_API_KEY"
  case .gemini: "GEMINI_API_KEY"
  case .openRouter: "OPENROUTER_API_KEY"
  case .claudeCode, .codex, .cursor: ""
  }
}

private func apiURL(_ params: GatewayExecuteParams, apiKey: String) throws -> URL {
  let value: String
  switch params.vendor {
  case .openAI:
    value = appendPath(params.baseURL ?? "https://api.openai.com/v1", "responses")
  case .anthropic:
    value = appendPath(params.baseURL ?? "https://api.anthropic.com/v1", "messages")
  case .gemini:
    let base = params.baseURL ?? "https://generativelanguage.googleapis.com/v1beta"
    value = appendPath(base, "models/\(params.model):streamGenerateContent") + "?alt=sse&key=\(apiKey)"
  case .openRouter:
    value = appendPath(params.baseURL ?? "https://openrouter.ai/api/v1", "chat/completions")
  case .claudeCode, .codex, .cursor:
    throw GatewayRPCError(code: -32602, message: "CLI vendor cannot create an API URL")
  }
  guard let url = URL(string: value) else {
    throw GatewayRPCError(code: -32602, message: "invalid base URL")
  }
  return url
}

private func appendPath(_ base: String, _ path: String) -> String {
  base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path
}

private func apiBody(_ params: GatewayExecuteParams) -> [String: Any] {
  switch params.vendor {
  case .openAI:
    var body: [String: Any] = ["model": params.model, "input": params.prompt, "stream": true]
    body["instructions"] = params.systemPrompt
    return body
  case .anthropic:
    var body: [String: Any] = [
      "model": params.model,
      "max_tokens": params.maxTokens ?? 4_096,
      "messages": [["role": "user", "content": params.prompt]],
      "stream": true
    ]
    body["system"] = params.systemPrompt
    return body
  case .gemini:
    var contents: [[String: Any]] = [["role": "user", "parts": [["text": params.prompt]]]]
    if let systemPrompt = params.systemPrompt {
      contents.insert(["role": "user", "parts": [["text": systemPrompt]]], at: 0)
    }
    return ["contents": contents]
  case .openRouter:
    var messages: [[String: String]] = []
    if let systemPrompt = params.systemPrompt {
      messages.append(["role": "system", "content": systemPrompt])
    }
    messages.append(["role": "user", "content": params.prompt])
    return ["model": params.model, "messages": messages, "stream": true, "stream_options": ["include_usage": true]]
  case .claudeCode, .codex, .cursor:
    return [:]
  }
}
