import Foundation
import Testing
@testable import AgentGatewayAppCore

@Test func decisionCommandAcceptsFileAndStdinRequests() throws {
  let json = #"{"model":"typesafe/jev-1.13","state":"refund please","questions":{"refund":{"type":"noul","instructions":"Is a refund requested?"}}}"#
  let command = AppCommand(arguments: ["decide", "--request", "-"])
  #expect(try command.run().isEmpty)
  let options = try command.decisionOptions(["--request", "-", "--api-key-environment", "TOKEN", "--base-url", "https://proxy.example/alpha"])
  #expect(options.apiKeyEnvironment == "TOKEN")
  #expect(options.baseURL == "https://proxy.example/alpha")
  let request = try options.loadRequest(stdin: { Data(json.utf8) })
  #expect(request.model == "typesafe/jev-1.13")
  let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
  try Data(json.utf8).write(to: path)
  defer { try? FileManager.default.removeItem(at: path) }
  let fileOptions = try command.decisionOptions(["--request", path.path])
  #expect(try fileOptions.loadRequest() == request)
}

@Test func decisionCommandRejectsMissingUnknownAndMalformedInputs() throws {
  let command = AppCommand(arguments: [])
  #expect(throws: AppCommand.Error.missingValue("--request")) { try command.decisionOptions([]) }
  #expect(throws: AppCommand.Error.missingValue("--base-url")) { try command.decisionOptions(["--request", "-", "--base-url"]) }
  #expect(throws: AppCommand.Error.unknownArgument("--prompt")) { try command.decisionOptions(["--prompt", "hi"]) }
  let options = try command.decisionOptions(["--request", "-"])
  #expect(throws: (any Error).self) { try options.loadRequest(stdin: { Data("{}".utf8) }) }
}

@Test func decisionHelpDoesNotExecuteRequest() async throws {
  let command = AppCommand(arguments: ["decide", "--help"])
  #expect(try command.run().contains("decide --request"))
  #expect(try await command.runStreaming() == 0)
}
