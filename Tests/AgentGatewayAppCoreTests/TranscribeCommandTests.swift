import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AgentGateway
@testable import AgentGatewayAppCore

private final class RecordingTransport: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [(URLRequest, Int)] = []
  let status: Int
  let body: String
  let headers: [String: String]
  let error: (any Error)?
  init(status: Int = 200, body: String = "{\"text\":\"hello\"}", headers: [String: String] = [:], error: (any Error)? = nil) {
    self.status = status
    self.body = body
    self.headers = headers
    self.error = error
  }
  var calls: [(URLRequest, Int)] { lock.withLock { recorded } }
  var transport: GatewayTranscriptionTransport {
    { request, timeout in
      self.lock.withLock { self.recorded.append((request, timeout)) }
      if let error = self.error { throw error }
      let response = HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: self.status,
                                     httpVersion: nil, headerFields: self.headers)!
      return (Data(self.body.utf8), response)
    }
  }
}

@Suite private struct TranscribeCommandTests {
  let command = AppCommand(arguments: [])
  func options(_ path: String, _ extra: [String] = []) throws -> GatewayTranscriptionCommandOptions {
    try command.transcriptionOptions(["--vendor", "openai", "--model", "whisper-1", "--file", path,
                                      "--api-key-environment", "TEST_OPENAI_KEY"] + extra)
  }
  func run(_ options: GatewayTranscriptionCommandOptions, _ stub: RecordingTransport,
           environment: [String: String] = ["TEST_OPENAI_KEY": "fixture-secret"]) async -> GatewayTranscriptionCommandOutcome {
    await command.runTranscription(options, transcriber: GatewayTranscriptionPipeline(environment: environment, transport: stub.transport))
  }
  func temporary(_ ext: String = "mp3") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
    try Data("audio".utf8).write(to: url)
    return url
  }

  @Test func textAndRequest() async throws {
    let file = try temporary(); defer { try? FileManager.default.removeItem(at: file) }
    let stub = RecordingTransport()
    let result = await run(try options(file.path, ["--language", "ja", "--prompt", "Stria"]), stub)
    #expect(result.status == 0 && result.standardOutput == "hello\n" && result.standardError.isEmpty)
    #expect(!result.standardOutput.contains("fixture-secret") && !result.standardError.contains("fixture-secret"))
    #expect(stub.calls.count == 1)
    let request = try #require(stub.calls.first?.0)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
    #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
    #expect(request.value(forHTTPHeaderField: "Authorization") != nil)
    let data = try #require(request.httpBody)
    let body = try #require(String(data: data, encoding: .utf8))
    for value in ["name=\"model\"\r\n\r\nwhisper-1", "name=\"language\"\r\n\r\nja", "name=\"prompt\"\r\n\r\nStria", "Content-Type: audio/mpeg"] { #expect(body.contains(value)) }
  }
  @Test func json() async throws {
    let file = try temporary(); defer { try? FileManager.default.removeItem(at: file) }
    let stub = RecordingTransport()
    let result = await run(try options(file.path, ["--output", "json"]), stub)
    #expect(result.status == 0 && result.standardError.isEmpty && result.standardOutput == "{\"model\":\"whisper-1\",\"text\":\"hello\",\"vendor\":\"openai\"}\n")
    #expect(stub.calls.count == 1)
  }
  @Test func baseAndTimeout() async throws {
    let file = try temporary(); defer { try? FileManager.default.removeItem(at: file) }
    let stub = RecordingTransport()
    let result = await run(try options(file.path, ["--base-url", "https://example.invalid/v1", "--timeout-seconds", "7"]), stub)
    #expect(result.status == 0)
    let call = try #require(stub.calls.first)
    #expect(call.0.url?.absoluteString == "https://example.invalid/v1/audio/transcriptions" && call.1 == 7 && call.0.timeoutInterval == 7)
  }
  @Test func mimeTable() {
    for (ext, mime) in [("wav", "audio/wav"),
      ("WAV", "audio/wav"),
      ("mp3", "audio/mpeg"),
      ("mpga", "audio/mpeg"),
      ("mpeg", "audio/mpeg"),
      ("m4a", "audio/mp4"),
      ("mp4", "audio/mp4"),
      ("webm", "audio/webm"),
      ("ogg", "audio/ogg"),
      ("oga", "audio/ogg"),
      ("flac", "audio/flac"),
      ("aac", "audio/aac")] { #expect(inferGatewayTranscriptionMIMEType(path: "x." + ext) == mime) }
    #expect(inferGatewayTranscriptionMIMEType(path: "x.xyz") == nil)
    #expect(inferGatewayTranscriptionMIMEType(path: "noext") == nil)
  }
  @Test func mimeOverride() async throws {
    let file = try temporary(); defer { try? FileManager.default.removeItem(at: file) }
    let stub = RecordingTransport()
    let result = await run(try options(file.path, ["--mime-type", "audio/wav"]), stub)
    #expect(result.status == 0)
    let data = try #require(stub.calls.first?.0.httpBody)
    let body = try #require(String(data: data, encoding: .utf8))
    #expect(body.contains("Content-Type: audio/wav"))
  }
  @Test func unknownMIME() async throws {
    let stub = RecordingTransport(); let result = await run(try options("a.xyz"), stub)
    #expect(result.status == 1 && result.standardOutput.isEmpty && result.standardError.contains("-32602") && result.standardError.contains("--mime-type") && stub.calls.isEmpty)
  }
  @Test func unsupportedVendors() async throws {
    for vendor in ["anthropic", "cursor", "cursor-api", "claude-code", "codex"] {
      let stub = RecordingTransport()
      let opts = try command.transcriptionOptions(["--vendor", vendor, "--model", "m", "--file", "/nonexistent/a.xyz"])
      let result = await run(opts, stub)
      #expect(result.status == 1 && result.standardOutput.isEmpty && result.standardError.hasPrefix("transcription failed (-32021)") && stub.calls.isEmpty)
    }
  }
  @Test func missingFile() async throws {
    let stub = RecordingTransport(); let result = await run(try options("/nonexistent/a.mp3"), stub)
    #expect(result.status == 1 && result.standardOutput.isEmpty && result.standardError.hasPrefix("transcription failed") && stub.calls.isEmpty)
  }
  @Test func oversizedFile() async throws {
    let file = try temporary(); defer { try? FileManager.default.removeItem(at: file) }
    let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: 25_000_001); try handle.close()
    let stub = RecordingTransport(); let result = await run(try options(file.path), stub)
    #expect(result.status == 1 && result.standardOutput.isEmpty && result.standardError.contains("-32602") && result.standardError.contains("25 MB") && stub.calls.isEmpty)
  }
  @Test func httpErrors() async throws {
    let file = try temporary(); defer { try? FileManager.default.removeItem(at: file) }
    for code in ["insufficient_quota", "rate_limit_exceeded"] {
      let stub = RecordingTransport(status: 429, body: "{\"error\":{\"code\":\"\(code)\"}}")
      let result = await run(try options(file.path), stub)
      #expect(result.status == 1 && result.standardOutput.isEmpty && result.standardError.contains("transcription failed (-32010)")
        && result.standardError.contains("vendor HTTP 429") && result.standardError.contains(code))
    }
  }
  @Test func structuredQuotaFailure() async throws {
    let file = try temporary(); defer { try? FileManager.default.removeItem(at: file) }
    let body = "{\"error\":{\"type\":\"insufficient_quota\",\"code\":\"credit_balance_exhausted\",\"message\":\"quota\"}}"
    let stub = RecordingTransport(status: 429, body: body, headers: ["Retry-After": "7"])
    let result = await run(try options(file.path), stub)
    let expected = "transcription failed (-32010): vendor HTTP 429: \(body)\n"
      + "classification: quotaExhausted\nhttp-status: 429\nvendor-error-type: insufficient_quota\n"
      + "vendor-error-code: credit_balance_exhausted\nretry-after-seconds: 7\n"
    #expect(result.status == 1 && result.standardOutput.isEmpty && result.standardError == expected)
    #expect(!result.standardError.contains("fixture-secret") && stub.calls.count == 1)
  }
  @Test func structuredTransportFailure() async throws {
    let file = try temporary(); defer { try? FileManager.default.removeItem(at: file) }
    let stub = RecordingTransport(error: URLError(.notConnectedToInternet))
    let result = await run(try options(file.path), stub)
    #expect(result.status == 1 && result.standardOutput.isEmpty && stub.calls.count == 1)
    for line in ["classification: transport", "http-status: none", "vendor-error-type: none",
                 "vendor-error-code: none", "retry-after-seconds: none"] {
      #expect(result.standardError.contains(line + "\n"))
    }
  }
  @Test func secretBoundaryInStderr() async throws {
    let file = try temporary(); defer { try? FileManager.default.removeItem(at: file) }
    let key = "fixture-secret-0123456789abcdef"
    let stub = RecordingTransport(status: 429, body: String(repeating: "x", count: 480) + key + String(repeating: "x", count: 100))
    let result = await run(try options(file.path), stub, environment: ["TEST_OPENAI_KEY": key])
    #expect(result.status == 1 && result.standardOutput.isEmpty && stub.calls.count == 1)
    #expect(result.standardError.contains("[REDACTED]"))
    for length in 8...31 { #expect(!result.standardError.contains(String(key.prefix(length)))) }
  }
  @Test func missingCredential() async throws {
    let stub = RecordingTransport()
    let opts = try command.transcriptionOptions(["--vendor", "openai", "--model", "m", "--file", "a.mp3"])
    let result = await run(opts, stub, environment: [:])
    #expect(result.status == 1 && result.standardOutput.isEmpty && result.standardError.contains("-32011") && result.standardError.contains("OPENAI_API_KEY") && stub.calls.isEmpty)
  }
  @Test func parsing() throws {
    let valid = ["--vendor", "openai", "--model", "m", "--file", "a.mp3"]
    for (args, flag) in [(["--model", "m", "--file", "a"], "--vendor"),
      (["--vendor", "nope", "--model", "m", "--file", "a"], "--vendor"),
      (["--vendor", "openai", "--file", "a"], "--model"),
      (["--vendor", "openai", "--model", "m"], "--file"),
      (valid + ["--output", "yaml"], "--output"),
      (valid + ["--timeout-seconds", "abc"], "--timeout-seconds"),
      (valid + ["--file"], "--file")] {
      #expect(throws: AppCommand.Error.missingValue(flag)) { try command.transcriptionOptions(args) }
    }
    for token in ["--bogus", "positional", "--"] {
      #expect(throws: AppCommand.Error.unknownArgument(token)) { try command.transcriptionOptions(valid + [token]) }
    }
    #expect(try command.transcriptionOptions(valid + ["--model", "last"]).model == "last")
  }
  @Test func dispatchAndHelp() throws {
    #expect(try AppCommand(arguments: ["transcribe", "--vendor", "openai"]).run() == "")
    #expect(command.usage.contains("agent-gateway transcribe"))
  }
}
