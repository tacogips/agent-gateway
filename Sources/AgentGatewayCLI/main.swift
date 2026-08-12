import Foundation
import AgentGatewayAppCore

@main
enum AgentGatewayEntryPoint {
  static func main() async {
    let command = AppCommand(arguments: Array(CommandLine.arguments.dropFirst()))
    do {
      let output = try command.run()
      if !output.isEmpty { print(output) }
      let status = try await command.runStreaming()
      if status != 0 { exit(status) }
    } catch AppCommand.Error.unknownArgument(let argument) {
      FileHandle.standardError.write(Data("Unknown argument: \(argument)\n".utf8))
      exit(2)
    } catch AppCommand.Error.missingValue(let argument) {
      FileHandle.standardError.write(Data("Missing or invalid value: \(argument)\n".utf8))
      exit(2)
    } catch {
      FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
      exit(1)
    }
  }
}
