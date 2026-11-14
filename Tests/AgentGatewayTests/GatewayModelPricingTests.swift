import Foundation
import Testing
@testable import AgentGateway
@testable import AgentGatewayAppCore

/// A trimmed LiteLLM `model_prices_and_context_window.json` payload,
/// including the "sample_spec" documentation entry that must be ignored.
private let liteLLMFixtureJSON = #"""
{
  "sample_spec": {
    "input_cost_per_token": "0.0000030",
    "output_cost_per_token": "0.0000150",
    "litellm_provider": "one of https://docs.litellm.ai/docs/providers"
  },
  "claude-sonnet-4-5": {
    "input_cost_per_token": 3e-06,
    "output_cost_per_token": 1.5e-05,
    "cache_read_input_token_cost": 3e-07,
    "cache_creation_input_token_cost": 3.75e-06,
    "litellm_provider": "anthropic",
    "supports_prompt_caching": true
  },
  "gpt-5": {
    "input_cost_per_token": 1.25e-06,
    "output_cost_per_token": 1e-05,
    "litellm_provider": "openai"
  },
  "gemini/gemini-2.5-pro": {
    "input_cost_per_token": 1.25e-06,
    "output_cost_per_token": 1e-05,
    "litellm_provider": "gemini"
  },
  "openrouter/anthropic/claude-sonnet-4.5": {
    "input_cost_per_token": 3e-06,
    "output_cost_per_token": 1.5e-05,
    "litellm_provider": "openrouter"
  },
  "free-model": {
    "input_cost_per_token": 0.0,
    "output_cost_per_token": 0.0,
    "litellm_provider": "openrouter"
  },
  "no-costs-model": {
    "litellm_provider": "openai",
    "max_input_tokens": 128000
  }
}
"""#

/// A distinct payload for the fallback pricing table so tests can tell
/// which source answered.
private let fallbackTableFixtureJSON = #"""
{
  "claude-sonnet-4-5": {"input_cost_per_token": 9e-06, "output_cost_per_token": 9e-05}
}
"""#

private func fixtureStore(source: GatewayModelPricingSource = .liteLLMRemote) -> GatewayModelPricingStore {
  GatewayModelPricingStore(
    prices: parseLiteLLMModelPrices(Data(liteLLMFixtureJSON.utf8)),
    source: source
  )
}

private func temporaryCacheDirectoryURL() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("agent-gateway-tests-\(UUID().uuidString)", isDirectory: true)
}

private func writeCacheFile(_ url: URL, contents: String, modified: Date? = nil) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
  )
  try Data(contents.utf8).write(to: url)
  if let modified {
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
  }
}

private func liteLLMCacheURL(_ loader: GatewayModelPricingLoader) -> URL {
  loader.sources[0].cacheFileURL
}

private func fallbackCacheURL(_ loader: GatewayModelPricingLoader) -> URL {
  loader.sources[1].cacheFileURL
}

@Test func liteLLMParsingSkipsNonNumericAndCostlessEntries() {
  let prices = parseLiteLLMModelPrices(Data(liteLLMFixtureJSON.utf8))
  #expect(prices["sample_spec"] == nil)
  #expect(prices["no-costs-model"] == nil)
  #expect(prices["claude-sonnet-4-5"] == GatewayModelPricing(
    inputCostPerToken: 3e-06,
    outputCostPerToken: 1.5e-05,
    cacheReadInputTokenCost: 3e-07,
    cacheCreationInputTokenCost: 3.75e-06
  ))
  #expect(prices["claude-sonnet-4-5"]?.currency == "USD")
  // Zero-cost (free) models must survive the numeric filtering.
  #expect(prices["free-model"] == GatewayModelPricing(inputCostPerToken: 0, outputCostPerToken: 0))
}

@Test func pricingLookupUsesVendorSpecificKeys() {
  let store = fixtureStore()
  #expect(store.pricing(for: "claude-sonnet-4-5", vendor: .anthropic)?.inputCostPerToken == 3e-06)
  #expect(store.pricing(for: "claude-sonnet-4-5", vendor: .claudeCode)?.inputCostPerToken == 3e-06)
  #expect(store.pricing(for: "gpt-5", vendor: .openAI)?.outputCostPerToken == 1e-05)
  #expect(store.pricing(for: "gpt-5", vendor: .codex)?.outputCostPerToken == 1e-05)
  #expect(store.pricing(for: "gemini-2.5-pro", vendor: .gemini)?.inputCostPerToken == 1.25e-06)
  #expect(store.pricing(for: "anthropic/claude-sonnet-4.5", vendor: .openRouter)?.inputCostPerToken == 3e-06)
  #expect(store.pricing(for: "unknown-model", vendor: .anthropic) == nil)
  #expect(store.pricing(for: "claude-sonnet-4-5", vendor: .cursor) == nil)
  #expect(store.pricing(for: "claude-sonnet-4-5", vendor: .cursorAPI) == nil)
}

@Test func repositoryFallbackTableParsesAndCoversVendors() throws {
  // data/model-prices.json is the table published at the fallback remote
  // URL; it must stay a valid LiteLLM-format extract.
  let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // GatewayModelPricingTests.swift
    .deletingLastPathComponent()  // AgentGatewayTests
    .deletingLastPathComponent()  // Tests
  let tableURL = repoRoot.appendingPathComponent("data/model-prices.json")
  let prices = parseLiteLLMModelPrices(try Data(contentsOf: tableURL))
  #expect(!prices.isEmpty)
  #expect(prices.keys.contains { $0.hasPrefix("claude-") })
  #expect(prices.keys.contains { $0.hasPrefix("gpt-") })
  #expect(prices.keys.contains { $0.hasPrefix("gemini/") })
  #expect(prices.keys.contains { $0.hasPrefix("openrouter/") })
}

@Test func loaderOffModeReturnsNothing() async {
  let loader = GatewayModelPricingLoader(
    fetch: { _ in
      Issue.record("off mode must not fetch")
      throw GatewayRPCError(code: -1, message: "unexpected fetch")
    },
    cacheDirectoryURL: temporaryCacheDirectoryURL()
  )
  #expect(await loader.load(mode: .off) == nil)
}

@Test func loaderOfflineModeUsesCachesOnlyAndNeverFetches() async throws {
  let loader = GatewayModelPricingLoader(
    fetch: { _ in
      Issue.record("offline mode must not fetch")
      throw GatewayRPCError(code: -1, message: "unexpected fetch")
    },
    cacheDirectoryURL: temporaryCacheDirectoryURL()
  )

  // No caches at all: pricing is unavailable, and that is not an error.
  #expect(await loader.load(mode: .offline) == nil)

  // Only the fallback-table cache exists (even stale): it answers.
  try writeCacheFile(
    fallbackCacheURL(loader),
    contents: fallbackTableFixtureJSON,
    modified: Date(timeIntervalSinceNow: -90 * 24 * 60 * 60)
  )
  let fallbackOnly = await loader.load(mode: .offline)
  #expect(fallbackOnly?.source == .fallbackTableCache)

  // Once the LiteLLM cache exists too, it wins over the fallback cache.
  try writeCacheFile(
    liteLLMCacheURL(loader),
    contents: liteLLMFixtureJSON,
    modified: Date(timeIntervalSinceNow: -90 * 24 * 60 * 60)
  )
  let both = await loader.load(mode: .offline)
  #expect(both?.source == .liteLLMCache)
  #expect(both?.prices["gpt-5"] != nil)
}

@Test func loaderAutoModeUsesFreshLiteLLMCacheWithoutFetching() async throws {
  let loader = GatewayModelPricingLoader(
    fetch: { _ in
      Issue.record("fresh cache must short-circuit the fetch")
      throw GatewayRPCError(code: -1, message: "unexpected fetch")
    },
    cacheDirectoryURL: temporaryCacheDirectoryURL()
  )
  try writeCacheFile(liteLLMCacheURL(loader), contents: liteLLMFixtureJSON)
  let store = await loader.load(mode: .auto)
  #expect(store?.source == .liteLLMCache)
}

@Test func loaderAutoModeFetchesWhenCacheIsStaleAndWritesCache() async throws {
  let loader = GatewayModelPricingLoader(
    fetch: { url in
      #expect(url == GatewayModelPricingLoader.liteLLMRemoteURL)
      return Data(liteLLMFixtureJSON.utf8)
    },
    cacheDirectoryURL: temporaryCacheDirectoryURL()
  )
  try writeCacheFile(
    liteLLMCacheURL(loader),
    contents: #"{"old-model": {"input_cost_per_token": 1e-06}}"#,
    modified: Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
  )
  let store = await loader.load(mode: .auto)
  #expect(store?.source == .liteLLMRemote)
  #expect(store?.prices["gpt-5"] != nil)
  // The remote payload replaces the on-disk cache.
  let rewritten = parseLiteLLMModelPrices(try Data(contentsOf: liteLLMCacheURL(loader)))
  #expect(rewritten["gpt-5"] != nil)
  #expect(rewritten["old-model"] == nil)
}

@Test func loaderAutoModeFallsBackToRepositoryTableWhenLiteLLMFails() async throws {
  let loader = GatewayModelPricingLoader(
    fetch: { url in
      if url == GatewayModelPricingLoader.liteLLMRemoteURL {
        throw GatewayRPCError(code: -32010, message: "litellm unavailable")
      }
      #expect(url == GatewayModelPricingLoader.fallbackTableRemoteURL)
      return Data(fallbackTableFixtureJSON.utf8)
    },
    cacheDirectoryURL: temporaryCacheDirectoryURL()
  )
  let store = await loader.load(mode: .auto)
  #expect(store?.source == .fallbackTableRemote)
  #expect(store?.prices["claude-sonnet-4-5"]?.inputCostPerToken == 9e-06)
  // The fallback fetch fills the fallback cache for later offline runs.
  let cached = parseLiteLLMModelPrices(try Data(contentsOf: fallbackCacheURL(loader)))
  #expect(cached["claude-sonnet-4-5"] != nil)
}

@Test func loaderAutoModePrefersStaleLiteLLMCacheOverFallbackTable() async throws {
  let loader = GatewayModelPricingLoader(
    fetch: { url in
      if url == GatewayModelPricingLoader.liteLLMRemoteURL {
        throw GatewayRPCError(code: -32010, message: "litellm unavailable")
      }
      Issue.record("a stale LiteLLM cache must answer before the fallback table")
      throw GatewayRPCError(code: -1, message: "unexpected fetch")
    },
    cacheDirectoryURL: temporaryCacheDirectoryURL()
  )
  try writeCacheFile(
    liteLLMCacheURL(loader),
    contents: liteLLMFixtureJSON,
    modified: Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
  )
  let store = await loader.load(mode: .auto)
  #expect(store?.source == .liteLLMCache)
}

@Test func loaderAutoModeReturnsNothingWhenEverythingFails() async {
  let loader = GatewayModelPricingLoader(
    fetch: { _ in throw GatewayRPCError(code: -32010, message: "offline") },
    cacheDirectoryURL: temporaryCacheDirectoryURL()
  )
  #expect(await loader.load(mode: .auto) == nil)
}

@Test func attachPricingAnnotatesModelsAndKeepsUnknownOnesListed() async {
  let catalog = GatewayModelCatalogResult(
    vendor: .anthropic,
    models: [
      GatewayModelInfo(modelId: "claude-sonnet-4-5", name: "Claude Sonnet 4.5"),
      GatewayModelInfo(modelId: "brand-new-model")
    ]
  )
  let loader = GatewayModelPricingLoader(
    fetch: { _ in Data(liteLLMFixtureJSON.utf8) },
    cacheDirectoryURL: temporaryCacheDirectoryURL()
  )
  let priced = await attachGatewayModelPricing(to: catalog, mode: .auto, loader: loader)
  #expect(priced.pricingSource == .liteLLMRemote)
  #expect(priced.models[0].pricing?.inputCostPerToken == 3e-06)
  #expect(priced.models[0].pricing?.currency == "USD")
  #expect(priced.models[0].name == "Claude Sonnet 4.5")
  #expect(priced.models[1].pricing == nil)
  #expect(priced.models.count == 2)
}

@Test func attachPricingLeavesCatalogUntouchedWhenOffOrUnavailable() async {
  let catalog = GatewayModelCatalogResult(
    vendor: .openAI,
    models: [GatewayModelInfo(modelId: "gpt-5")]
  )
  let workingLoader = GatewayModelPricingLoader(
    fetch: { _ in Data(liteLLMFixtureJSON.utf8) },
    cacheDirectoryURL: temporaryCacheDirectoryURL()
  )
  let off = await attachGatewayModelPricing(to: catalog, mode: .off, loader: workingLoader)
  #expect(off == catalog)

  // When every pricing layer fails, the model list itself must pass
  // through unchanged instead of failing the query.
  let failingLoader = GatewayModelPricingLoader(
    fetch: { _ in throw GatewayRPCError(code: -32010, message: "offline") },
    cacheDirectoryURL: temporaryCacheDirectoryURL()
  )
  let unpriced = await attachGatewayModelPricing(to: catalog, mode: .auto, loader: failingLoader)
  #expect(unpriced == catalog)
}
