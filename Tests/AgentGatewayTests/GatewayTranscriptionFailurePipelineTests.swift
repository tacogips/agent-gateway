import Foundation
import Testing
import AgentGateway
@testable import AgentGatewayAppCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class PipelineStub: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [URLRequest] = []
  let status: Int
  let body: String
  let headers: [String: String]
  let error: (any Error)?
  let nonHTTP: Bool

  init(status: Int = 429, body: String = "{}", headers: [String: String] = [:],
       error: (any Error)? = nil, nonHTTP: Bool = false) {
    self.status = status
    self.body = body
    self.headers = headers
    self.error = error
    self.nonHTTP = nonHTTP
  }

  var requests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  private func record(_ request: URLRequest) {
    lock.lock()
    recorded.append(request)
    lock.unlock()
  }

  func transport(_ request: URLRequest, _: Int) async throws -> (Data, URLResponse) {
    record(request)
    if let error { throw error }
    let url = request.url!
    let response: URLResponse = nonHTTP
      ? URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
      : HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    return (Data(body.utf8), response)
  }
}

@Suite struct GatewayTranscriptionFailurePipelineTests {
  private let key = "fixture-secret-0123456789abcdef"

  private func call(_ stub: PipelineStub, vendor: GatewayVendor = .openAI) async throws -> GatewayTranscriptionResult {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
    try Data([1, 2, 3]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let params = GatewayTranscriptionParams(vendor: vendor, model: "test", audioFile: url, mimeType: "audio/mp3",
                                            apiKeyEnvironment: "TEST_KEY")
    return try await GatewayTranscriptionPipeline(environment: ["TEST_KEY": key], transport: stub.transport).transcribe(params)
  }

  private func failure(_ stub: PipelineStub, vendor: GatewayVendor = .openAI) async throws -> GatewayTranscriptionFailure {
    do {
      _ = try await call(stub, vendor: vendor)
      throw TestFailure.expectedFailure
    } catch let error as GatewayTranscriptionFailure {
      #expect(stub.requests.count == 1)
      return error
    }
  }

  private enum TestFailure: Error { case expectedFailure }

  @Test func vendorAndStatusClassification() async throws {
    let quota = try await failure(PipelineStub(body: #"{"error":{"type":"insufficient_quota","code":"credit_balance_exhausted","message":"quota"}}"#))
    #expect(quota.classification == .quotaExhausted && quota.httpStatus == 429)
    #expect(quota.vendorErrorType == "insufficient_quota" && quota.vendorErrorCode == "credit_balance_exhausted")
    let rate = try await failure(PipelineStub(body: #"{"error":{"type":"rate_limit_exceeded","code":"rate_limit_exceeded"}}"#,
                                              headers: ["Retry-After": "7"]))
    #expect(rate.classification == .rateLimited && rate.retryAfterSeconds == 7)
    for (status, classification) in [(503, GatewayTranscriptionFailure.Classification.serverError), (401, .authFailed)] {
      let result = try await failure(PipelineStub(status: status))
      #expect(result.classification == classification)
    }
    let gemini = try await failure(PipelineStub(body: #"{"error":{"code":429,"message":"m","status":"RESOURCE_EXHAUSTED"}}"#), vendor: .gemini)
    #expect(gemini.classification == .rateLimited && gemini.vendorErrorType == "RESOURCE_EXHAUSTED" && gemini.vendorErrorCode == "429")
    #expect(!String(describing: gemini).contains(key))
    let router = try await failure(PipelineStub(status: 402, body: #"{"error":{"code":402,"message":"m"}}"#), vendor: .openRouter)
    #expect(router.classification == .quotaExhausted && router.vendorErrorCode == "402")
  }

  @Test func redirectAndLongBodies() async throws {
    let stub = PipelineStub(status: 302, body: "", headers: ["Location": "https://example.invalid/elsewhere"])
    let redirect = try await failure(stub)
    #expect(redirect.httpStatus == 302 && redirect.classification == .unknown)
    #expect(stub.requests.first?.url?.host == "api.openai.com")
    for count in [600, 20_000] {
      let body = "{\"error\":{\"message\":\"" + String(repeating: "x", count: count) + "\",\"code\":\"insufficient_quota\"}}"
      let result = try await failure(PipelineStub(body: body))
      #expect(result.vendorErrorCode == "insufficient_quota")
      #expect((result.rawBody?.utf8.count ?? 0) <= 16_384)
    }
    let legacy = try await failure(PipelineStub(body: String(repeating: "x", count: 600)))
    #expect(legacy.rpcError == GatewayRPCError(code: -32010, message: "vendor HTTP 429: " + String(repeating: "x", count: 500)))
  }

  @Test func transportAndMalformedResponses() async throws {
    let transport = try await failure(PipelineStub(error: URLError(.timedOut)))
    #expect(transport.classification == .transport && transport.httpStatus == nil)
    let cancelled = PipelineStub(error: CancellationError())
    do { _ = try await call(cancelled); Issue.record("expected cancellation") } catch is CancellationError { }
    #expect(cancelled.requests.count == 1)
    for (stub, message) in [(PipelineStub(status: 200, body: "invalid"), "vendor returned invalid transcription JSON"),
                            (PipelineStub(status: 200), "vendor returned invalid transcription payload")] {
      let result = try await failure(stub)
      #expect(result.classification == .unknown && result.httpStatus == 200 && result.message == message)
    }
    let nonHTTP = try await failure(PipelineStub(nonHTTP: true))
    #expect(nonHTTP.classification == .unknown && nonHTTP.httpStatus == nil)
  }

  @Test func redactsBeforeBothBoundaries() async throws {
    for body in [String(repeating: "x", count: 480) + key, String(repeating: "x", count: 16_370) + key,
                 "{\"error\":{\"message\":\"" + key + "\"}}"] {
      let result = try await failure(PipelineStub(body: body))
      #expect(result.classification == .rateLimited && result.httpStatus == 429)
      #expect(result.rawBody?.contains("[REDACTED]") == true)
      for text in [result.message, result.rawBody ?? "", result.vendorMessage ?? "", result.rpcError.message, String(describing: result)] {
        for length in 8...31 { #expect(!text.contains(String(key.prefix(length)))) }
      }
    }
  }

  @Test func successAndDelegate() async throws {
    let stub = PipelineStub(status: 200, body: #"{"text":"hello"}"#)
    #expect(try await call(stub).text == "hello")
    #expect(stub.requests.count == 1)
    let url = try #require(URL(string: "https://example.invalid/original"))
    let response = try #require(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil))
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let request = URLRequest(url: url)
    let delegate = GatewayTranscriptionRedirectRefusal()
    let result = RedirectResult()
    delegate.urlSession(session, task: session.dataTask(with: request), willPerformHTTPRedirection: response,
                        newRequest: request) { result.set($0) }
    #expect(result.called && result.request == nil)
    #expect(delegate.refusedRedirectResponse?.statusCode == 302)
  }
}

private final class RedirectResult: @unchecked Sendable {
  var called = false
  var request: URLRequest?
  func set(_ request: URLRequest?) { called = true; self.request = request }
}
