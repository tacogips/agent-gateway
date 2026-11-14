import Foundation

/// Content blocks per the ACP `ContentBlock` schema (MCP-compatible).
public enum ACPContentBlock: Codable, Equatable, Sendable {
  case text(ACPTextContent)
  case image(ACPImageContent)
  case audio(ACPAudioContent)
  case resourceLink(ACPResourceLink)
  case resource(ACPEmbeddedResource)

  public static func text(_ value: String) -> ACPContentBlock {
    .text(ACPTextContent(text: value))
  }

  private enum CodingKeys: String, CodingKey {
    case type
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "text": self = .text(try ACPTextContent(from: decoder))
    case "image": self = .image(try ACPImageContent(from: decoder))
    case "audio": self = .audio(try ACPAudioContent(from: decoder))
    case "resource_link": self = .resourceLink(try ACPResourceLink(from: decoder))
    case "resource": self = .resource(try ACPEmbeddedResource(from: decoder))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: container, debugDescription: "unknown content block type '\(type)'"
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let value):
      try container.encode("text", forKey: .type)
      try value.encode(to: encoder)
    case .image(let value):
      try container.encode("image", forKey: .type)
      try value.encode(to: encoder)
    case .audio(let value):
      try container.encode("audio", forKey: .type)
      try value.encode(to: encoder)
    case .resourceLink(let value):
      try container.encode("resource_link", forKey: .type)
      try value.encode(to: encoder)
    case .resource(let value):
      try container.encode("resource", forKey: .type)
      try value.encode(to: encoder)
    }
  }
}

public struct ACPTextContent: Codable, Equatable, Sendable {
  public var text: String

  public init(text: String) {
    self.text = text
  }

  private enum CodingKeys: String, CodingKey {
    case text
  }
}

public struct ACPImageContent: Codable, Equatable, Sendable {
  public var data: String
  public var mimeType: String
  public var uri: String?

  public init(data: String, mimeType: String, uri: String? = nil) {
    self.data = data
    self.mimeType = mimeType
    self.uri = uri
  }

  private enum CodingKeys: String, CodingKey {
    case data
    case mimeType
    case uri
  }
}

public struct ACPAudioContent: Codable, Equatable, Sendable {
  public var data: String
  public var mimeType: String

  public init(data: String, mimeType: String) {
    self.data = data
    self.mimeType = mimeType
  }

  private enum CodingKeys: String, CodingKey {
    case data
    case mimeType
  }
}

public struct ACPResourceLink: Codable, Equatable, Sendable {
  public var uri: String
  public var name: String
  public var title: String?
  public var description: String?
  public var mimeType: String?
  public var size: Int?

  public init(
    uri: String,
    name: String,
    title: String? = nil,
    description: String? = nil,
    mimeType: String? = nil,
    size: Int? = nil
  ) {
    self.uri = uri
    self.name = name
    self.title = title
    self.description = description
    self.mimeType = mimeType
    self.size = size
  }

  private enum CodingKeys: String, CodingKey {
    case uri
    case name
    case title
    case description
    case mimeType
    case size
  }
}

public struct ACPEmbeddedResource: Codable, Equatable, Sendable {
  public var resource: ACPEmbeddedResourceContents

  public init(resource: ACPEmbeddedResourceContents) {
    self.resource = resource
  }

  private enum CodingKeys: String, CodingKey {
    case resource
  }
}

public struct ACPEmbeddedResourceContents: Codable, Equatable, Sendable {
  public var uri: String
  public var mimeType: String?
  /// Present for text resources.
  public var text: String?
  /// Present (base64) for binary resources.
  public var blob: String?

  public init(uri: String, mimeType: String? = nil, text: String? = nil, blob: String? = nil) {
    self.uri = uri
    self.mimeType = mimeType
    self.text = text
    self.blob = blob
  }
}
