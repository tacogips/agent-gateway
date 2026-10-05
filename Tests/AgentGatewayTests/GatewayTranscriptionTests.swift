import Foundation
import Testing
import AgentGateway
@testable import AgentGatewayAppCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private func withTranscriptionFile(_ body: (URL, Data) throws -> Void) throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let audio = Data([0, 1, 2, 255, 13, 10])
  try audio.write(to: url)
  defer { try? FileManager.default.removeItem(at: url) }
  try body(url, audio)
}

private func expectTranscriptionError(_ code: Int, message: String? = nil, _ body: () throws -> Void) {
  do {
    try body()
    Issue.record("expected transcription error")
  } catch let error as GatewayRPCError {
    #expect(error.code == code)
    if let message { #expect(error.message == message) }
  } catch {
    Issue.record("unexpected error type")
  }
}

@Test func openAITranscriptionMultipartContainsAudioAndFields() throws {
  try withTranscriptionFile { url, audio in
    let params = GatewayTranscriptionParams(
      vendor: .openAI, model: "whisper-1", audioFile: url, mimeType: "audio/mp4",
      language: "ja", prompt: "Stria", apiKeyEnvironment: "TEST_TOKEN",
      baseURL: "https://proxy.example/v1/", timeoutSeconds: 42
    )
    let request = try makeTranscriptionRequest(
      params, audioData: loadGatewayTranscriptionAudio(url), environment: ["TEST_TOKEN": "fixture"], boundary: "test-boundary"
    )
    #expect(request.url?.absoluteString == "https://proxy.example/v1/audio/transcriptions")
    #expect(request.httpMethod == "POST")
    #expect(request.timeoutInterval == 42)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=test-boundary")
    let body = try #require(request.httpBody)
    for (name, value) in [("model", "whisper-1"), ("language", "ja"), ("prompt", "Stria"), ("response_format", "json")] {
      #expect(body.range(of: Data("name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)) != nil)
    }
    #expect(body.range(of: Data("name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8) + audio) != nil)
    #expect(body.suffix(Data("\r\n--test-boundary--\r\n".utf8).count) == Data("\r\n--test-boundary--\r\n".utf8))
  }
}

@Test func transcriptionOptionalMultipartFieldsAreOmitted() throws {
  try withTranscriptionFile { url, audio in
    let params = GatewayTranscriptionParams(vendor: .openAI, model: "any-model", audioFile: url, mimeType: "audio/wav")
    #expect(params.protocolVersion == GatewayProtocolVersion.current)
    #expect(params.timeoutSeconds == 120)
    let request = try makeTranscriptionRequest(params, audioData: audio, environment: ["OPENAI_API_KEY": "fixture"])
    #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
    let body = try #require(request.httpBody)
    #expect(body.range(of: Data("name=\"language\"".utf8)) == nil)
    #expect(body.range(of: Data("name=\"prompt\"".utf8)) == nil)
  }
}

@Test func geminiTranscriptionUsesInlineAudioAndEncodedKey() throws {
  try withTranscriptionFile { url, audio in
    let params = GatewayTranscriptionParams(vendor: .gemini, model: "gemini-test", audioFile: url, mimeType: "audio/m4a", language: "en", prompt: "Stria")
    let request = try makeTranscriptionRequest(params, audioData: audio, environment: ["GEMINI_API_KEY": "fixture&+?="])
    let components = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
    #expect(components.path == "/v1beta/models/gemini-test:generateContent")
    #expect(components.host == "generativelanguage.googleapis.com")
    #expect(components.queryItems == [URLQueryItem(name: "key", value: "fixture&+?=")])
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try #require(request.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let contents = try #require(object["contents"] as? [[String: Any]])
    let parts = try #require(contents.first?["parts"] as? [[String: Any]])
    #expect(parts.count == 2)
    let inline = try #require(parts.first?["inline_data"] as? [String: String])
    #expect(inline == ["mime_type": "audio/m4a", "data": audio.base64EncodedString()])
    #expect(parts.last?["text"] as? String == transcriptionInstruction(params))
    #expect(transcriptionInstruction(params).contains("verbatim"))
    #expect(transcriptionInstruction(params).contains("en"))
    #expect(transcriptionInstruction(params).contains("Stria"))
  }
}

@Test func openRouterTranscriptionUsesAudioMessage() throws {
  try withTranscriptionFile { url, audio in
    let params = GatewayTranscriptionParams(vendor: .openRouter, model: "any/model", audioFile: url, mimeType: "audio/mpeg")
    let request = try makeTranscriptionRequest(params, audioData: audio, environment: ["OPENROUTER_API_KEY": "fixture"])
    #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
    let body = try #require(request.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["model"] as? String == "any/model")
    let messages = try #require(object["messages"] as? [[String: Any]])
    #expect(messages.count == 1)
    #expect(messages.first?["role"] as? String == "user")
    let content = try #require(messages.first?["content"] as? [[String: Any]])
    #expect(content.count == 2)
    #expect(content[0]["type"] as? String == "text")
    #expect(content[0]["text"] as? String == transcriptionInstruction(params))
    #expect(content[1]["type"] as? String == "input_audio")
    #expect(content[1]["input_audio"] as? [String: String] == ["data": audio.base64EncodedString(), "format": "mp3"])
  }
}

@Test func transcriptionParsesVendorPayloadsAndEmptyText() throws {
  #expect(try parseVendorTranscription(["text": " hello "], vendor: .openAI) == " hello ")
  #expect(try parseVendorTranscription(["text": ""], vendor: .openAI) == "")
  #expect(try parseVendorTranscription(["candidates": [["content": ["parts": [["text": "hello"], ["text": " world"]]]]]], vendor: .gemini) == "hello world")
  #expect(try parseVendorTranscription(["candidates": [["content": ["parts": [["text": ""]]]]]], vendor: .gemini) == "")
  #expect(try parseVendorTranscription(["choices": [["message": ["content": "hello"]]]], vendor: .openRouter) == "hello")
  #expect(try parseVendorTranscription(["choices": [["message": ["content": ""]]]], vendor: .openRouter) == "")
  let parts = [["type": "text", "text": "hello"], ["type": "image", "text": "ignore"], ["type": "text", "text": " world"]]
  #expect(try parseVendorTranscription(["choices": [["message": ["content": parts]]]], vendor: .openRouter) == "hello world")
  for vendor in [GatewayVendor.openAI, .gemini, .openRouter] {
    expectTranscriptionError(-32010) { _ = try parseVendorTranscription([:], vendor: vendor) }
  }
}

@Test func transcriptionUnsupportedVendorsFailBeforeFileIO() async {
  for vendor in [GatewayVendor.anthropic, .cursorAPI, .claudeCode, .codex, .cursor] {
    let params = GatewayTranscriptionParams(vendor: vendor, model: "test", audioFile: URL(fileURLWithPath: "/nonexistent/audio"), mimeType: "audio/wav")
    do {
      _ = try await ProductionGatewayExecutor(environment: [:]).transcribe(params)
      Issue.record("expected unsupported vendor")
    } catch let error as GatewayRPCError {
      #expect(error.code == gatewayTranscriptionUnsupportedCode)
      #expect(error.message == "\(vendor.rawValue) does not support audio transcription")
    } catch { Issue.record("unexpected error type") }
  }
}

@Test func transcriptionMissingCredentialsFailBeforeFileIO() async {
  for vendor in [GatewayVendor.openAI, .gemini, .openRouter] {
    let params = GatewayTranscriptionParams(vendor: vendor, model: "test", audioFile: URL(fileURLWithPath: "/nonexistent/audio"), mimeType: "audio/wav", apiKeyEnvironment: "TEST_TOKEN")
    do {
      _ = try await ProductionGatewayExecutor(environment: ["TEST_TOKEN": ""]).transcribe(params)
      Issue.record("expected missing credential")
    } catch let error as GatewayRPCError {
      #expect(error.code == -32011)
      #expect(error.message == "missing credential environment 'TEST_TOKEN'")
    } catch { Issue.record("unexpected error type") }
    expectTranscriptionError(-32011, message: "missing credential environment '\(defaultAPIKeyEnvironment(for: vendor))'") {
      var defaults = params
      defaults.apiKeyEnvironment = nil
      _ = try makeTranscriptionRequest(defaults, audioData: Data(), environment: [:])
    }
  }
}

@Test func transcriptionRejectsOversizeFilesAndNonlocalURLs() throws {
  try withTranscriptionFile { url, _ in
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(gatewayTranscriptionMaxBytes + 1))
    try handle.close()
    expectTranscriptionError(-32602, message: "audio input exceeds the 25 MB (25,000,000 bytes) size limit") {
      _ = try loadGatewayTranscriptionAudio(url)
    }
    try validateTranscriptionSize(gatewayTranscriptionMaxBytes)
    for vendor in [GatewayVendor.openAI, .gemini, .openRouter] {
      let params = GatewayTranscriptionParams(vendor: vendor, model: "test", audioFile: url, mimeType: "audio/wav")
      expectTranscriptionError(-32602) {
        _ = try makeTranscriptionRequest(params, audioData: Data(count: gatewayTranscriptionMaxBytes + 1), environment: [defaultAPIKeyEnvironment(for: vendor): "fixture"])
      }
    }
  }
  let remote = try #require(URL(string: "https://example.com/audio"))
  expectTranscriptionError(-32602) { _ = try loadGatewayTranscriptionAudio(remote) }
}

