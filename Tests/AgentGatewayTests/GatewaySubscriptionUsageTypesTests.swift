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

@Test func subscriptionUsageLimitStatusAndNextReset() throws {
  let early = Date(timeIntervalSince1970: 1793469600)
  let late = early.addingTimeInterval(3600)
  for vendor in [GatewayVendor.codex, .claudeCode] {
    var result = GatewaySubscriptionUsageResult(vendor: vendor, planType: "pro", available: true, windows: [
      .init(kind: .fiveHour, windowMinutes: 300, usedPercent: 100, resetsAt: late),
      .init(kind: .weekly, scope: "model", windowMinutes: 10080, usedPercent: 105, resetsAt: early),
      .init(kind: .other, windowMinutes: 60, usedPercent: 99.9, resetsAt: early.addingTimeInterval(-3600))
    ])
    #expect(result.status == .limitReached)
    #expect(result.limitHit == true)
    #expect(result.nextResetAt == early)
    let encoded = try JSONEncoder().encode(result)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["status"] as? String == "limitReached")
    #expect(object["limitHit"] as? Bool == true)
    #expect(object["nextResetAt"] as? String == "2026-10-31T18:00:00Z")
    let windows = try #require(object["windows"] as? [[String: Any]])
    #expect(windows.map { $0["limitHit"] as? Bool } == [true, true, false])
    #expect(try JSONDecoder().decode(GatewaySubscriptionUsageResult.self, from: encoded) == result)

    result.windows.removeFirst(2)
    #expect(result.status == .available)
    #expect(result.limitHit == false)
    #expect(result.nextResetAt == nil)
    result.windows[0].usedPercent = 100
    result.windows[0].resetsAt = nil
    #expect(result.status == .limitReached)
    #expect(result.nextResetAt == nil)
  }
}

@Test func subscriptionUsageUnknownAndLegacyDecoding() throws {
  let legacy = Data(#"{"protocolVersion":"1","vendor":"codex","available":true,"windows":[]}"#.utf8)
  var result = try JSONDecoder().decode(GatewaySubscriptionUsageResult.self, from: legacy)
  #expect(result.status == .unavailable)
  #expect(result.limitHit == nil)
  result.available = false
  result.windows = [.init(kind: .weekly, windowMinutes: 10080, usedPercent: 100, resetsAt: Date())]
  #expect(result.status == .unavailable)
  #expect(result.nextResetAt == nil)
  let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
  #expect(object["limitHit"] is NSNull)
  #expect(object["nextResetAt"] == nil)
}
