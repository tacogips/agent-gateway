import Foundation

/// Parameters for reading a CLI vendor's subscription usage.
public struct GatewaySubscriptionUsageParams: Codable, Equatable, Sendable {
  public var protocolVersion: String
  public var vendor: GatewayVendor
  public var executable: String?
  public var timeoutSeconds: Double?

  public init(
    protocolVersion: String = GatewayProtocolVersion.current,
    vendor: GatewayVendor,
    executable: String? = nil,
    timeoutSeconds: Double? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.vendor = vendor
    self.executable = executable
    self.timeoutSeconds = timeoutSeconds
  }
}

/// The duration category of a subscription usage window.
public enum GatewaySubscriptionUsageWindowKind: String, Codable, Sendable {
  case fiveHour, weekly, other

  public static func classify(windowMinutes: Int?) -> Self {
    switch windowMinutes {
    case 300: .fiveHour
    case 10080: .weekly
    default: .other
    }
  }
}

/// A rate-limit window, optionally scoped to a model or limit.
public struct GatewaySubscriptionUsageWindow: Codable, Equatable, Sendable {
  public var kind: GatewaySubscriptionUsageWindowKind
  public var scope: String?
  public var windowMinutes: Int?
  public var usedPercent: Double
  public var resetsAt: Date?

  public init(
    kind: GatewaySubscriptionUsageWindowKind,
    scope: String? = nil,
    windowMinutes: Int?,
    usedPercent: Double,
    resetsAt: Date?
  ) {
    self.kind = kind
    self.scope = scope
    self.windowMinutes = windowMinutes
    self.usedPercent = usedPercent
    self.resetsAt = resetsAt
  }

  private enum CodingKeys: String, CodingKey {
    case kind, scope, windowMinutes, usedPercent, resetsAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(GatewaySubscriptionUsageWindowKind.self, forKey: .kind)
    scope = try container.decodeIfPresent(String.self, forKey: .scope)
    windowMinutes = try container.decodeIfPresent(Int.self, forKey: .windowMinutes)
    usedPercent = try container.decode(Double.self, forKey: .usedPercent)
    if let value = try container.decodeIfPresent(String.self, forKey: .resetsAt) {
      guard let date = parseGatewayISO8601Date(value) else {
        throw DecodingError.dataCorruptedError(
          forKey: .resetsAt, in: container, debugDescription: "Invalid ISO 8601 date"
        )
      }
      resetsAt = date
    } else {
      resetsAt = nil
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try container.encodeIfPresent(scope, forKey: .scope)
    try container.encodeIfPresent(windowMinutes, forKey: .windowMinutes)
    try container.encode(usedPercent, forKey: .usedPercent)
    if let resetsAt {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      try container.encode(formatter.string(from: resetsAt), forKey: .resetsAt)
    }
  }
}

/// Subscription usage reported by a vendor CLI.
public struct GatewaySubscriptionUsageResult: Codable, Equatable, Sendable {
  public var protocolVersion: String
  public var vendor: GatewayVendor
  public var planType: String?
  public var available: Bool
  public var windows: [GatewaySubscriptionUsageWindow]

  public init(
    protocolVersion: String = GatewayProtocolVersion.current,
    vendor: GatewayVendor,
    planType: String?,
    available: Bool,
    windows: [GatewaySubscriptionUsageWindow]
  ) {
    self.protocolVersion = protocolVersion
    self.vendor = vendor
    self.planType = planType
    self.available = available
    self.windows = windows
  }
}

package func parseGatewayISO8601Date(_ value: String) -> Date? {
  var normalized = value
  var hasFraction = false
  if let dot = normalized.firstIndex(of: ".") {
    let start = normalized.index(after: dot)
    let end = normalized[start...].firstIndex { !$0.isASCII || !$0.isNumber } ?? normalized.endIndex
    if start < end {
      hasFraction = true
      let limit = normalized.index(start, offsetBy: 3, limitedBy: end) ?? end
      normalized.removeSubrange(limit..<end)
    }
  }
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = hasFraction ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
  return formatter.date(from: normalized)
}
