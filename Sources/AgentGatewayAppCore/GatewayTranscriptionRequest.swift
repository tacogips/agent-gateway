import AgentGateway
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Pure request construction: audio loading and network I/O live outside this function.
func makeTranscriptionRequest(
  _ params: GatewayTranscriptionParams,
  audioData: Data,
  environment: [String: String],
  boundary: String = "agent-gateway-\(UUID().uuidString)"
) throws -> URLRequest {
  let apiKey = try transcriptionAPIKey(params, environment: environment)
  try validateTranscriptionSize(audioData.count)
  let format = try transcriptionAudioFormat(params.mimeType)
  let base = try params.baseURL ?? defaultGatewayBaseURL(for: params.vendor)
  let path: String
  switch params.vendor {
  case .openAI: path = "audio/transcriptions"
  case .gemini: path = "models/\(params.model):generateContent"
  default: path = "chat/completions"
  }
  guard var components = URLComponents(string: appendPath(base, path)),
        ["https", "http"].contains(components.scheme), components.host != nil else {
    throw GatewayRPCError(code: -32602, message: "invalid base URL")
  }
  if params.vendor == .gemini {
    components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "key", value: apiKey)]
  }
  guard let url = components.url else {
    throw GatewayRPCError(code: -32602, message: "invalid base URL")
  }
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.timeoutInterval = TimeInterval(params.timeoutSeconds)
  try applyGatewayAPIKeyHeaders(&request, vendor: params.vendor, apiKey: apiKey)
  if params.vendor == .openAI {
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = transcriptionMultipart(params, audio: audioData, format: format, boundary: boundary)
  } else {
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let instruction = transcriptionInstruction(params)
    let body: [String: Any]
    if params.vendor == .gemini {
      body = ["contents": [["parts": [
        ["inline_data": ["mime_type": params.mimeType, "data": audioData.base64EncodedString()]],
        ["text": instruction]
      ]]]]
    } else {
      body = ["model": params.model, "messages": [["role": "user", "content": [
        ["type": "text", "text": instruction],
        ["type": "input_audio", "input_audio": ["data": audioData.base64EncodedString(), "format": format]]
      ]]]]
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
  }
  return request
}

func transcriptionInstruction(_ params: GatewayTranscriptionParams) -> String {
  var instruction = "Transcribe the audio verbatim. Return only the transcription, without commentary, formatting, or translation."
  if let language = params.language { instruction += " The spoken language is \(language)." }
  if let prompt = params.prompt { instruction += " Vocabulary/context hint: \(prompt)" }
  return instruction
}

func transcriptionAudioFormat(_ mimeType: String) throws -> String {
  switch mimeType.lowercased() {
  case "audio/wav", "audio/x-wav", "audio/wave": "wav"
  case "audio/mpeg", "audio/mp3": "mp3"
  case "audio/mp4", "audio/m4a", "audio/x-m4a": "m4a"
  case "audio/webm": "webm"
  case "audio/ogg": "ogg"
  case "audio/flac", "audio/x-flac": "flac"
  case "audio/aac": "aac"
  default: throw GatewayRPCError(code: -32602, message: "unsupported audio MIME type")
  }
}

private func transcriptionMultipart(
  _ params: GatewayTranscriptionParams, audio: Data, format: String, boundary: String
) -> Data {
  var body = Data()
  func append(_ value: String) { body.append(Data(value.utf8)) }
  func field(_ name: String, _ value: String) {
    append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
  }
  field("model", params.model)
  if let language = params.language { field("language", language) }
  if let prompt = params.prompt { field("prompt", prompt) }
  field("response_format", "json")
  append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.\(format)\"\r\n")
  append("Content-Type: \(params.mimeType)\r\n\r\n")
  body.append(audio)
  append("\r\n--\(boundary)--\r\n")
  return body
}

func parseTranscriptionResponse(_ data: Data, response: URLResponse, vendor: GatewayVendor) throws -> String {
  guard let http = response as? HTTPURLResponse else {
    throw GatewayRPCError(code: -32010, message: "vendor did not return an HTTP response")
  }
  guard (200...299).contains(http.statusCode) else {
    let body = String(bytes: data.prefix(500), encoding: .utf8) ?? "invalid UTF-8 response"
    throw GatewayRPCError(code: -32010, message: "vendor HTTP \(http.statusCode): \(body)")
  }
  guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw GatewayRPCError(code: -32010, message: "vendor returned invalid transcription JSON")
  }
  return try parseVendorTranscription(object, vendor: vendor)
}

func parseVendorTranscription(_ object: [String: Any], vendor: GatewayVendor) throws -> String {
  switch vendor {
  case .openAI:
    if let text = object["text"] as? String { return text }
  case .gemini:
    if let candidates = object["candidates"] as? [[String: Any]],
       let content = candidates.first?["content"] as? [String: Any],
       let parts = content["parts"] as? [[String: Any]] {
      return parts.compactMap { $0["text"] as? String }.joined()
    }
  case .openRouter:
    if let choices = object["choices"] as? [[String: Any]],
       let message = choices.first?["message"] as? [String: Any] {
      if let text = message["content"] as? String { return text }
      if let parts = message["content"] as? [[String: Any]] {
        return parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
      }
    }
  default:
    throw GatewayRPCError(
      code: gatewayTranscriptionUnsupportedCode,
      message: "\(vendor.rawValue) does not support audio transcription"
    )
  }
  throw GatewayRPCError(code: -32010, message: "vendor returned invalid transcription payload")
}
