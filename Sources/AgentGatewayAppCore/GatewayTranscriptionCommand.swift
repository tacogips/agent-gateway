import AgentGateway
import Foundation

enum GatewayTranscriptionOutputFormat: String, Sendable { case text, json }

struct GatewayTranscriptionCommandOptions: Equatable, Sendable {
  var vendor: GatewayVendor
  var model: String
   var file: String
  var mimeType: String?
  var language: String?
  var prompt: String?
  var apiKeyEnvironment: String?
  var baseURL: String?
  var timeoutSeconds: Int = 120
  var output: GatewayTranscriptionOutputFormat = .text
}

struct GatewayTranscriptionCommandOutcome: Equatable, Sendable {
  var status: Int32
  var standardOutput: String
  var standardError: String
}

private struct TranscriptionJSON: Encodable {
  let model: String
  let text: String
  let vendor: String
}

extension AppCommand {
  func transcriptionOptions(_ arguments: [String]) throws -> GatewayTranscriptionCommandOptions {
    let flags = ["--vendor", "--model", "--file", "--mime-type", "--language", "--prompt",
                 "--api-key-environment", "--base-url", "--timeout-seconds", "--output"]
    var values: [String: String] = [:]
    var index = 0
    while index < arguments.count {
      let flag = arguments[index]
      guard flags.contains(flag) else { throw Error.unknownArgument(flag) }
      guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"), !arguments[index + 1].isEmpty else {
        throw Error.missingValue(flag)
      }
      values[flag] = arguments[index + 1]
      index += 2
    }
    guard let value = values["--vendor"], let vendor = GatewayVendor(rawValue: value) else {
      throw Error.missingValue("--vendor")
    }
    guard let model = values["--model"] else { throw Error.missingValue("--model") }
    guard let file = values["--file"] else { throw Error.missingValue("--file") }
    var options = GatewayTranscriptionCommandOptions(vendor: vendor, model: model, file: file)
    options.mimeType = values["--mime-type"]
    options.language = values["--language"]
    options.prompt = values["--prompt"]
    options.apiKeyEnvironment = values["--api-key-environment"]
    options.baseURL = values["--base-url"]
    if let value = values["--timeout-seconds"] {
      guard let timeout = Int(value) else { throw Error.missingValue("--timeout-seconds") }
      options.timeoutSeconds = timeout
    }
    if let value = values["--output"] {
      guard let output = GatewayTranscriptionOutputFormat(rawValue: value) else { throw Error.missingValue("--output") }
      options.output = output
    }
    return options
  }

  func runTranscription(
    _ options: GatewayTranscriptionCommandOptions, transcriber: any GatewayTranscribing
  ) async -> GatewayTranscriptionCommandOutcome {
    do {
      try validateGatewayTranscriptionVendor(options.vendor)
      guard let mime = options.mimeType ?? inferGatewayTranscriptionMIMEType(path: options.file) else {
        let ext = URL(fileURLWithPath: options.file).pathExtension.lowercased()
        throw GatewayRPCError(code: -32602, message: "cannot infer audio MIME type from file extension '\(ext)'; pass --mime-type")
      }
      let params = GatewayTranscriptionParams(
        vendor: options.vendor, model: options.model, audioFile: URL(fileURLWithPath: options.file), mimeType: mime,
        language: options.language, prompt: options.prompt, apiKeyEnvironment: options.apiKeyEnvironment,
        baseURL: options.baseURL, timeoutSeconds: options.timeoutSeconds
      )
      let result = try await transcriber.transcribe(params)
      let output: String
      switch options.output {
      case .text: output = result.text
      case .json:
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        output = String(bytes: try encoder.encode(TranscriptionJSON(
          model: result.model, text: result.text, vendor: result.vendor.rawValue
        )), encoding: .utf8) ?? ""
      }
      return GatewayTranscriptionCommandOutcome(status: 0, standardOutput: output + "\n", standardError: "")
    } catch let error as GatewayRPCError {
      return GatewayTranscriptionCommandOutcome(
        status: 1, standardOutput: "", standardError: "transcription failed (\(error.code)): \(error.message)\n"
      )
    } catch {
      return GatewayTranscriptionCommandOutcome(
        status: 1, standardOutput: "", standardError: "transcription failed: \(error.localizedDescription)\n"
      )
    }
  }
}

func inferGatewayTranscriptionMIMEType(path: String) -> String? {
  switch URL(fileURLWithPath: path).pathExtension.lowercased() {
  case "wav": "audio/wav"
  case "mp3", "mpga", "mpeg": "audio/mpeg"
  case "m4a", "mp4": "audio/mp4"
  case "webm": "audio/webm"
  case "ogg", "oga": "audio/ogg"
  case "flac": "audio/flac"
  case "aac": "audio/aac"
  default: nil
  }
}
