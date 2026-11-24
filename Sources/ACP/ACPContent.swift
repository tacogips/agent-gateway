import Foundation

/// Content blocks per the ACP `ContentBlock` schema (MCP-compatible).
public enum ACPContentBlock: Codable, Equatable, Sendable {
  case text(ACPTextContent)
  case image(ACPImageContent)
  case audio(ACPAudioContent)
  case resourceLink(ACPResourceLink)
  case resource(ACPEmbeddedResource)
  /// A block whose `type` this library does not model: a custom
  /// (`_`-prefixed) or future variant. Carries the raw JSON so it survives
  /// storing, replaying, and proxying. ACP v2 makes the discriminator
  /// extensible; receivers that cannot act on a block reject or ignore it.
  case other(ACPJSONValue)

  public static func text(_ value: String) -> ACPContentBlock {
    .text(ACPTextContent(text: value))
  }

  /// The wire `type` discriminator of this block.
  public var type: String {
    switch self {
    case .text: "text"
    case .image: "image"
    case .audio: "audio"
    case .resourceLink: "resource_link"
    case .resource: "resource"
    case .other(let value): value["type"]?.stringValue ?? ""
    }
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
    default: self = .other(try ACPJSONValue(from: decoder))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    if case .other(let value) = self {
      try value.encode(to: encoder)
      return
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, forKey: .type)
    switch self {
    case .text(let value): try value.encode(to: encoder)
    case .image(let value): try value.encode(to: encoder)
    case .audio(let value): try value.encode(to: encoder)
    case .resourceLink(let value): try value.encode(to: encoder)
    case .resource(let value): try value.encode(to: encoder)
    case .other: preconditionFailure("handled above")
    }
  }
}

public struct ACPTextContent: Codable, Equatable, Sendable {
  public var text: String
  public var annotations: ACPJSONValue?
  public var meta: ACPJSONValue?

  public init(text: String, annotations: ACPJSONValue? = nil, meta: ACPJSONValue? = nil) {
    self.text = text
    self.annotations = annotations
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case text
    case annotations
    case meta = "_meta"
  }
}

public struct ACPImageContent: Codable, Equatable, Sendable {
  public var data: String
  public var mimeType: String
  public var uri: String?
  public var annotations: ACPJSONValue?
  public var meta: ACPJSONValue?

  public init(
    data: String,
    mimeType: String,
    uri: String? = nil,
    annotations: ACPJSONValue? = nil,
    meta: ACPJSONValue? = nil
  ) {
    self.data = data
    self.mimeType = mimeType
    self.uri = uri
    self.annotations = annotations
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case data
    case mimeType
    case uri
    case annotations
    case meta = "_meta"
  }
}

public struct ACPAudioContent: Codable, Equatable, Sendable {
  public var data: String
  public var mimeType: String
  public var annotations: ACPJSONValue?
  public var meta: ACPJSONValue?

  public init(data: String, mimeType: String, annotations: ACPJSONValue? = nil, meta: ACPJSONValue? = nil) {
    self.data = data
    self.mimeType = mimeType
    self.annotations = annotations
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case data
    case mimeType
    case annotations
    case meta = "_meta"
  }
}

public struct ACPResourceLink: Codable, Equatable, Sendable {
  public var uri: String
  public var name: String
  public var title: String?
  public var description: String?
  public var mimeType: String?
  public var size: Int?
  /// Icons for the linked resource (ACP v2; each has a required `src`).
  public var icons: ACPJSONValue?
  public var annotations: ACPJSONValue?
  public var meta: ACPJSONValue?

  public init(
    uri: String,
    name: String,
    title: String? = nil,
    description: String? = nil,
    mimeType: String? = nil,
    size: Int? = nil,
    icons: ACPJSONValue? = nil,
    annotations: ACPJSONValue? = nil,
    meta: ACPJSONValue? = nil
  ) {
    self.uri = uri
    self.name = name
    self.title = title
    self.description = description
    self.mimeType = mimeType
    self.size = size
    self.icons = icons
    self.annotations = annotations
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case uri
    case name
    case title
    case description
    case mimeType
    case size
    case icons
    case annotations
    case meta = "_meta"
  }
}

public struct ACPEmbeddedResource: Codable, Equatable, Sendable {
  public var resource: ACPEmbeddedResourceContents
  public var annotations: ACPJSONValue?
  public var meta: ACPJSONValue?

  public init(
    resource: ACPEmbeddedResourceContents,
    annotations: ACPJSONValue? = nil,
    meta: ACPJSONValue? = nil
  ) {
    self.resource = resource
    self.annotations = annotations
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case resource
    case annotations
    case meta = "_meta"
  }
}

public struct ACPEmbeddedResourceContents: Codable, Equatable, Sendable {
  public var uri: String
  public var mimeType: String?
  /// Present for text resources.
  public var text: String?
  /// Present (base64) for binary resources.
  public var blob: String?
  public var meta: ACPJSONValue?

  public init(
    uri: String,
    mimeType: String? = nil,
    text: String? = nil,
    blob: String? = nil,
    meta: ACPJSONValue? = nil
  ) {
    self.uri = uri
    self.mimeType = mimeType
    self.text = text
    self.blob = blob
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case uri
    case mimeType
    case text
    case blob
    case meta = "_meta"
  }
}
