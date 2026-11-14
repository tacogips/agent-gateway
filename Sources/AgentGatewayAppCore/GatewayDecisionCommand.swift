import AgentGateway
import Foundation

struct GatewayDecisionCommandOptions {
  var requestPath: String
  var apiKeyEnvironment = "OPENROUTER_API_KEY"
  var baseURL = "https://openrouter.ai/api/alpha"

  func loadRequest(stdin: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }) throws -> GatewayDecisionRequest {
    let data = try requestPath == "-" ? stdin() : Data(contentsOf: URL(fileURLWithPath: requestPath))
    let request: GatewayDecisionRequest
    do { request = try JSONDecoder().decode(GatewayDecisionRequest.self, from: data) } catch {
      throw GatewayRPCError(code: -32602, message: "invalid decision request JSON; expected model, state, and typed questions")
    }
    try request.validate()
    return request
  }
}

extension AppCommand {
  func decisionOptions(_ arguments: [String]) throws -> GatewayDecisionCommandOptions {
    var values: [String: String] = [:]
    let flags = ["--request", "--api-key-environment", "--base-url"]
    var index = 0
    while index < arguments.count {
      let flag = arguments[index]
      guard flags.contains(flag) else { throw Error.unknownArgument(flag) }
      guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"), !arguments[index + 1].isEmpty else {
        throw Error.missingValue(flag)
      }
      values[flag] = arguments[index + 1]
      index += 2
    }
    guard let path = values["--request"] else { throw Error.missingValue("--request") }
    var options = GatewayDecisionCommandOptions(requestPath: path)
    if let key = values["--api-key-environment"] { options.apiKeyEnvironment = key }
    if let base = values["--base-url"] { options.baseURL = base }
    return options
  }
}
