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
  case .cursorAPI:
    request.setValue("Basic \(Data("\(apiKey):".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
  case .claudeCode, .codex, .cursor:
    throw GatewayRPCError(code: -32602, message: "CLI vendor cannot create an API request")
  }
  request.httpBody = try JSONSerialization.data(withJSONObject: try apiBody(params))
  return request
}

func defaultAPIKeyEnvironment(for vendor: GatewayVendor) -> String {
  switch vendor {
  case .openAI: "OPENAI_API_KEY"
  case .anthropic: "ANTHROPIC_API_KEY"
  case .gemini: "GEMINI_API_KEY"
  case .openRouter: "OPENROUTER_API_KEY"
  case .cursorAPI: "CURSOR_API_KEY"
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
  case .cursorAPI:
    value = appendPath(params.baseURL ?? "https://api.cursor.com/v1", "agents")
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

private func apiBody(_ params: GatewayExecuteParams) throws -> [String: Any] {
  let images = try gatewayImages(params.images)
  switch params.vendor {
  case .openAI:
    var content: [[String: Any]] = [["type": "input_text", "text": params.prompt]]
    content += images.map { ["type": "input_image", "image_url": $0.dataURL] }
    var body: [String: Any] = [
      "model": params.model,
      "input": [["role": "user", "content": content]],
      "stream": true
    ]
    body["instructions"] = params.systemPrompt
    if params.sessionMode == .reuse {
      body["previous_response_id"] = params.sessionId
    }
    return body
  case .anthropic:
    var content: [[String: Any]] = [["type": "text", "text": params.prompt]]
    content += images.map {
      ["type": "image", "source": ["type": "base64", "media_type": $0.mimeType, "data": $0.dataBase64]]
    }
    var body: [String: Any] = [
      "model": params.model,
      "max_tokens": params.maxTokens ?? 4_096,
      "messages": [["role": "user", "content": content]],
      "stream": true
    ]
    body["system"] = params.systemPrompt
    return body
  case .gemini:
    var parts: [[String: Any]] = [["text": params.prompt]]
    parts += images.map { ["inline_data": ["mime_type": $0.mimeType, "data": $0.dataBase64]] }
    var contents: [[String: Any]] = [["role": "user", "parts": parts]]
    if let systemPrompt = params.systemPrompt {
      contents.insert(["role": "user", "parts": [["text": systemPrompt]]], at: 0)
    }
    return ["contents": contents]
  case .openRouter:
    var messages: [[String: Any]] = []
    if let systemPrompt = params.systemPrompt {
      messages.append(["role": "system", "content": systemPrompt])
    }
    var content: [[String: Any]] = [["type": "text", "text": params.prompt]]
    content += images.map { ["type": "image_url", "image_url": ["url": $0.dataURL]] }
    messages.append(["role": "user", "content": content])
    return ["model": params.model, "messages": messages, "stream": true, "stream_options": ["include_usage": true]]
  case .cursorAPI:
    guard images.isEmpty else {
      throw GatewayRPCError(code: -32602, message: "cursor-api does not support gateway image inputs")
    }
    var body: [String: Any] = [
      "prompt": ["text": [params.systemPrompt, params.prompt].compactMap { $0 }.joined(separator: "\n\n")],
      "model": ["id": params.model]
    ]
    if let repositoryURL = params.cursorAPI?.repositoryURL, !repositoryURL.isEmpty {
      var repository = ["url": repositoryURL]
      if let startingRef = params.cursorAPI?.startingRef, !startingRef.isEmpty {
        repository["startingRef"] = startingRef
      }
      body["repos"] = [repository]
    }
    body["workOnCurrentBranch"] = params.cursorAPI?.workOnCurrentBranch
    body["autoCreatePR"] = params.cursorAPI?.autoCreatePR
    return body
  case .claudeCode, .codex, .cursor:
    return [:]
  }
}

private struct ResolvedGatewayImage {
  var mimeType: String
  var dataBase64: String
  var dataURL: String { "data:\(mimeType);base64,\(dataBase64)" }
}

private func gatewayImages(_ inputs: [GatewayImageInput]) throws -> [ResolvedGatewayImage] {
  try inputs.map { input in
    if let dataBase64 = input.dataBase64, let mimeType = input.mimeType {
      guard Data(base64Encoded: dataBase64) != nil else {
        throw GatewayRPCError(code: -32602, message: "image dataBase64 is invalid")
      }
      return ResolvedGatewayImage(mimeType: mimeType, dataBase64: dataBase64)
    }
    guard let filePath = input.filePath else {
      throw GatewayRPCError(code: -32602, message: "image input requires filePath or dataBase64")
    }
    let url = URL(fileURLWithPath: filePath)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw GatewayRPCError(code: -32602, message: "image input must be a regular file")
    }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count <= 20 * 1_024 * 1_024 else {
      throw GatewayRPCError(code: -32602, message: "image input exceeds 20 MiB")
    }
    return ResolvedGatewayImage(
      mimeType: input.mimeType ?? gatewayImageMIMEType(url.pathExtension),
      dataBase64: data.base64EncodedString()
    )
  }
}

private func gatewayImageMIMEType(_ pathExtension: String) -> String {
  switch pathExtension.lowercased() {
  case "jpg", "jpeg": "image/jpeg"
  case "gif": "image/gif"
  case "webp": "image/webp"
  default: "image/png"
  }
}
