import Foundation
import GatewayProcessNative
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owns a foreground process group. Daemonizing or moving to another group is
/// outside this capability; use a stronger injected owner for such commands.
public struct POSIXGatewayProcessRunner: GatewayProcessRunning {
  public let supportedOwnership: Set<GatewayProcessOwnership> = [.foregroundProcessGroup]

  public init() {}

  public func run(
    _ request: GatewayProcessRequest,
    emit: @escaping @Sendable (GatewayProcessOutput) -> Void = { _ in }
  ) async throws -> GatewayProcessResult {
    guard supportedOwnership.contains(request.ownership) else {
      throw GatewayProcessError.unsupportedOwnership(request.ownership)
    }
    try validate(request)
    let cancellation = ProcessCancellation()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(with: Result {
            try ProcessSession(request: request, cancellation: cancellation, emit: emit).run()
          })
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  private func validate(_ request: GatewayProcessRequest) throws {
    let strings = [request.executable] + request.arguments + request.environment.flatMap { [$0.key, $0.value] }
      + [request.workingDirectory].compactMap { $0 }
    guard request.executable.hasPrefix("/"), request.outputLimitBytes >= 0,
          !strings.contains(where: { $0.utf8.contains(0) }),
          !request.environment.keys.contains(where: { $0.isEmpty || $0.contains("=") }) else {
      throw GatewayProcessError.invalidRequest
    }
  }
}

private final class ProcessCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  var isCancelled: Bool { lock.withLock { cancelled } }
  func cancel() { lock.withLock { cancelled = true } }

  func spawn(_ operation: () throws -> gwp_process) throws -> gwp_process {
    try lock.withLock {
      if cancelled { throw CancellationError() }
      return try operation()
    }
  }
}

/// All descriptor, signal and wait operations live on one worker. Cancellation
/// only sets a flag, so no delayed callback can target a reused PID or PGID.
private final class ProcessSession {
  let request: GatewayProcessRequest
  let cancellation: ProcessCancellation
  let emit: @Sendable (GatewayProcessOutput) -> Void
  var process = gwp_process(pid: 0, input: -1, output: -1, error: -1)
  var stdout = Data()
  var stderr = Data()
  var truncated = false
  var inputOffset = 0

  init(request: GatewayProcessRequest, cancellation: ProcessCancellation, emit: @escaping @Sendable (GatewayProcessOutput) -> Void) {
    self.request = request
    self.cancellation = cancellation
    self.emit = emit
  }

  func run() throws -> GatewayProcessResult {
    process = try cancellation.spawn {
      if let deadline = request.deadline, deadline <= Date() { throw GatewayProcessError.timedOut }
      return try spawn()
    }
    defer {
      for descriptor in [process.input, process.output, process.error] where descriptor >= 0 { close(descriptor) }
    }
    var failure: (any Error)?
    do {
      for descriptor in [process.input, process.output, process.error] {
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw GatewayProcessError.ioFailed(errno) }
      }
      while true {
        try transfer()
        if cancellation.isCancelled { failure = CancellationError(); break }
        if let deadline = request.deadline, deadline <= Date() { failure = GatewayProcessError.timedOut; break }
        let exited = gwp_observe_exit(process.pid)
        guard exited >= 0 else { throw GatewayProcessError.ownershipLost(-exited) }
        if exited == 1 || truncated { break }
        pause()
      }
    } catch { failure = error }

    // Keep the leader unreaped until every group member is dead and every
    // buffered output byte is consumed. Normal exit also enters this barrier.
    let signalError = gwp_signal_owned_group(process.pid, SIGKILL)
    guard signalError == 0 else { throw GatewayProcessError.ownershipLost(signalError) }
    while true {
      do { try transfer() } catch { if failure == nil { failure = error } }
      let quiet = gwp_group_quiescent(process.pid)
      guard quiet >= 0 else { throw GatewayProcessError.cleanupFailed(-quiet) }
      if quiet == 1 { break }
      pause()
    }
    // EOF follows the final write once the owned group is quiescent. An escaped
    // process holding a pipe violates foregroundProcessGroup's contract.
    do {
      while process.output >= 0 || process.error >= 0 {
        try transfer()
        if process.output >= 0 || process.error >= 0 { pause() }
      }
    } catch { if failure == nil { failure = error } }
    var status: Int32 = 0
    let reapError = gwp_reap(process.pid, &status)
    guard reapError == 0 else { throw GatewayProcessError.ownershipLost(reapError) }
    if cancellation.isCancelled { throw CancellationError() }
    if let failure { throw failure }
    return GatewayProcessResult(exitCode: gwp_exit_code(status), stdout: stdout, stderr: stderr, outputTruncated: truncated)
  }

  private func spawn() throws -> gwp_process {
    let arguments = ([request.executable] + request.arguments).map { strdup($0) }
    let environment = request.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
    defer { (arguments + environment).forEach { free($0) } }
    guard (arguments + environment).allSatisfy({ $0 != nil }) else { throw GatewayProcessError.launchFailed(ENOMEM) }
    var result = gwp_process()
    let code = (arguments + [nil]).withUnsafeBufferPointer { argv in
      (environment + [nil]).withUnsafeBufferPointer { envp in
        request.executable.withCString { executable in
          if let directory = request.workingDirectory {
            return directory.withCString { gwp_spawn(executable, argv.baseAddress, envp.baseAddress, $0, &result) }
          }
          return gwp_spawn(executable, argv.baseAddress, envp.baseAddress, nil, &result)
        }
      }
    }
    guard code == 0 else { throw GatewayProcessError.launchFailed(code) }
    return result
  }

  private func transfer() throws {
    try readOutput(descriptor: &process.output, stream: .stdout)
    try readOutput(descriptor: &process.error, stream: .stderr)
    guard process.input >= 0 else { return }
    if inputOffset < request.stdin.count {
      let count = request.stdin.withUnsafeBytes { bytes in
        gwp_write(process.input, bytes.baseAddress?.advanced(by: inputOffset), min(16_384, bytes.count - inputOffset))
      }
      if count > 0 { inputOffset += count }
      if count < 0 && errno == EPIPE { close(process.input); process.input = -1; return }
      if count < 0 && errno != EAGAIN && errno != EINTR { throw GatewayProcessError.ioFailed(errno) }
    }
    if inputOffset == request.stdin.count { close(process.input); process.input = -1 }
  }

  private func readOutput(descriptor: inout Int32, stream: GatewayProcessStream) throws {
    guard descriptor >= 0 else { return }
    var buffer = [UInt8](repeating: 0, count: 16_384)
    // Bound each pass so a constantly writing child cannot starve cancellation.
    for _ in 0..<16 {
      let count = read(descriptor, &buffer, buffer.count)
      if count == 0 { close(descriptor); descriptor = -1; return }
      if count < 0 {
        if errno == EAGAIN || errno == EINTR { return }
        throw GatewayProcessError.ioFailed(errno)
      }
      let used = stream == .stdout ? stdout.count : stderr.count
      let accepted = min(count, request.outputLimitBytes - used)
      if accepted < count { truncated = true }
      if accepted > 0 {
        let data = Data(buffer.prefix(accepted))
        if stream == .stdout { stdout.append(data) } else { stderr.append(data) }
        emit(GatewayProcessOutput(stream: stream, data: data))
      }
    }
  }

  private func pause() {
    var timeout = timespec(tv_sec: 0, tv_nsec: 2_000_000)
    _ = nanosleep(&timeout, nil)
  }
}
