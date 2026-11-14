import Foundation
import Testing
import AgentGateway
@testable import AgentGatewayAppCore

@Suite struct GatewayTranscriptionRedirectTests {
  @Test func productionTransportDoesNotFollowRedirect() async throws {
    let body = #"{"text":"followed"}"#
    let server = LoopbackHTTPServer(routes: [
      "/redirected": "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    ])
    let port = try server.start()
    defer { server.stop() }
    server.setRoute("/v1/audio/transcriptions", response:
      "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(port)/redirected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    let key = "fixture-secret-0123456789abcdef"
    let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
    try Data([1, 2, 3]).write(to: audio)
    defer { try? FileManager.default.removeItem(at: audio) }
    let params = GatewayTranscriptionParams(vendor: .openAI, model: "whisper-1", audioFile: audio,
      mimeType: "audio/mpeg", apiKeyEnvironment: "TEST_OPENAI_KEY",
      baseURL: "http://127.0.0.1:\(port)/v1", timeoutSeconds: 5)
    do {
      let result = try await ProductionGatewayExecutor(environment: ["TEST_OPENAI_KEY": key]).transcribe(params)
      Issue.record("redirect was followed: \(result.text)")
    } catch let failure as GatewayTranscriptionFailure {
      #expect(failure.httpStatus == 302)
      #expect(failure.classification == .unknown)
      #expect(!String(describing: failure).contains(key))
    }
    #expect(server.requestCount(path: "/v1/audio/transcriptions") == 1)
    #expect(server.requestCount(path: "/redirected") == 0)
  }
}
