import Foundation

public enum ACPProtocol {
  /// Latest major protocol version implemented by this library (integer per ACP spec).
  public static let versionV1 = 1
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

  private struct Envelope: Decodable {
    var jsonrpc: String?
    var id: ACPRequestID?
    var method: String?
    var error: ACPError?
  }

  /// Parses one JSONL line into a message. `params`/`result` are re-extracted as
  /// raw JSON fragments so callers can decode them into typed structures.
  static func parse(_ line: Data) throws -> ACPIncomingMessage {
    let envelope: Envelope
    do {
      envelope = try decoder.decode(Envelope.self, from: line)
    } catch {
      throw ACPError.parseError()
    }
    guard envelope.jsonrpc == ACPProtocol.jsonrpc else {
      throw ACPError.invalidRequest("missing jsonrpc version")
    }
    let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    func fragment(_ key: String) -> Data? {
      guard let value = object?[key], !(value is NSNull) else { return nil }
      return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }
    if let method = envelope.method {
      let params = fragment("params") ?? Data("{}".utf8)
      if let id = envelope.id {
        return .request(id: id, method: method, params: params)
      }
      return .notification(method: method, params: params)
    }
    guard let id = envelope.id else {
      throw ACPError.invalidRequest("message is neither a request, notification, nor response")
    }
    return .response(id: id, result: fragment("result"), error: envelope.error)
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