@Test func transcriptionResponseReportsHTTPAndJSONErrors() throws {
  let url = try #require(URL(string: "https://example.com"))
  let failure = try #require(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: nil))
  expectTranscriptionError(-32010, message: "vendor HTTP 429: " + String(repeating: "x", count: 500)) {
    _ = try parseTranscriptionResponse(Data(String(repeating: "x", count: 600).utf8), response: failure, vendor: .openAI)
  }
  let success = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
  #expect(try parseTranscriptionResponse(Data(#"{"text":""}"#.utf8), response: success, vendor: .openAI) == "")
  expectTranscriptionError(-32010) { _ = try parseTranscriptionResponse(Data("invalid".utf8), response: success, vendor: .openAI) }
  expectTranscriptionError(-32010) { _ = try parseTranscriptionResponse(Data(), response: URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), vendor: .openAI) }
}

@Test func transcriptionFormatsAndDefaultModels() throws {
  for (mime, format) in [("audio/wav", "wav"), ("audio/mpeg", "mp3"), ("audio/mp4", "m4a"), ("audio/m4a", "m4a"), ("audio/webm", "webm")] {
    #expect(try transcriptionAudioFormat(mime) == format)
  }
  #expect(GatewayTranscriptionModels.defaults[.openAI] == ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"])
  #expect(GatewayTranscriptionModels.defaults[.gemini] == ["gemini-3.5-flash-lite", "gemini-3.8-flash"])
  #expect(GatewayTranscriptionModels.defaults[.openRouter] == ["openai/gpt-4o-audio-preview", "google/gemini-3.5-flash-lite"])
  #expect(GatewayTranscriptionModels.defaults[.anthropic] == nil)
}

