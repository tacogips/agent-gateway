import ACP
import Foundation
import GatewayProcessNative
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

enum GatewayJSONLineExchangeError: Error, Equatable, Sendable {
  case launchFailed(String)
  case exitedWithoutAnswer(stderrTail: String)
  case timedOut(seconds: Double)
}

func exchangeGatewayJSONLines(
  executable: String, arguments: [String], environment: [String: String],
  requests: [Data], timeoutSeconds: Double,
  isResponse: @escaping @Sendable (Data) -> Bool
) async throws -> Data {
  #if os(macOS) || os(Linux)
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.environment = environment
  let input = Pipe()
  let output = Pipe()
  let standardError = Pipe()
  process.standardInput = input
  process.standardOutput = output
  process.standardError = standardError
  let tail = GatewayExchangeStderrTail()
  standardError.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    if data.isEmpty {
      handle.readabilityHandler = nil
      tail.finish()
    } else {
      tail.append(data)
    }
  }
  let transport = ACPFileHandleTransport(input: output.fileHandleForReading, output: input.fileHandleForWriting)
  var launched = false
  do {
    do {
      try process.run()
      launched = true
    } catch {
      throw GatewayJSONLineExchangeError.launchFailed(String(describing: error))
    }
    for request in requests {
      guard gatewayExchangeWrite(request + Data([10]), to: input.fileHandleForWriting.fileDescriptor) else { break }
    }
    let lines = transport.lines
    let response = try await withThrowingTaskGroup(of: Data?.self) { group in
      group.addTask {
        for await line in lines where isResponse(line) { return line }
        return nil
      }
      group.addTask {
        try await Task.sleep(for: .seconds(timeoutSeconds))
        throw GatewayJSONLineExchangeError.timedOut(seconds: timeoutSeconds)
      }
      defer { group.cancelAll() }
      return try await group.next() ?? nil
    }
    guard let response else {
      await gatewayExchangePoll(seconds: 2) { !process.isRunning }
      await gatewayExchangePoll(seconds: 1) { tail.finished }
      throw GatewayJSONLineExchangeError.exitedWithoutAnswer(stderrTail: tail.text)
    }
    await gatewayExchangeCleanup(process, launched: launched, transport: transport, stderr: standardError)
    return response
  } catch {
    await gatewayExchangeCleanup(process, launched: launched, transport: transport, stderr: standardError)
    throw error
  }
  #else
  throw GatewayProcessError.launchFailed(ENOTSUP)
  #endif
}

#if os(macOS) || os(Linux)
private func gatewayExchangeWrite(_ data: Data, to descriptor: Int32) -> Bool {
  data.withUnsafeBytes { bytes in
    guard let base = bytes.baseAddress else { return true }
    var offset = 0
    while offset < bytes.count {
      let count = gwp_write(descriptor, base.advanced(by: offset), bytes.count - offset)
      if count > 0 { offset += count } else if count < 0 && errno == EINTR { continue } else { return false }
    }
    return true
  }
}

private func gatewayExchangePoll(seconds: TimeInterval, until done: () -> Bool) async {
  let deadline = Date().addingTimeInterval(seconds)
  while !done() && Date() < deadline {
    // A detached sleep still observes the grace period when the caller is cancelled.
    await Task.detached { try? await Task.sleep(for: .milliseconds(20)) }.value
  }
}

private func gatewayExchangeCleanup(
  _ process: Process, launched: Bool, transport: ACPFileHandleTransport, stderr: Pipe
) async {
  if launched {
    if process.isRunning { process.terminate() }
    await gatewayExchangePoll(seconds: 2) { !process.isRunning }
    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
  }
  transport.close()
  stderr.fileHandleForReading.readabilityHandler = nil
}

private final class GatewayExchangeStderrTail: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  private var isFinished = false
  func append(_ chunk: Data) {
    lock.withLock {
      data.append(chunk)
      if data.count > 2048 { data = Data(data.suffix(2048)) }
    }
  }
  func finish() { lock.withLock { isFinished = true } }
  var finished: Bool { lock.withLock { isFinished } }
  var text: String {
    lock.withLock { String(bytes: data, encoding: .utf8) ?? String(decoding: data, as: Unicode.UTF8.self) }.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
#endif
