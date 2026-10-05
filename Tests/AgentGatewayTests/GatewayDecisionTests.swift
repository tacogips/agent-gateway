import ACP
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AgentGateway
@testable import AgentGatewayAppCore

private let decisionFixture = #"""
{"id":"decision-1","model":"typesafe/jev-1.13-20260917","provider":"TypeSafe",
"answers":{
"team":{"type":"choice","choice":"billing","probabilities":{"billing":0.8,"technical":0.2},"confidence":0.7},
"urgency":{"type":"score","score":0.2,"legend":{"0":"routine","1":"urgent"},"probabilities":{"0":0.8,"1":0.2},"confidence":0.7},
"refund":{"type":"noul","noul":0.9}},
"usage":{"input_tokens":400,"output_tokens":30,"cost":0.000018}}
"""#

private func decisionHTTPResponse(_ request: URLRequest, status: Int) throws -> HTTPURLResponse {
  let url = try #require(request.url)
  return try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
}

private func decisionRequest() -> GatewayDecisionRequest {
  GatewayDecisionRequest(state: .object(["ticket": .string("Please refund my duplicate charge")]), questions: [
    "team": .choice(instructions: "Which team?", criteria: ["billing": "Invoices", "technical": "Bugs"]),
    "urgency": .score(instructions: "How urgent?", criteria: ["routine", "urgent"]),
    "refund": .noul(instructions: "Is a refund requested?")
  ])
}

@Test func decisionRequestUsesAlphaEndpointAndTypedQuestions() throws {
  let client = GatewayDecisionClient(environment: ["ROUTER_TOKEN": "test-token"], apiKeyEnvironment: "ROUTER_TOKEN")
  var decision = decisionRequest()
  decision.model = "~typesafe/jev-latest"
  decision.sessionID = "workflow-1"
  decision.provider = ["allow_fallbacks": .bool(true)]
  decision.trace = ["trace_id": .string("trace-1")]
  decision.user = "user-1"
  let request = try client.makeRequest(decision)
  #expect(request.url?.absoluteString == "https://openrouter.ai/api/alpha/decisions")
  #expect(request.httpMethod == "POST")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
  #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
  let data = try #require(request.httpBody)
  #expect(try JSONDecoder().decode(GatewayDecisionRequest.self, from: data) == decision)
  let body = try JSONDecoder().decode(ACPJSONValue.self, from: data)
  #expect(body["session_id"] == .string("workflow-1"))
  #expect(body["stream"] == nil)
  #expect(body["messages"] == nil)
}

@Test func decisionQuestionsSupportAllStateShapesAndExplicitNoulCriteria() throws {
  let question = GatewayDecisionQuestion.noul(instructions: "Is this a bug?", criteria: ["true": "Broken", "false": "Working"])
  #expect(try JSONDecoder().decode(GatewayDecisionQuestion.self, from: JSONEncoder().encode(question)) == question)
  for state in [ACPJSONValue.string("ticket"), .array([.string("first"), .string("second")]), .object([:])] {
    try GatewayDecisionRequest(state: state, questions: ["bug": question]).validate()
  }
}

@Test func decisionRejectsInvalidRequestsAndMissingCredentials() throws {
  let client = GatewayDecisionClient(environment: [:])
  #expect(throws: GatewayRPCError.self) { try client.makeRequest(decisionRequest()) }
  var request = decisionRequest()
  request.questions = [:]
  #expect(throws: GatewayRPCError.self) { try request.validate() }
  request = decisionRequest()
  request.state = .bool(true)
  #expect(throws: GatewayRPCError.self) { try request.validate() }
  request = decisionRequest()
  request.questions = ["refund": .noul(instructions: "", criteria: ["true": "yes"])]
  #expect(throws: GatewayRPCError.self) { try request.validate() }
  request = decisionRequest()
  request.questions = ["team": .choice(instructions: "team", criteria: [:])]
  #expect(throws: GatewayRPCError.self) { try request.validate() }
  request = decisionRequest()
  request.sessionID = String(repeating: "x", count: 257)
  #expect(throws: GatewayRPCError.self) { try request.validate() }
}

@Test func decisionBaseURLUsesExplicitAlphaBaseAndRejectsUnsafeURLs() throws {
  for base in ["https://proxy.example/api/alpha/", "http://127.0.0.1:8080/api/alpha/"] {
    let client = GatewayDecisionClient(environment: ["OPENROUTER_API_KEY": "test-token"], baseURL: base)
    #expect(try client.makeRequest(decisionRequest()).url?.absoluteString == base + "decisions")
  }
  for base in ["http://proxy.example/api/alpha", "https://user:password@proxy.example/api/alpha", "https://proxy.example/api/alpha?key=value"] {
    let client = GatewayDecisionClient(environment: ["OPENROUTER_API_KEY": "test-token"], baseURL: base)
    #expect(throws: GatewayRPCError.self) { try client.makeRequest(decisionRequest()) }
  }
}

@Test func decisionClientReturnsAllTypedAnswersAndUsage() async throws {
  let client = GatewayDecisionClient(environment: ["OPENROUTER_API_KEY": "test-token"]) { request in
    #expect(request.url?.path == "/api/alpha/decisions")
    let response = try decisionHTTPResponse(request, status: 200)
    return (Data(decisionFixture.utf8), response)
  }
  let result = try await client.decide(decisionRequest())
  #expect(result.answers["refund"] == .noul(0.9))
  #expect(result.answers["team"] == .choice(choice: "billing", probabilities: ["billing": 0.8, "technical": 0.2], confidence: 0.7))
  #expect(result.usage.inputTokens == 400)
  #expect(result.usage.outputTokens == 30)
  #expect(result.usage.cost == 0.000018)
  #expect(result.id == "decision-1")
  #expect(result.provider == "TypeSafe")
  #expect(try JSONDecoder().decode(GatewayDecisionResult.self, from: JSONEncoder().encode(result)) == result)
}

private actor DecisionAttempts {
  private var count = 0
  func next() -> Int { count += 1; return count }
  func total() -> Int { count }
}

@Test func decisionRetriesTransientHTTPFailure() async throws {
  let attempts = DecisionAttempts()
  let client = GatewayDecisionClient(
    environment: ["OPENROUTER_API_KEY": "test-token"],
    retryPolicy: GatewayRetryPolicy(maxAttempts: 2, initialDelayMilliseconds: 0, maximumDelayMilliseconds: 0)
  ) { request in
    let status = await attempts.next() == 1 ? 429 : 200
    let response = try decisionHTTPResponse(request, status: status)
    return (Data(decisionFixture.utf8), response)
  }
  _ = try await client.decide(decisionRequest())
  #expect(await attempts.total() == 2)
}

@Test func decisionHTTPFailuresRedactCredentialsAndDoNotRetryAuthentication() async throws {
  let attempts = DecisionAttempts()
  let client = GatewayDecisionClient(environment: ["OPENROUTER_API_KEY": "test-token"]) { request in
    _ = await attempts.next()
    let response = try decisionHTTPResponse(request, status: 401)
    return (Data("test-token invalid".utf8), response)
  }
  do {
    _ = try await client.decide(decisionRequest())
    Issue.record("Expected HTTP failure")
  } catch let error as GatewayRPCError {
    #expect(error.message.contains("HTTP 401"))
    #expect(error.message.contains("<redacted>"))
    #expect(!error.message.contains("test-token"))
  }
  #expect(await attempts.total() == 1)
}

@Test func decisionRejectsMalformedAndMismatchedResponses() async throws {
  for fixture in ["{}", decisionFixture.replacingOccurrences(of: "0.9", with: "1.9"),
                  decisionFixture.replacingOccurrences(of: "\"refund\"", with: "\"unknown\""),
                  decisionFixture.replacingOccurrences(of: "\"choice\":\"billing\"", with: "\"choice\":\"other\"")] {
    let client = GatewayDecisionClient(environment: ["OPENROUTER_API_KEY": "test-token"]) { request in
      let response = try decisionHTTPResponse(request, status: 200)
      return (Data(fixture.utf8), response)
    }
    await #expect(throws: GatewayRPCError.self) { try await client.decide(decisionRequest()) }
  }
}

@Test func decisionCancellationIsPropagatedWithoutRetry() async throws {
  let attempts = DecisionAttempts()
  let client = GatewayDecisionClient(environment: ["OPENROUTER_API_KEY": "test-token"]) { _ in
    _ = await attempts.next()
    throw CancellationError()
  }
  await #expect(throws: CancellationError.self) { try await client.decide(decisionRequest()) }
  #expect(await attempts.total() == 1)
}
