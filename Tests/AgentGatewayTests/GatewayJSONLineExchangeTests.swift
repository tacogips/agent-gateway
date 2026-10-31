import Foundation
import Testing
@testable import AgentGatewayAppCore

#if os(macOS) || os(Linux)
private func jsonLineScript(_ body: String) throws -> (URL, String) {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("agent-gateway-jsonline-test-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let script = directory.appendingPathComponent("fake")
  try ("#!/bin/sh\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
  return (directory, script.path)
}

private func jsonLineMatch(_ data: Data) -> Bool {
  guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
  return object["id"] as? Int == 2
}

private func jsonLineRun(_ executable: String, requests: [String], timeout: Double = 10) async throws -> Data {
  try await exchangeGatewayJSONLines(
    executable: executable, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
    requests: requests.map { Data($0.utf8) }, timeoutSeconds: timeout, isResponse: jsonLineMatch
  )
}

@Test func jsonLineExchangeAnswersAfterNoise() async throws {
  let (directory, executable) = try jsonLineScript("""
  read -r a
  read -r b
  read -r c
  printf '%s\n' 'not json' '{"method":"note"}' '{"id":1,"result":{}}' '{"id":2,"result":{"ok":true}}'
  while IFS= read -r line; do :; done
  """)
  defer { try? FileManager.default.removeItem(at: directory) }
  let result = try await jsonLineRun(executable, requests: ["one", "two", "three"])
  let object = try #require(JSONSerialization.jsonObject(with: result) as? [String: Any])
  let payload = try #require(object["result"] as? [String: Bool])
  #expect(payload["ok"] == true)
}

@Test func jsonLineExchangePreservesRequestOrder() async throws {
  let (directory, executable) = try jsonLineScript("""
  read -r first
  read -r second
  printf '{"id":2,"echo":"%s|%s"}\n' "$first" "$second"
  """)
  defer { try? FileManager.default.removeItem(at: directory) }
  let result = try await jsonLineRun(executable, requests: ["first", "second"])
  let object = try #require(JSONSerialization.jsonObject(with: result) as? [String: Any])
  #expect(object["echo"] as? String == "first|second")
}

@Test func jsonLineExchangeReportsStderrOnExit() async throws {
  let (directory, executable) = try jsonLineScript("read -r line; echo 'fake failure detail' >&2; exit 3")
  defer { try? FileManager.default.removeItem(at: directory) }
  do {
    _ = try await jsonLineRun(executable, requests: ["request"])
    Issue.record("Expected an exit error")
  } catch let error as GatewayJSONLineExchangeError {
    guard case .exitedWithoutAnswer(let tail) = error else {
      Issue.record("Unexpected error: \(error)")
      return
    }
    #expect(tail.contains("fake failure detail"))
  }
}

@Test func jsonLineExchangeTimesOut() async throws {
  let (directory, executable) = try jsonLineScript("while IFS= read -r line; do :; done")
  defer { try? FileManager.default.removeItem(at: directory) }
  let start = Date()
  do {
    _ = try await jsonLineRun(executable, requests: ["request"], timeout: 0.5)
    Issue.record("Expected a timeout")
  } catch let error as GatewayJSONLineExchangeError {
    #expect(error == .timedOut(seconds: 0.5))
  }
  #expect(Date().timeIntervalSince(start) < 5)
}

@Test func jsonLineExchangeReportsLaunchFailure() async throws {
  let (directory, _) = try jsonLineScript("exit 0")
  defer { try? FileManager.default.removeItem(at: directory) }
  do {
    _ = try await jsonLineRun(directory.appendingPathComponent("does-not-exist").path, requests: [])
    Issue.record("Expected a launch error")
  } catch let error as GatewayJSONLineExchangeError {
    guard case .launchFailed = error else {
      Issue.record("Unexpected error: \(error)")
      return
    }
  }
}
#endif
