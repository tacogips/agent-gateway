import AgentGateway
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GatewayTranscriptionParams: Sendable, Equatable {
  public var protocolVersion: String
  public var vendor: GatewayVendor
  public var model: String
  public var audioFile: URL
  public var mimeType: String
  public var language: String?
  public var prompt: String?
  public var apiKeyEnvironment: String?
  public var baseURL: String?
  public var timeoutSeconds: Int

  public init(
    protocolVersion: String = GatewayProtocolVersion.current,
    vendor: GatewayVendor,
    model: String,
    audioFile: URL,
    mimeType: String,
    language: String? = nil,
    prompt: String? = nil,
    apiKeyEnvironment: String? = nil,
    baseURL: String? = nil,
    timeoutSeconds: Int = 120
  ) {
    self.protocolVersion = protocolVersion
    self.vendor = vendor
    self.model = model
    self.audioFile = audioFile
    self.mimeType = mimeType
    self.language = language
    self.prompt = prompt
    self.apiKeyEnvironment = apiKeyEnvironment
    self.baseURL = baseURL
    self.timeoutSeconds = timeoutSeconds
  }
}

public struct GatewayTranscriptionResult: Sendable, Equatable {
  public var vendor: GatewayVendor
  public var model: String
  public var text: String

  public init(vendor: GatewayVendor, model: String, text: String) {
    self.vendor = vendor
    self.model = model
    self.text = text
  }
}

public protocol GatewayTranscribing: Sendable {
  func transcribe(_ params: GatewayTranscriptionParams) async throws -> GatewayTranscriptionResult
}

public let gatewayTranscriptionUnsupportedCode = -32021

/// Curated suggestions only; callers may supply any vendor model ID.
public enum GatewayTranscriptionModels {
  public static let defaults: [GatewayVendor: [String]] = [
    .openAI: ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"],
    .gemini: ["gemini-3.5-flash-lite", "gemini-3.8-flash"],
    .openRouter: ["openai/gpt-4o-audio-preview", "google/gemini-3.5-flash-lite"]
  ]
}

extension ProductionGatewayExecutor: GatewayTranscribing {
  public func transcribe(_ params: GatewayTranscriptionParams) async throws -> GatewayTranscriptionResult {
    try await GatewayTranscriptionPipeline(
      environment: environment, transport: defaultGatewayTranscriptionTransport
    ).transcribe(params)
  }
}

typealias GatewayTranscriptionTransport = @Sendable (URLRequest, Int) async throws -> (Data, URLResponse)

final class GatewayTranscriptionRedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var response: HTTPURLResponse?

  var refusedRedirectResponse: HTTPURLResponse? {
    lock.lock()
    defer { lock.unlock() }
    return response
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    lock.lock()
    self.response = response
    lock.unlock()
    completionHandler(nil)
  }
}

let defaultGatewayTranscriptionTransport: GatewayTranscriptionTransport = { request, timeoutSeconds in
  let configuration = URLSessionConfiguration.ephemeral
  configuration.timeoutIntervalForRequest = TimeInterval(timeoutSeconds)
  configuration.timeoutIntervalForResource = TimeInterval(timeoutSeconds)
  let delegate = GatewayTranscriptionRedirectRefusal()
  let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
  defer { session.invalidateAndCancel() }
  do {
    return try await session.data(for: request)
  } catch {
    if let response = delegate.refusedRedirectResponse { return (Data(), response) }
    throw error
  }
}

struct GatewayTranscriptionPipeline: GatewayTranscribing {
  let environment: [String: String]
  let transport: GatewayTranscriptionTransport

  func transcribe(_ params: GatewayTranscriptionParams) async throws -> GatewayTranscriptionResult {
    // Reject unsupported vendors and missing credentials before any file or network I/O.
    let apiKey = try transcriptionAPIKey(params, environment: environment)
    try Task.checkCancellation()
    let audio = try loadGatewayTranscriptionAudio(params.audioFile)
    try Task.checkCancellation()
    let request = try makeTranscriptionRequest(params, audioData: audio, environment: environment)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await transport(request, params.timeoutSeconds)
    } catch {
      if error is CancellationError || Task.isCancelled { throw CancellationError() }
      throw GatewayTranscriptionFailure.transportFailure(vendor: params.vendor, error: error, secret: apiKey)
    }
    try Task.checkCancellation()
    return GatewayTranscriptionResult(
      vendor: params.vendor,
      model: params.model,
      text: try parseTranscriptionResponse(data, response: response, vendor: params.vendor, secret: apiKey)
    )
  }
}

let gatewayTranscriptionMaxBytes = 25_000_000

func loadGatewayTranscriptionAudio(_ url: URL) throws -> Data {
  guard url.isFileURL else {
    throw GatewayRPCError(code: -32602, message: "audio input must be a local file")
  }
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  guard attributes[.type] as? FileAttributeType == .typeRegular else {
    throw GatewayRPCError(code: -32602, message: "audio input must be a regular file")
  }
  try validateTranscriptionSize((attributes[.size] as? NSNumber)?.intValue ?? 0)
  let audio = try Data(contentsOf: url, options: [.mappedIfSafe])
  try validateTranscriptionSize(audio.count)
  return audio
}

func validateTranscriptionSize(_ count: Int) throws {
  guard count <= gatewayTranscriptionMaxBytes else {
    throw GatewayRPCError(code: -32602, message: "audio input exceeds the 25 MB (25,000,000 bytes) size limit")
  }
}

func validateGatewayTranscriptionVendor(_ vendor: GatewayVendor) throws {
  guard [.openAI, .gemini, .openRouter].contains(vendor) else {
    throw GatewayRPCError(
      code: gatewayTranscriptionUnsupportedCode,
      message: "\(vendor.rawValue) does not support audio transcription"
    )
  }
}

func transcriptionAPIKey(_ params: GatewayTranscriptionParams, environment: [String: String]) throws -> String {
  try validateGatewayTranscriptionVendor(params.vendor)
  guard params.protocolVersion == GatewayProtocolVersion.current else {
    throw GatewayRPCError(code: -32602, message: "unsupported protocol version '\(params.protocolVersion)'")
  }
  guard params.timeoutSeconds > 0 else {
    throw GatewayRPCError(code: -32602, message: "timeoutSeconds must be positive")
  }
  let keyName = params.apiKeyEnvironment ?? defaultAPIKeyEnvironment(for: params.vendor)
  guard let key = environment[keyName], !key.isEmpty else {
    throw GatewayRPCError(code: -32011, message: "missing credential environment '\(keyName)'")
  }
  return key
}
