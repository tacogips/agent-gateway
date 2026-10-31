import Foundation
import Testing
@testable import AgentGateway
@testable import AgentGatewayAppCore

private let claudeUsage = #"{"type":"control_response","response":{"subtype":"success","request_id":"agent-gateway-subscription-usage","response":{"subscription_type":"max","#
    + #""rate_limits_available":true,"extra":1,"rate_limits":{"five_hour":{"utilization":28,"resets_at":"2026-10-31T18:00:00.066915+00:00"},"#
    + #""seven_day":{"utilization":68},"seven_day_opus":null,"seven_day_sonnet":null,"model_scoped":[{"display_name":"Fable","utilization":0,"#
    + #""resets_at":"2026-11-01T17:00:00+00:00"}]}}}}"#
private let codexUsage = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","planType":"pro","primary":{"usedPercent":91,"windowDurationMins":10080,"resetsAt":1793774131},"secondary":null}}}"#
private func data(_ text: String) -> Data { Data(text.utf8) }

@Test func subscriptionUsageClaudeSuccess() throws {
  let result = try parseClaudeSubscriptionUsage(data(claudeUsage))
  #expect(result.planType == "max" && result.available)
  #expect(result.windows.map(\.kind) == [.fiveHour, .weekly, .weekly])
  #expect(result.windows.map(\.scope) == [nil, nil, "Fable"])
  #expect(result.windows.map(\.usedPercent) == [28, 68, 0])
  #expect(result.windows.map(\.windowMinutes) == [300, 10080, 10080])
  #expect(result.windows[0].resetsAt != nil)
}

@Test func subscriptionUsageClaudeFallbackAndUnavailable() throws {
  let legacy = #"{"response":{"response":{"rate_limits":{"five_hour":{"utilization":1},"seven_day":{"utilization":2},"seven_day_opus":{"utilization":40},"seven_day_sonnet":null}}}}"#
  let result = try parseClaudeSubscriptionUsage(data(legacy))
  #expect(result.windows.map(\.scope) == [nil, nil, "Opus"])
  #expect(result.windows.last?.usedPercent == 40)
  let unavailable = #"{"response":{"response":{"rate_limits_available":false,"rate_limits":{"five_hour":{"utilization":1}}}}}"#
  let empty = try parseClaudeSubscriptionUsage(data(unavailable))
  #expect(!empty.available && empty.windows.isEmpty)
}

@Test func subscriptionUsageVendorErrors() throws {
  for (input, parser) in [
    (#"{"response":{"subtype":"error","error":"boom"}}"#, parseClaudeSubscriptionUsage),
    (#"{"id":2,"error":{"message":"denied"}}"#, parseCodexSubscriptionUsage)
  ] {
    do {
      _ = try parser(data(input))
      Issue.record("Expected vendor error")
    } catch let error as GatewayRPCError {
      #expect(error.code == -32041)
      #expect(error.message.contains(input.contains("boom") ? "boom" : "denied"))
    }
  }
}

@Test func subscriptionUsageCodexSingleAndBuckets() throws {
  let single = try parseCodexSubscriptionUsage(data(codexUsage))
  #expect(single.available && single.planType == "pro")
  #expect(single.windows.count == 1 && single.windows[0].kind == .weekly)
  #expect(single.windows[0].usedPercent == 91 && single.windows[0].windowMinutes == 10080)
  #expect(single.windows[0].resetsAt == Date(timeIntervalSince1970: 1793774131))
  let multi = #"{"result":{"rateLimitsByLimitId":{"zeta":{"limitId":"zeta","limitName":"Zeta Model","primary":{"usedPercent":3,"windowDurationMins":300}},"#
    + #""codex":{"limitId":"codex","primary":{"usedPercent":1,"windowDurationMins":300},"secondary":{"usedPercent":2,"windowDurationMins":10080}},"#
    + #""alpha":{"limitId":"alpha","limitName":null,"primary":{"usedPercent":4,"windowDurationMins":60}},"null":null}}}"#
  let result = try parseCodexSubscriptionUsage(data(multi))
  #expect(result.windows.map(\.kind) == [.fiveHour, .weekly, .other, .fiveHour])
  #expect(result.windows.map(\.scope) == [nil, nil, "alpha", "Zeta Model"])
}

@Test func subscriptionUsageValidation() async throws {
  let executor = ProductionGatewayExecutor(environment: ["PATH": "/nonexistent"])
  for vendor in [GatewayVendor.cursor, .cursorAPI, .openAI, .anthropic, .gemini, .openRouter] {
    do {
      _ = try await executor.subscriptionUsage(.init(vendor: vendor, executable: "deliberately-absent"))
      Issue.record("Expected unsupported vendor")
    } catch let error as GatewayRPCError { #expect(error.code == -32040) }
  }
  for params in [GatewaySubscriptionUsageParams(protocolVersion: "0", vendor: .codex),
                 .init(vendor: .codex, timeoutSeconds: 0), .init(vendor: .codex, timeoutSeconds: .infinity)] {
    do {
      _ = try await executor.subscriptionUsage(params)
      Issue.record("Expected invalid parameters")
    } catch let error as GatewayRPCError { #expect(error.code == -32602) }
  }
  do {
    _ = try await executor.subscriptionUsage(.init(vendor: .codex, executable: "/missing/not-found"))
    Issue.record("Expected missing executable")
  } catch let error as GatewayRPCError {
    #expect(error.code == -32041 && error.message.contains("executable unavailable"))
  }
}

private func fakeUsageScript(_ body: String) throws -> (URL, String) {
  let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let script = directory.appendingPathComponent("fake-vendor")
  try ("#!/bin/sh\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
  return (directory, script.path)
}

@Test func subscriptionUsageFakeVendors() async throws {
  for (vendor, response, reads) in [(GatewayVendor.codex, codexUsage, 3), (.claudeCode, claudeUsage, 1)] {
    let body = String(repeating: "read -r line || exit 1\n", count: reads)
      + "printf '%s\\n' '{\"method\":\"noise\"}' '\(response)'\nwhile read -r line; do :; done"
    let (directory, executable) = try fakeUsageScript(body)
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = try await ProductionGatewayExecutor(environment: ["PATH": "/usr/bin:/bin"])
      .subscriptionUsage(.init(vendor: vendor, executable: executable, timeoutSeconds: 10))
    #expect(result.available && result.vendor == vendor)
    #expect(result.windows.count == (vendor == .codex ? 1 : 3))
  }
}

@Test func subscriptionUsageChildExit() async throws {
  let (directory, executable) = try fakeUsageScript("echo nope >&2\nexit 2")
  defer { try? FileManager.default.removeItem(at: directory) }
  do {
    _ = try await ProductionGatewayExecutor().subscriptionUsage(.init(vendor: .codex, executable: executable))
    Issue.record("Expected child exit")
  } catch let error as GatewayRPCError {
    #expect(error.code == -32041 && error.message.contains("exited without answering") && error.message.contains("nope"))
  }
}

@Test func subscriptionUsageCLIParamsAndHelp() throws {
  let command = AppCommand(arguments: [])
  let params = try command.subscriptionUsageParams(["--vendor", "codex", "--executable", "/x"])
  #expect(params.vendor == .codex && params.executable == "/x")
  #expect(throws: AppCommand.Error.missingValue("--vendor")) { try command.subscriptionUsageParams([]) }
  #expect(throws: AppCommand.Error.missingValue("--vendor")) { try command.subscriptionUsageParams(["--vendor", "bogus"]) }
  #expect(try AppCommand(arguments: ["--help"]).run().contains("subscription-usage --vendor <claude-code|codex>"))
}
