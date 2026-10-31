import Foundation
import Testing
@testable import AgentGateway

@Test func subscriptionUsageTypesClassification() {
  #expect(GatewaySubscriptionUsageWindowKind.classify(windowMinutes: 300) == .fiveHour)
  #expect(GatewaySubscriptionUsageWindowKind.classify(windowMinutes: 10080) == .weekly)
  #expect(GatewaySubscriptionUsageWindowKind.classify(windowMinutes: 60) == .other)
  #expect(GatewaySubscriptionUsageWindowKind.classify(windowMinutes: nil) == .other)
}

@Test func subscriptionUsageTypesWindowRoundTrip() throws {
  let window = GatewaySubscriptionUsageWindow(
    kind: .fiveHour, windowMinutes: 300, usedPercent: 28,
    resetsAt: Date(timeIntervalSince1970: 1793469600)
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  let data = try encoder.encode(window)
  let json = try #require(String(data: data, encoding: .utf8))
  #expect(json.contains("\"resetsAt\":\"2026-10-31T18:00:00Z\""))
  #expect(try JSONDecoder().decode(GatewaySubscriptionUsageWindow.self, from: data) == window)
}

@Test func subscriptionUsageTypesOptionalFieldsOmitted() throws {
  let window = GatewaySubscriptionUsageWindow(kind: .other, windowMinutes: nil, usedPercent: 0, resetsAt: nil)
  let data = try JSONEncoder().encode(window)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(object["scope"] == nil)
  #expect(object["windowMinutes"] == nil)
  #expect(object["resetsAt"] == nil)
}

@Test func subscriptionUsageTypesFractionalDate() throws {
  for fraction in ["0", "066", "066934", "066934123456789"] {
    let json = """
      {"kind":"weekly","usedPercent":68,"resetsAt":"2026-11-01T17:00:00.\(fraction)+00:00"}
      """
    let window = try JSONDecoder().decode(GatewaySubscriptionUsageWindow.self, from: Data(json.utf8))
    let expected = try #require(parseGatewayISO8601Date("2026-11-01T17:00:00.\(fraction == "0" ? "000" : "066")Z"))
    #expect(abs(try #require(window.resetsAt).timeIntervalSince(expected)) < 0.001)
  }
  #expect(parseGatewayISO8601Date("2026-11-01T17:00:00+00:00") != nil)
  #expect(parseGatewayISO8601Date("garbage") == nil)
}

@Test func subscriptionUsageTypesInvalidDate() throws {
  let data = Data(#"{"kind":"weekly","usedPercent":68,"resetsAt":"not-a-date"}"#.utf8)
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(GatewaySubscriptionUsageWindow.self, from: data)
  }
}

@Test func subscriptionUsageTypesResultRoundTrip() throws {
  let window = GatewaySubscriptionUsageWindow(kind: .weekly, windowMinutes: 10080, usedPercent: 68, resetsAt: nil)
  let result = GatewaySubscriptionUsageResult(vendor: .codex, planType: "pro", available: true, windows: [window])
  let data = try JSONEncoder().encode(result)
  #expect(try #require(String(data: data, encoding: .utf8)).contains("\"vendor\":\"codex\""))
  #expect(try JSONDecoder().decode(GatewaySubscriptionUsageResult.self, from: data) == result)
}
