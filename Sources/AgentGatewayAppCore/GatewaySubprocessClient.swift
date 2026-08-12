import AgentGateway
import Foundation

struct GatewaySubprocessClient {
  func run<Request: Encodable>(request: Request) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["server"]
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error
    try process.run()
    try? output.fileHandleForWriting.close()
    try? error.fileHandleForWriting.close()

    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      forward(input: output.fileHandleForReading, output: .standardOutput)
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      forward(input: error.fileHandleForReading, output: .standardError)
      group.leave()
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    input.fileHandleForWriting.write(try encoder.encode(request) + Data([10]))
    try? input.fileHandleForWriting.close()
    process.waitUntilExit()
    group.wait()
    return process.terminationStatus
  }
}

private func forward(input: FileHandle, output: FileHandle) {
  while true {
    let data = input.availableData
    guard !data.isEmpty else { return }
    output.write(data)
  }
}
