import Foundation
import Testing
@testable import AgentGateway
@testable import AgentGatewayAppCore

@Test func openRouterRequestUsesChatCompletionsAndCredentialName() throws {
  let request = try makeAPIRequest(
    GatewayExecuteParams(
      vendor: .openRouter,
      model: "anthropic/claude-sonnet",
      prompt: "hello",
      systemPrompt: "system",
      apiKeyEnvironment: "ROUTER_TOKEN"
    ),
    environment: ["ROUTER_TOKEN": "secret"]
  )
  #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
  let bodyData = try #require(request.httpBody)
  let object = try JSONSerialization.jsonObject(with: bodyData)
  let body = try #require(object as? [String: Any])
  #expect(body["stream"] as? Bool == true)
  #expect(body["model"] as? String == "anthropic/claude-sonnet")
}

@Test func anthropicRequestUsesNativeMessagesProtocol() throws {
  let request = try makeAPIRequest(
    GatewayExecuteParams(vendor: .anthropic, model: "claude-sonnet", prompt: "hello"),
    environment: ["ANTHROPIC_API_KEY": "secret"]
  )
  #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
  #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
  #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
}

@Test func geminiRequestUsesSSEStreamingEndpoint() throws {
  let request = try makeAPIRequest(
    GatewayExecuteParams(vendor: .gemini, model: "gemini-flash", prompt: "hello"),
    environment: ["GEMINI_API_KEY": "secret"]
  )
  #expect(request.url?.absoluteString ==
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash:streamGenerateContent?alt=sse&key=secret")
}

@Test func cursorAPIRequestUsesTypedRepositoryOptionsAndBasicAuthentication() throws {
  let request = try makeAPIRequest(
    GatewayExecuteParams(
      vendor: .cursorAPI,
      model: "composer-1",
      prompt: "implement it",
      cursorAPI: GatewayCursorAPIOptions(
        repositoryURL: "https://github.com/example/project.git",
        startingRef: "main",
        workOnCurrentBranch: true,
        autoCreatePR: false
      )
    ),
    environment: ["CURSOR_API_KEY": "cursor-secret"]
  )
  #expect(request.url?.absoluteString == "https://api.cursor.com/v1/agents")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic Y3Vyc29yLXNlY3JldDo=")
  let bodyData = try #require(request.httpBody)
  let object = try JSONSerialization.jsonObject(with: bodyData)
  let body = try #require(object as? [String: Any])
  let repositories = try #require(body["repos"] as? [[String: Any]])
  #expect(repositories.first?["url"] as? String == "https://github.com/example/project.git")
  #expect(repositories.first?["startingRef"] as? String == "main")
  #expect(body["workOnCurrentBranch"] as? Bool == true)
  #expect(body["autoCreatePR"] as? Bool == false)
}

@Test func openAIReuseRequestUsesPreviousResponseID() throws {
  let request = try makeAPIRequest(
    GatewayExecuteParams(
      vendor: .openAI,
      model: "gpt-5",
      prompt: "continue",
      sessionMode: .reuse,
      sessionId: "response-1"
    ),
    environment: ["OPENAI_API_KEY": "secret"]
  )
  let bodyData = try #require(request.httpBody)
  let object = try JSONSerialization.jsonObject(with: bodyData)
  let body = try #require(object as? [String: Any])
  #expect(body["previous_response_id"] as? String == "response-1")
}

@Test func openAIRequestEncodesTypedImageInput() throws {
  let request = try makeAPIRequest(
    GatewayExecuteParams(
      vendor: .openAI,
      model: "gpt-5",
      prompt: "describe",
      images: [GatewayImageInput(dataBase64: "aGVsbG8=", mimeType: "image/png")]
    ),
    environment: ["OPENAI_API_KEY": "secret"]
  )
  let bodyData = try #require(request.httpBody)
  let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
  let input = try #require(body["input"] as? [[String: Any]])
  let content = try #require(input.first?["content"] as? [[String: Any]])
  #expect(content.count == 2)
  #expect(content[1]["type"] as? String == "input_image")
  #expect(content[1]["image_url"] as? String == "data:image/png;base64,aGVsbG8=")
}

@Test func vendorStreamParsersExtractAssistantDeltas() {
  #expect(parseVendorJSON(
    #"{"type":"response.output_text.delta","delta":"openai"}"#,
    vendor: .openAI
  ).delta == "openai")
  #expect(parseVendorJSON(
    #"{"type":"response.created","response":{"id":"response-123"}}"#,
    vendor: .openAI
  ).sessionId == "response-123")
  #expect(parseVendorJSON(
    #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"anthropic"}}"#,
    vendor: .anthropic
  ).delta == "anthropic")
  #expect(parseVendorJSON(
    #"{"choices":[{"delta":{"content":"router"}}]}"#,
    vendor: .openRouter
  ).delta == "router")
  #expect(parseVendorJSON(
    #"{"candidates":[{"content":{"parts":[{"text":"gemini"}]}}]}"#,
    vendor: .gemini
  ).delta == "gemini")
}
