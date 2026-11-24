import Foundation

public enum ACPProtocol {
  /// ACP major protocol version 1 (integer per ACP spec).
  public static let versionV1 = 1
  /// ACP major protocol version 2 (Preview): redesigned prompt lifecycle,
  /// upsert-style updates, reorganized capabilities.
  public static let versionV2 = 2
  /// Every major protocol version this library can speak, ascending.
  public static let supportedVersions = [versionV1, versionV2]
  /// Inclusive range of a well-formed `protocolVersion` value.
  public static let versionRange = 0...65535
  public static let jsonrpc = "2.0"
}

/// JSON-RPC request identifier: a number or a string.
public enum ACPRequestID: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
  case number(Int)
  case string(String)

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Int.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "request id must be a number or string")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    }
  }

  public var description: String {
    switch self {
    case .number(let value): String(value)
    case .string(let value): value
    }
  }
}

/// JSON-RPC error object. Also thrown by handlers to produce protocol errors.
public struct ACPError: Codable, Equatable, Error, Sendable {
  public var code: Int
  public var message: String
  public var data: ACPJSONValue?

  public init(code: Int, message: String, data: ACPJSONValue? = nil) {
    self.code = code
    self.message = message
    self.data = data
  }

  public static func parseError(_ message: String = "parse error") -> ACPError {
    ACPError(code: -32700, message: message)
  }
  public static func invalidRequest(_ message: String = "invalid request") -> ACPError {
    ACPError(code: -32600, message: message)
  }
  public static func methodNotFound(_ method: String) -> ACPError {
    ACPError(code: -32601, message: "method not found: \(method)")
  }
  public static func invalidParams(_ message: String = "invalid params") -> ACPError {
    ACPError(code: -32602, message: message)
  }
  public static func internalError(_ message: String = "internal error") -> ACPError {
    ACPError(code: -32603, message: message)
  }
  /// ACP-defined: authentication is required before the request can proceed.
  public static func authRequired(_ message: String = "authentication required") -> ACPError {
    ACPError(code: -32000, message: message)
  }
  /// ACP-defined: the request was cancelled (`$/cancel_request`,
  /// `session/cancel`, or `session/close` before it took effect).
  public static func requestCancelled(_ message: String = "request cancelled") -> ACPError {
    ACPError(code: ACPErrorCode.requestCancelled, message: message)
  }
  /// ACP-defined: a referenced resource does not exist.
  public static func resourceNotFound(_ message: String = "resource not found", data: ACPJSONValue? = nil) -> ACPError {
    ACPError(code: ACPErrorCode.resourceNotFound, message: message, data: data)
  }
  /// ACP-defined: a session-scoped request named a session that does not
  /// exist or is not active on the connection. Carries `data.sessionId`.
  public static func sessionNotFound(_ sessionId: String) -> ACPError {
    ACPError(
      code: ACPErrorCode.resourceNotFound,
      message: "session not found: \(sessionId)",
      data: .object(["sessionId": .string(sessionId)])
    )
  }
  /// ACP-defined: no supported protocol version is at or below the requested
  /// one. Carries `data.requested` and `data.supported`.
  public static func unsupportedProtocolVersion(requested: Int, supported: [Int]) -> ACPError {
    ACPError(
      code: ACPErrorCode.unsupportedProtocolVersion,
      message: "Unsupported protocol version",
      data: .object([
        "requested": .integer(requested),
        "supported": .array(supported.map { .integer($0) })
      ])
    )
  }
}

/// Error codes ACP uses on top of the JSON-RPC reserved range.
public enum ACPErrorCode {
  public static let parseError = -32700
  public static let invalidRequest = -32600
  public static let methodNotFound = -32601
  public static let invalidParams = -32602
  public static let internalError = -32603
  public static let authRequired = -32000
  public static let resourceNotFound = -32002
  public static let unsupportedProtocolVersion = -32022
  public static let requestCancelled = -32800
}

/// An envelope that is invalid but whose request id could still be read, so
/// the error response can name it.
struct ACPInvalidEnvelope: Error {
  var id: ACPRequestID?
  var error: ACPError
}

/// A decoded incoming JSON-RPC message.
public enum ACPIncomingMessage: Sendable {
  case request(id: ACPRequestID, method: String, params: Data)
  case notification(method: String, params: Data)
  case response(id: ACPRequestID, result: Data?, error: ACPError?)
}

enum ACPWireCoding {
  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  static let decoder = JSONDecoder()