@Test func transcriptionValidatesProtocolTimeoutAndMimeType() throws {
  try withTranscriptionFile { url, audio in
    var params = GatewayTranscriptionParams(vendor: .openAI, model: "test", audioFile: url, mimeType: "audio/wav")
    params.protocolVersion = "unsupported"
    expectTranscriptionError(-32602) {
      _ = try makeTranscriptionRequest(params, audioData: audio, environment: ["OPENAI_API_KEY": "fixture"])
    }
    params.protocolVersion = GatewayProtocolVersion.current
    params.timeoutSeconds = 0
    expectTranscriptionError(-32602) {
      _ = try makeTranscriptionRequest(params, audioData: audio, environment: ["OPENAI_API_KEY": "fixture"])
    }
    params.timeoutSeconds = 120
    params.mimeType = "audio/wav\r\nInjected: header"
    expectTranscriptionError(-32602) {
      _ = try makeTranscriptionRequest(params, audioData: audio, environment: ["OPENAI_API_KEY": "fixture"])
    }
  }
}

@Test func cancelledTranscriptionStopsBeforeFileIO() async {
  let task = Task {
    // Cancel this task deterministically before calling the executor.
    withUnsafeCurrentTask { $0?.cancel() }
    let params = GatewayTranscriptionParams(
      vendor: .openAI, model: "test", audioFile: URL(fileURLWithPath: "/nonexistent/audio"), mimeType: "audio/wav"
    )
    return try await ProductionGatewayExecutor(environment: ["OPENAI_API_KEY": "fixture"]).transcribe(params)
  }
  do {
    _ = try await task.value
    Issue.record("expected cancellation")
  } catch is CancellationError {
    // Cancellation must win over opening the nonexistent file.
  } catch { Issue.record("unexpected error type") }
}
