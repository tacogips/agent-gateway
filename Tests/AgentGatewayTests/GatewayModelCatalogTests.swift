import Foundation
import Testing
@testable import AgentGateway
@testable import AgentGatewayAppCore

@Test func modelListRequestUsesVendorEndpointsAndCredentials() throws {
  let openAI = try makeModelListRequest(
    GatewayModelCatalogParams(vendor: .openAI),
    environment: ["OPENAI_API_KEY": "secret"]
  )
  #expect(openAI.url?.absoluteString == "https://api.openai.com/v1/models")
  #expect(openAI.httpMethod == "GET")
  #expect(openAI.value(forHTTPHeaderField: "Authorization") == "Bearer secret")

  let anthropic = try makeModelListRequest(
    GatewayModelCatalogParams(vendor: .anthropic),
    environment: ["ANTHROPIC_API_KEY": "secret"]
  )
  #expect(anthropic.url?.absoluteString == "https://api.anthropic.com/v1/models")
  #expect(anthropic.value(forHTTPHeaderField: "x-api-key") == "secret")

  let gemini = try makeModelListRequest(
    GatewayModelCatalogParams(vendor: .gemini),
    environment: ["GEMINI_API_KEY": "secret"]
  )
  #expect(gemini.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models?key=secret")

  let overridden = try makeModelListRequest(
    GatewayModelCatalogParams(vendor: .openRouter, apiKeyEnvironment: "ROUTER_TOKEN", baseURL: "https://proxy.example/v1"),
    environment: ["ROUTER_TOKEN": "secret"]
  )
  #expect(overridden.url?.absoluteString == "https://proxy.example/v1/models")
}

@Test func modelListRequestRejectsCLIVendorsAsUnsupported() {
  do {
    _ = try makeModelListRequest(
      GatewayModelCatalogParams(vendor: .claudeCode),
      environment: [:]
    )
    Issue.record("expected an unsupported error for CLI vendors")
  } catch let error as GatewayRPCError {
    #expect(error.code == gatewayModelListingUnsupportedCode)
  } catch {
    Issue.record("unexpected error: \(error)")
  }
}

@Test func vendorModelListPayloadsAreParsedPerVendor() throws {
  func object(_ json: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
  }

  let openAI = parseVendorModelList(
    try object(#"{"data":[{"id":"gpt-5"},{"id":"gpt-5-mini"}]}"#), vendor: .openAI
  )
  #expect(openAI.map(\.modelId) == ["gpt-5", "gpt-5-mini"])

  let anthropic = parseVendorModelList(
    try object(#"{"data":[{"id":"claude-sonnet-5","display_name":"Claude Sonnet 5"}]}"#),
    vendor: .anthropic
  )
  #expect(anthropic == [GatewayModelInfo(modelId: "claude-sonnet-5", name: "Claude Sonnet 5")])

  let gemini = parseVendorModelList(
    try object(#"{"models":[{"name":"models/gemini-2.5-pro","displayName":"Gemini 2.5 Pro","description":"desc"}]}"#),
    vendor: .gemini
  )
  #expect(gemini == [GatewayModelInfo(modelId: "gemini-2.5-pro", name: "Gemini 2.5 Pro", description: "desc")])

  let cursor = parseVendorModelList(
    try object(#"{"models":["composer-1","o3"]}"#), vendor: .cursorAPI
  )
  #expect(cursor.map(\.modelId) == ["composer-1", "o3"])
}

@Test func modelsCommandBuildsTypedParams() throws {
  let (params, pricingMode) = try AppCommand(arguments: []).modelCatalogParams([
    "--vendor", "openrouter",
    "--api-key-environment", "ROUTER_TOKEN",
    "--base-url", "https://proxy.example/v1"
  ])
  #expect(params.vendor == .openRouter)
  #expect(params.apiKeyEnvironment == "ROUTER_TOKEN")
  #expect(params.baseURL == "https://proxy.example/v1")
  #expect(pricingMode == .auto)
}

@Test func modelsCommandParsesPricingMode() throws {
  let (_, offline) = try AppCommand(arguments: []).modelCatalogParams([
    "--vendor", "anthropic", "--pricing", "offline"
  ])
  #expect(offline == .offline)

  let (_, off) = try AppCommand(arguments: []).modelCatalogParams([
    "--vendor", "anthropic", "--pricing", "off"
  ])
  #expect(off == .off)

  #expect(throws: AppCommand.Error.missingValue("--pricing")) {
    _ = try AppCommand(arguments: []).modelCatalogParams([
      "--vendor", "anthropic", "--pricing", "sometimes"
    ])
  }
}
