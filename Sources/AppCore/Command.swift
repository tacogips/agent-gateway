import Foundation

public struct AppCommand: Sendable {
  public enum Error: Swift.Error, Equatable, Sendable {
    case unknownArgument(String)
  }

  public let arguments: [String]

  public init(arguments: [String]) {
    self.arguments = arguments
  }

  public func run() throws -> String {
    if arguments.contains("--version") {
      return Version.current
    }

    if arguments.contains("--help") || arguments.contains("-h") {
      return usage
    }

    if let firstUnknown = arguments.first(where: { $0.hasPrefix("-") }) {
      throw Error.unknownArgument(firstUnknown)
    }

    return "Hello from agent-gateway"
  }

  public var usage: String {
    """
    Usage: agent-gateway [--help] [--version]
    """
  }
}
