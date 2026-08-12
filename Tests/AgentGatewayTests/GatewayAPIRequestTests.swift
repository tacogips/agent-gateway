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

@Test func vendorStreamParsersExtractAssistantDeltas() {
  #expect(parseVendorJSON(
    #"{"type":"response.output_text.delta","delta":"openai"}"#,
    vendor: .openAI
  ).delta == "openai")
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
