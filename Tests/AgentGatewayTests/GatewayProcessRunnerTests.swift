import Foundation
import Testing
import AgentGateway
import AgentGatewayAppCore

private actor InjectedProcessRunner: GatewayProcessRunning {
  nonisolated let supportedOwnership: Set<GatewayProcessOwnership> = [.foregroundProcessGroup, .allDescendants]
  private(set) var requests: [GatewayProcessRequest] = []

  func run(_ request: GatewayProcessRequest, emit: @escaping @Sendable (GatewayProcessOutput) -> Void) async throws -> GatewayProcessResult {
    requests.append(request)
    let output = Data("{\"type\":\"result\",\"result\":\"injected\"}\n".utf8)
    emit(GatewayProcessOutput(stream: .stdout, data: output))
    return GatewayProcessResult(exitCode: 0, stdout: output, stderr: Data())
  }
}

private func shellRequest(_ script: String, deadline: Date? = Date().addingTimeInterval(5)) -> GatewayProcessRequest {
  GatewayProcessRequest(executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"], deadline: deadline)
}

private func expectStopped(_ identifier: String) async throws {
  #expect(Int32(identifier) != nil)
  let check = try await POSIXGatewayProcessRunner().run(GatewayProcessRequest(
    executable: "/bin/ps", arguments: ["-o", "stat=", "-p", identifier], deadline: Date().addingTimeInterval(5)
  ))
  let state = try #require(String(data: check.stdout, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
  #expect(state.isEmpty || state.hasPrefix("Z"), "A subsequent process started while the previous child was live: \(state)")
}

@Test func gatewayExecutorDelegatesToPublicInjectedRunner() async throws {
  let runner = InjectedProcessRunner()
  let executor = ProductionGatewayExecutor(environment: ["INJECTED": "value"], processRunner: runner, processOwnership: .allDescendants)
  let result = try await executor.execute(GatewayExecuteParams(
    vendor: .claudeCode, model: "test", prompt: "payload", workingDirectory: "/", executable: "deliberately-absent"
  ), emit: { _ in })
  #expect(result.text == "injected")
  let requests = await runner.requests
  #expect(requests.count == 1)
  #expect(requests.first?.stdin == Data("payload".utf8))
  #expect(requests.first?.workingDirectory == "/")
  #expect(requests.first?.environment["INJECTED"] == "value")
  #expect(requests.first?.ownership == .allDescendants)
}

@Test func gatewayProcessReclaimsBackgroundGroupOnNormalExit() async throws {
  let result = try await POSIXGatewayProcessRunner().run(shellRequest("sleep 30 & printf '%s\\n' $!"))
  #expect(result.exitCode == 0)
  #expect(!result.outputTruncated)
  try await expectStopped(#require(String(data: result.stdout, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))
}

@Test func gatewayProcessPreservesCompleteNonzeroOutput() async throws {
  let count = 300_000
  let script = "head -c \(count) /dev/zero; head -c \(count) /dev/zero >&2; printf tail; printf error-tail >&2; exit 17"
  let result = try await POSIXGatewayProcessRunner().run(shellRequest(script))
  #expect(result.exitCode == 17)
  #expect(result.stdout == Data(repeating: 0, count: count) + Data("tail".utf8))
  #expect(result.stderr == Data(repeating: 0, count: count) + Data("error-tail".utf8))
  #expect(!result.outputTruncated)
}

@Test func gatewayProcessReportsBoundedOutputAndCleansUp() async throws {
  var request = shellRequest("printf '%s\\n' $$; while :; do printf 0123456789; printf abcdefghij >&2; done")
  request.outputLimitBytes = 1_024
  let result = try await POSIXGatewayProcessRunner().run(request)
  #expect(result.outputTruncated)
  #expect(result.stdout.count <= 1_024)
  #expect(result.stderr.count <= 1_024)
  let identifier = try #require(String(data: result.stdout, encoding: .utf8)).components(separatedBy: "\n")[0]
  try await expectStopped(identifier)
}

@Test func gatewayProcessCancellationWaitsForCleanupBeforeNextRun() async throws {
  let (stream, continuation) = AsyncStream<Data>.makeStream()
  let task = Task {
    defer { continuation.finish() }
    return try await POSIXGatewayProcessRunner().run(shellRequest("trap '' TERM; sleep 30 & printf '%s\\n' $!; wait")) {
      if $0.stream == .stdout { continuation.yield($0.data) }
    }
  }
  var bytes = Data()
  for await data in stream {
    bytes.append(data)
    if bytes.contains(10) { break }
  }
  continuation.finish()
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  try await expectStopped(#require(String(data: bytes, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))
}

@Test func gatewayProcessDeadlineWaitsForGroupCleanup() async throws {
  let collector = ProcessTestOutput()
  let request = shellRequest("trap '' TERM; sleep 30 & printf '%s\\n' $!; wait", deadline: Date().addingTimeInterval(0.5))
  await #expect(throws: GatewayProcessError.timedOut) {
    try await POSIXGatewayProcessRunner().run(request) { if $0.stream == .stdout { collector.append($0.data) } }
  }
  try await expectStopped(#require(String(data: collector.data, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))
}

@Test func gatewayProcessRejectsStrictOwnershipBeforeSpawn() async {
  let request = GatewayProcessRequest(executable: "/definitely/absent", ownership: .allDescendants)
  await #expect(throws: GatewayProcessError.unsupportedOwnership(.allDescendants)) {
    try await POSIXGatewayProcessRunner().run(request)
  }
  let executor = ProductionGatewayExecutor(processOwnership: .allDescendants)
  await #expect(throws: GatewayProcessError.unsupportedOwnership(.allDescendants)) {
    try await executor.execute(GatewayExecuteParams(vendor: .codex, model: "test", prompt: "test"), emit: { _ in })
  }
}

@Test func gatewayProcessRejectsPreSpawnCancellationAndExpiredDeadline() async {
  let task = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return try await POSIXGatewayProcessRunner().run(GatewayProcessRequest(executable: "/definitely/absent"))
  }
  await #expect(throws: CancellationError.self) { try await task.value }
  await #expect(throws: GatewayProcessError.timedOut) {
    try await POSIXGatewayProcessRunner().run(GatewayProcessRequest(executable: "/definitely/absent", deadline: .distantPast))
  }
}

@Test func gatewayProcessStreamsAndWritesLargeInputWithoutDeadlock() async throws {
  var request = GatewayProcessRequest(executable: "/bin/cat", deadline: Date().addingTimeInterval(5))
  request.stdin = Data(repeating: 65, count: 500_000)
  let collector = ProcessTestOutput()
  let result = try await POSIXGatewayProcessRunner().run(request) { if $0.stream == .stdout { collector.append($0.data) } }
  #expect(result.exitCode == 0)
  #expect(result.stdout == request.stdin)
  #expect(collector.data == request.stdin)
}

private final class ProcessTestOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = Data()
  var data: Data { lock.withLock { bytes } }
  func append(_ data: Data) { lock.withLock { bytes.append(data) } }
}
