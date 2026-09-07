import Foundation

public enum GatewayProcessOwnership: String, Codable, Hashable, Sendable {
  /// Owns a dedicated process group. Commands must not escape it using
  /// setsid, setpgid, daemonization, or an external service manager.
  case foregroundProcessGroup
  /// Requires an injected OS/container owner that also reclaims escaped groups.
  case allDescendants
}

public struct GatewayProcessRequest: Sendable {
  public var executable: String
  public var arguments: [String]
  public var environment: [String: String]
  public var workingDirectory: String?
  public var stdin: Data
  public var ownership: GatewayProcessOwnership
  public var deadline: Date?
  /// Maximum retained and emitted bytes per stream. Additional bytes trigger
  /// cleanup and outputTruncated; a nonzero exit still returns captured output.
  public var outputLimitBytes: Int

  public init(
    executable: String, arguments: [String] = [], environment: [String: String] = [:],
    workingDirectory: String? = nil, stdin: Data = Data(),
    ownership: GatewayProcessOwnership = .foregroundProcessGroup,
    deadline: Date? = nil, outputLimitBytes: Int = 16 * 1024 * 1024
  ) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
    self.stdin = stdin
    self.ownership = ownership
    self.deadline = deadline
    self.outputLimitBytes = outputLimitBytes
  }
}

public enum GatewayProcessStream: String, Sendable { case stdout, stderr }

public struct GatewayProcessOutput: Sendable {
  public var stream: GatewayProcessStream
  public var data: Data
  public init(stream: GatewayProcessStream, data: Data) { self.stream = stream; self.data = data }
}

public struct GatewayProcessResult: Sendable {
  public var exitCode: Int32
  public var stdout: Data
  public var stderr: Data
  /// A limit violation terminates and reclaims the group before returning.
  /// Callers must not interpret a truncated capture as successful execution.
  public var outputTruncated: Bool

  public init(exitCode: Int32, stdout: Data, stderr: Data, outputTruncated: Bool = false) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
    self.outputTruncated = outputTruncated
  }
}

public enum GatewayProcessError: Error, Equatable, Sendable {
  case unsupportedOwnership(GatewayProcessOwnership)
  case invalidRequest
  case launchFailed(Int32)
  case ownershipLost(Int32)
  case timedOut
  case ioFailed(Int32)
  case cleanupFailed(Int32)
}

/// Implementations must not return until their declared ownership scope is
/// reclaimed. Task cancellation requests cleanup and waits for that barrier.
/// Emit callbacks are synchronous, ordered per stream, and must return promptly.
/// Hosts must not reap runner-owned children or change SIGCHLD disposition while
/// runs are active. Unsupported ownership must fail before launching anything.
public protocol GatewayProcessRunning: Sendable {
  var supportedOwnership: Set<GatewayProcessOwnership> { get }
  func run(_ request: GatewayProcessRequest, emit: @escaping @Sendable (GatewayProcessOutput) -> Void) async throws -> GatewayProcessResult
}