  /// Parses one JSONL line into a message. `params`/`result` are re-extracted as
  /// raw JSON fragments so callers can decode them into typed structures.
  ///
  /// Envelope rules beyond base JSON-RPC, per ACP: request ids are a string
  /// or an integer and never `null` (a message with a `method` and
  /// `id: null` is rejected rather than treated as a notification), and
  /// batches (JSON arrays) are not used.
  static func parse(_ line: Data) throws -> ACPIncomingMessage {
    let value: Any
    do {
      value = try JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])
    } catch {
      throw ACPError.parseError()
    }
    if value is [Any] {
      throw ACPError.invalidRequest("JSON-RPC batches are not supported")
    }
    guard let object = value as? [String: Any] else {
      throw ACPError.invalidRequest("message must be a JSON object")
    }
    guard object["jsonrpc"] as? String == ACPProtocol.jsonrpc else {
      throw ACPError.invalidRequest("missing jsonrpc version")
    }
    func fragment(_ key: String) -> Data? {
      guard let value = object[key], !(value is NSNull) else { return nil }
      return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }
    // The id is probed with JSONDecoder, which tells integers from
    // booleans and fractions the same way on every platform.
    let probe = try? decoder.decode(RequestIDProbe.self, from: line)
    let hasID = object["id"] != nil
    let id = probe?.id
    if let rawMethod = object["method"] {
      guard let method = rawMethod as? String else {
        throw ACPError.invalidRequest("method must be a string")
      }
      if let rawParams = object["params"], !(rawParams is NSNull),
         !(rawParams is [String: Any]), !(rawParams is [Any]) {
        throw ACPInvalidEnvelope(id: id, error: .invalidRequest("params must be an object or array"))
      }
      let params = fragment("params") ?? Data("{}".utf8)
      guard hasID else {
        return .notification(method: method, params: params)
      }
      guard let id else {
        throw ACPError.invalidRequest("request id must be a string or an integer")
      }
      return .request(id: id, method: method, params: params)
    }
    guard let id else {
      throw ACPError.invalidRequest("message is neither a request, notification, nor response")
    }
    var error: ACPError?
    if let rawError = fragment("error") {
      error = (try? decoder.decode(ACPError.self, from: rawError))
        ?? ACPError.internalError("peer returned a malformed error object")
    }
    return .response(id: id, result: fragment("result"), error: error)
  }

  /// Reads a JSON-RPC id: a string or an integer. Booleans, fractional
  /// numbers, `null`, and structured values are not ids and read as nil.
  private struct RequestIDProbe: Decodable {
    var id: ACPRequestID?

    private enum CodingKeys: String, CodingKey {
      case id
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try? container.decode(ACPRequestID.self, forKey: .id)
    }
  }

  static func encodeRequest<Params: Encodable>(id: ACPRequestID, method: String, params: Params) throws -> Data {
    try encodeObject([
      "jsonrpc": AnyEncodable(ACPProtocol.jsonrpc),
      "id": AnyEncodable(id),
      "method": AnyEncodable(method),
      "params": AnyEncodable(params)
    ])
  }

  static func encodeNotification<Params: Encodable>(method: String, params: Params) throws -> Data {
    try encodeObject([
      "jsonrpc": AnyEncodable(ACPProtocol.jsonrpc),
      "method": AnyEncodable(method),
      "params": AnyEncodable(params)
    ])
  }

  static func encodeResponse<Result: Encodable>(id: ACPRequestID, result: Result) throws -> Data {
    try encodeObject([
      "jsonrpc": AnyEncodable(ACPProtocol.jsonrpc),
      "id": AnyEncodable(id),
      "result": AnyEncodable(result)
    ])
  }

  static func encodeError(id: ACPRequestID?, error: ACPError) throws -> Data {
    var fields = [
      "jsonrpc": AnyEncodable(ACPProtocol.jsonrpc),
      "error": AnyEncodable(error)
    ]
    fields["id"] = id.map { AnyEncodable($0) } ?? AnyEncodable(NullValue())
    return try encodeObject(fields)
  }

  private static func encodeObject(_ fields: [String: AnyEncodable]) throws -> Data {
    try encoder.encode(fields)
  }
}

private struct AnyEncodable: Encodable {
  private let encodeClosure: (any Encoder) throws -> Void

  init<T: Encodable>(_ value: T) {
    encodeClosure = { try value.encode(to: $0) }
  }

  func encode(to encoder: any Encoder) throws {
    try encodeClosure(encoder)
  }
}

private struct NullValue: Encodable {
  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encodeNil()
  }
}
