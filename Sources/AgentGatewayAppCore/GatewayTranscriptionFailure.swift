import AgentGateway
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GatewayTranscriptionFailure: Error, Sendable, Equatable, LocalizedError {
  public enum Classification: String, Sendable, Equatable {
    case quotaExhausted, rateLimited, serverError, authFailed, invalidRequest, transport, unknown
  }

  public var vendor: GatewayVendor
  public var classification: Classification
  public var httpStatus: Int?
  public var retryAfterSeconds: Int?
  public var vendorErrorType: String?
  public var vendorErrorCode: String?
  public var vendorMessage: String?
  public var rawBody: String?
  public var message: String

  public init(
    vendor: GatewayVendor, classification: Classification, httpStatus: Int? = nil,
    retryAfterSeconds: Int? = nil, vendorErrorType: String? = nil, vendorErrorCode: String? = nil,
    vendorMessage: String? = nil, rawBody: String? = nil, message: String
  ) {
    self.vendor = vendor
    self.classification = classification
    self.httpStatus = httpStatus
    self.retryAfterSeconds = retryAfterSeconds
    self.vendorErrorType = vendorErrorType
    self.vendorErrorCode = vendorErrorCode
    self.vendorMessage = vendorMessage
    self.rawBody = rawBody
    self.message = message
  }

  public var rpcError: GatewayRPCError { GatewayRPCError(code: -32010, message: message) }
  public var errorDescription: String? { message }
}

let gatewayTranscriptionRawBodyLimit = 16_384
let gatewayTranscriptionMessageBodyLimit = 500
let gatewayTranscriptionRedactionMarker = "[REDACTED]"

func gatewayRedacted(_ text: String, secret: String) -> String {
  secret.isEmpty ? text : text.replacingOccurrences(of: secret, with: gatewayTranscriptionRedactionMarker)
}

func gatewayRedactedText(_ data: Data, secret: String) -> String {
  gatewayRedacted(String(decoding: data, as: Unicode.UTF8.self), secret: secret)
}

func gatewayUTF8Prefix(_ text: String, maxBytes: Int) -> String {
  var result = ""
  var count = 0
  for character in text {
    let size = character.utf8.count
    guard size <= maxBytes - count else { break }
    result.append(character)
    count += size
  }
  return result
}

func parseGatewayRetryAfter(_ value: String?, now: Date) -> Int? {
  guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
  if value.utf8.allSatisfy({ (48...57).contains($0) }) { return Int(value) }
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(identifier: "GMT")
  formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
  guard let date = formatter.date(from: value) else { return nil }
  return max(0, Int(ceil(date.timeIntervalSince(now))))
}

struct GatewayVendorErrorFields: Equatable {
  var type: String?
  var code: String?
  var message: String?
}

func parseGatewayVendorErrorFields(_ data: Data) -> GatewayVendorErrorFields {
  guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
    return GatewayVendorErrorFields(type: nil, code: nil, message: nil)
  }
  if let message = object["error"] as? String { return GatewayVendorErrorFields(type: nil, code: nil, message: message) }
  guard let error = object["error"] as? [String: Any] else {
    return GatewayVendorErrorFields(type: nil, code: nil, message: nil)
  }
  let code = (error["code"] as? String) ?? (error["code"] as? Int).map(String.init)
  return GatewayVendorErrorFields(
    type: error["type"] as? String ?? error["status"] as? String, code: code, message: error["message"] as? String
  )
}

func classifyGatewayTranscriptionFailure(
  httpStatus: Int?, vendorErrorType: String?, vendorErrorCode: String?
) -> GatewayTranscriptionFailure.Classification {
  let values = [vendorErrorType, vendorErrorCode]
  if values.contains(where: { $0 == "insufficient_quota" || $0 == "credit_balance_exhausted" }) {
    return .quotaExhausted
  }
  if values.contains(where: { $0 == "rate_limit_exceeded" }) || vendorErrorType == "RESOURCE_EXHAUSTED" {
    return .rateLimited
  }
  guard let httpStatus else { return .unknown }
  switch httpStatus {
  case 402: return .quotaExhausted
  case 429: return .rateLimited
  case 401, 403: return .authFailed
  case 400...499: return .invalidRequest
  case 500...599: return .serverError
  default: return .unknown
  }
}

extension GatewayTranscriptionFailure {
  static func httpFailure(
    vendor: GatewayVendor, data: Data, response: HTTPURLResponse, secret: String, now: Date
  ) -> Self {
    let redacted = gatewayRedactedText(data, secret: secret)
    let fields = parseGatewayVendorErrorFields(data)
    let type = fields.type.map { gatewayRedacted($0, secret: secret) }
    let code = fields.code.map { gatewayRedacted($0, secret: secret) }
    return Self(
      vendor: vendor,
      classification: classifyGatewayTranscriptionFailure(
        httpStatus: response.statusCode, vendorErrorType: type, vendorErrorCode: code
      ),
      httpStatus: response.statusCode,
      retryAfterSeconds: parseGatewayRetryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now),
      vendorErrorType: type, vendorErrorCode: code,
      vendorMessage: fields.message.map { gatewayRedacted($0, secret: secret) },
      rawBody: data.isEmpty ? nil : gatewayUTF8Prefix(redacted, maxBytes: gatewayTranscriptionRawBodyLimit),
      message: "vendor HTTP \(response.statusCode): " + gatewayUTF8Prefix(
        redacted, maxBytes: gatewayTranscriptionMessageBodyLimit
      )
    )
  }

  static func responseFailure(
    vendor: GatewayVendor, httpStatus: Int?, data: Data, message: String, secret: String
  ) -> Self {
    let redacted = gatewayRedactedText(data, secret: secret)
    return Self(
      vendor: vendor, classification: .unknown, httpStatus: httpStatus,
      rawBody: data.isEmpty ? nil : gatewayUTF8Prefix(redacted, maxBytes: gatewayTranscriptionRawBodyLimit),
      message: gatewayRedacted(message, secret: secret)
    )
  }

  static func transportFailure(vendor: GatewayVendor, error: any Error, secret: String) -> Self {
    let detail: String
    if let urlError = error as? URLError {
      detail = "URLError(\(urlError.code.rawValue)): \(urlError.localizedDescription)"
    } else {
      detail = String(describing: type(of: error))
    }
    return Self(vendor: vendor, classification: .transport,
                message: gatewayRedacted("vendor request failed: " + detail, secret: secret))
  }
}
