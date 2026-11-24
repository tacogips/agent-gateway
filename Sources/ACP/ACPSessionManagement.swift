import Foundation

// Session listing, closing, deletion, and configuration options. The
// request/response shapes here are the same in ACP v1 and v2 unless a type
// says otherwise; the version-specific differences are the config option
// key names, handled by `ACPSessionConfigOption.V1Coding`.

// MARK: - session/list

/// Session metadata returned by `session/list` (`SessionInfo`).
public struct ACPSessionInfo: Codable, Equatable, Sendable {
  public var sessionId: ACPSessionID
  public var cwd: String
  public var additionalDirectories: [String]
  public var title: String?
  /// RFC 3339 timestamp of the last activity in the session.
  public var updatedAt: String?
  public var meta: ACPJSONValue?

  public init(
    sessionId: ACPSessionID,
    cwd: String,
    additionalDirectories: [String] = [],
    title: String? = nil,
    updatedAt: String? = nil,
    meta: ACPJSONValue? = nil
  ) {
    self.sessionId = sessionId
    self.cwd = cwd
    self.additionalDirectories = additionalDirectories
    self.title = title
    self.updatedAt = updatedAt
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case sessionId
    case cwd
    case additionalDirectories
    case title
    case updatedAt
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionId = try container.decode(ACPSessionID.self, forKey: .sessionId)
    cwd = try container.decode(String.self, forKey: .cwd)
    additionalDirectories = container.decodeLenient([String].self, forKey: .additionalDirectories) ?? []
    title = container.decodeLenient(String.self, forKey: .title)
    updatedAt = container.decodeLenient(String.self, forKey: .updatedAt)
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sessionId, forKey: .sessionId)
    try container.encode(cwd, forKey: .cwd)
    if !additionalDirectories.isEmpty {
      try container.encode(additionalDirectories, forKey: .additionalDirectories)
    }
    try container.encodeIfPresent(title, forKey: .title)
    try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    try container.encodeIfPresent(meta, forKey: .meta)
  }
}

public struct ACPListSessionsRequest: Codable, Equatable, Sendable {
  /// Only sessions whose working directory is exactly this absolute path.
  public var cwd: String?
  /// Opaque token from a previous response's `nextCursor`.
  public var cursor: String?
  public var meta: ACPJSONValue?

  public init(cwd: String? = nil, cursor: String? = nil, meta: ACPJSONValue? = nil) {
    self.cwd = cwd
    self.cursor = cursor
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case cwd
    case cursor
    case meta = "_meta"
  }
}

public struct ACPListSessionsResponse: Codable, Equatable, Sendable {
  public var sessions: [ACPSessionInfo]
  /// Absent means there are no more results; an empty string is a valid cursor.
  public var nextCursor: String?
  public var meta: ACPJSONValue?

  public init(sessions: [ACPSessionInfo], nextCursor: String? = nil, meta: ACPJSONValue? = nil) {
    self.sessions = sessions
    self.nextCursor = nextCursor
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case sessions
    case nextCursor
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessions = container.decodeLenientArray(ACPSessionInfo.self, forKey: .sessions) ?? []
    nextCursor = container.decodeLenient(String.self, forKey: .nextCursor)
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }
}

// MARK: - session/close, session/delete

/// Params naming one session: `session/close` and `session/delete`.
public struct ACPSessionRequest: Codable, Equatable, Sendable {
  public var sessionId: ACPSessionID
  public var meta: ACPJSONValue?

  public init(sessionId: ACPSessionID, meta: ACPJSONValue? = nil) {
    self.sessionId = sessionId
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case sessionId
    case meta = "_meta"
  }
}

// MARK: - Config options

/// A session configuration option (`SessionConfigOption`): model, mode,
/// thinking level, and similar per-session selectors.
///
/// `Codable` uses the ACP v2 key names (`configId`, `groupId`); wrap a value
/// in `V1Coding` to code it with the v1 names (`id`, `group`).
public struct ACPSessionConfigOption: Codable, Equatable, Sendable {
  public static let categoryMode = "mode"
  public static let categoryModel = "model"
  public static let categoryModelConfig = "model_config"
  public static let categoryThoughtLevel = "thought_level"

  public struct SelectOption: Equatable, Sendable {
    public var value: String
    public var name: String
    public var description: String?
    public var meta: ACPJSONValue?

    public init(value: String, name: String, description: String? = nil, meta: ACPJSONValue? = nil) {
      self.value = value
      self.name = name
      self.description = description
      self.meta = meta
    }
  }

  public struct SelectGroup: Equatable, Sendable {
    public var groupId: String
    public var name: String
    public var options: [SelectOption]
    public var meta: ACPJSONValue?

    public init(groupId: String, name: String, options: [SelectOption], meta: ACPJSONValue? = nil) {
      self.groupId = groupId
      self.name = name
      self.options = options
      self.meta = meta
    }
  }

  public enum SelectOptions: Equatable, Sendable {
    case ungrouped([SelectOption])
    case grouped([SelectGroup])

    /// Every selectable option, flattened across groups.
    public var all: [SelectOption] {
      switch self {
      case .ungrouped(let options): options
      case .grouped(let groups): groups.flatMap(\.options)
      }
    }
  }

  public enum Kind: Equatable, Sendable {
    case select(currentValue: String, options: SelectOptions)
    case boolean(currentValue: Bool)
    /// A custom or future option type, preserved as raw JSON.
    case other(ACPJSONValue)
  }

  public var configId: String
  public var name: String
  public var description: String?
  /// `mode`, `model`, `model_config`, `thought_level`, or an unknown category.
  public var category: String?
  public var kind: Kind
  public var meta: ACPJSONValue?

  public init(
    configId: String,
    name: String,
    description: String? = nil,
    category: String? = nil,
    kind: Kind,
    meta: ACPJSONValue? = nil
  ) {
    self.configId = configId
    self.name = name
    self.description = description
    self.category = category
    self.kind = kind
    self.meta = meta
  }

  public init(from decoder: any Decoder) throws {
    self = try ACPSessionConfigOption.decode(from: decoder)
  }

  public func encode(to encoder: any Encoder) throws {
    try encode(to: encoder, idKey: "configId", groupKey: "groupId")
  }

  /// ACP v1 coding of a config option: `id` and `group` key names.
  public struct V1Coding: Codable, Equatable, Sendable {
    public var option: ACPSessionConfigOption

    public init(_ option: ACPSessionConfigOption) {
      self.option = option
    }

    public init(from decoder: any Decoder) throws {
      option = try ACPSessionConfigOption.decode(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
      try option.encode(to: encoder, idKey: "id", groupKey: "group")
    }
  }
}

extension ACPSessionConfigOption {
  private static func key(_ name: String) -> ACPDynamicKey {
    ACPDynamicKey(name)
  }

  /// Decodes either version's key names: readers are tolerant, writers exact.
  fileprivate static func decode(from decoder: any Decoder) throws -> ACPSessionConfigOption {
    let container = try decoder.container(keyedBy: ACPDynamicKey.self)
    let configId = try container.decodeIfPresent(String.self, forKey: key("configId"))
      ?? container.decode(String.self, forKey: key("id"))
    let name = try container.decode(String.self, forKey: key("name"))
    let kind: Kind
    switch try container.decode(String.self, forKey: key("type")) {
    case "select":
      let currentValue = try container.decode(String.self, forKey: key("currentValue"))
      kind = .select(currentValue: currentValue, options: try decodeOptions(container))
    case "boolean":
      kind = .boolean(currentValue: try container.decode(Bool.self, forKey: key("currentValue")))
    default:
      kind = .other(try ACPJSONValue(from: decoder))
    }
    return ACPSessionConfigOption(
      configId: configId,
      name: name,
      description: container.decodeLenient(String.self, forKey: key("description")),
      category: container.decodeLenient(String.self, forKey: key("category")),
      kind: kind,
      meta: container.decodeLenient(ACPJSONValue.self, forKey: key("_meta"))
    )
  }

  private static func decodeOptions(
    _ container: KeyedDecodingContainer<ACPDynamicKey>
  ) throws -> SelectOptions {
    let raw = try container.decode([ACPJSONValue].self, forKey: key("options"))
    let isGrouped = raw.first?["options"] != nil
    if isGrouped {
      return .grouped(try raw.map { entry in
        guard let name = entry["name"]?.stringValue,
              let groupId = entry["groupId"]?.stringValue ?? entry["group"]?.stringValue,
              case .array(let options)? = entry["options"] else {
          throw DecodingError.dataCorruptedError(
            forKey: key("options"), in: container, debugDescription: "malformed config option group"
          )
        }
        return SelectGroup(
          groupId: groupId, name: name, options: try options.map { try decodeOption($0, container) },
          meta: entry["_meta"]
        )
      })
    }
    return .ungrouped(try raw.map { try decodeOption($0, container) })
  }

  private static func decodeOption(
    _ entry: ACPJSONValue, _ container: KeyedDecodingContainer<ACPDynamicKey>
  ) throws -> SelectOption {
    guard let value = entry["value"]?.stringValue, let name = entry["name"]?.stringValue else {
      throw DecodingError.dataCorruptedError(
        forKey: key("options"), in: container, debugDescription: "malformed config select option"
      )
    }
    return SelectOption(
      value: value, name: name, description: entry["description"]?.stringValue, meta: entry["_meta"]
    )
  }

  fileprivate func encode(to encoder: any Encoder, idKey: String, groupKey: String) throws {
    if case .other(let raw) = kind {
      try raw.encode(to: encoder)
      return
    }
    var container = encoder.container(keyedBy: ACPDynamicKey.self)
    try container.encode(configId, forKey: Self.key(idKey))
    try container.encode(name, forKey: Self.key("name"))
    try container.encodeIfPresent(description, forKey: Self.key("description"))
    try container.encodeIfPresent(category, forKey: Self.key("category"))
    try container.encodeIfPresent(meta, forKey: Self.key("_meta"))
    switch kind {
    case .select(let currentValue, let options):
      try container.encode("select", forKey: Self.key("type"))
      try container.encode(currentValue, forKey: Self.key("currentValue"))
      let encoded: [ACPJSONValue]
      switch options {
      case .ungrouped(let options):
        encoded = options.map(Self.json)
      case .grouped(let groups):
        encoded = groups.map { group in
          var object: [String: ACPJSONValue] = [
            groupKey: .string(group.groupId),
            "name": .string(group.name),
            "options": .array(group.options.map(Self.json))
          ]
          object["_meta"] = group.meta
          return .object(object)
        }
      }
      try container.encode(encoded, forKey: Self.key("options"))
    case .boolean(let currentValue):
      try container.encode("boolean", forKey: Self.key("type"))
      try container.encode(currentValue, forKey: Self.key("currentValue"))
    case .other:
      preconditionFailure("handled above")
    }
  }

  private static func json(_ option: SelectOption) -> ACPJSONValue {
    var object: [String: ACPJSONValue] = ["value": .string(option.value), "name": .string(option.name)]
    if let description = option.description { object["description"] = .string(description) }
    object["_meta"] = option.meta
    return .object(object)
  }
}

/// A value for `session/set_config_option`.
public enum ACPSessionConfigValue: Equatable, Sendable {
  /// The id of a `select` option.
  case id(String)
  case boolean(Bool)
  /// A custom or future value type, preserved with its discriminator.
  case other(type: String, value: ACPJSONValue)
}

/// `session/set_config_option` params.
///
/// v2 requires a `type` discriminator (`"id"` or `"boolean"`); v1 sends a
/// bare `value` for select options and `type: "boolean"` for booleans.
/// Decoding accepts both; encoding writes the v2 form unless
/// `usesV1Encoding` is set.
public struct ACPSetSessionConfigOptionRequest: Codable, Equatable, Sendable {
  public var sessionId: ACPSessionID
  public var configId: String
  public var value: ACPSessionConfigValue
  /// Whether to omit the `"id"` discriminator when encoding (ACP v1).
  public var usesV1Encoding: Bool
  public var meta: ACPJSONValue?

  public init(
    sessionId: ACPSessionID,
    configId: String,
    value: ACPSessionConfigValue,
    usesV1Encoding: Bool = false,
    meta: ACPJSONValue? = nil
  ) {
    self.sessionId = sessionId
    self.configId = configId
    self.value = value
    self.usesV1Encoding = usesV1Encoding
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case sessionId
    case configId
    case type
    case value
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionId = try container.decode(ACPSessionID.self, forKey: .sessionId)
    configId = try container.decode(String.self, forKey: .configId)
    let type = try container.decodeIfPresent(String.self, forKey: .type)
    usesV1Encoding = type == nil
    switch type {
    case nil, "id":
      value = .id(try container.decode(String.self, forKey: .value))
    case "boolean":
      value = .boolean(try container.decode(Bool.self, forKey: .value))
    case .some(let other):
      value = .other(type: other, value: try container.decode(ACPJSONValue.self, forKey: .value))
    }
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sessionId, forKey: .sessionId)
    try container.encode(configId, forKey: .configId)
    switch value {
    case .id(let id):
      if !usesV1Encoding {
        try container.encode("id", forKey: .type)
      }
      try container.encode(id, forKey: .value)
    case .boolean(let flag):
      try container.encode("boolean", forKey: .type)
      try container.encode(flag, forKey: .value)
    case .other(let type, let raw):
      try container.encode(type, forKey: .type)
      try container.encode(raw, forKey: .value)
    }
    try container.encodeIfPresent(meta, forKey: .meta)
  }
}

/// `session/set_config_option` result: the complete updated option list,
/// since one change can affect other options. ACP v2 key names.
public struct ACPSetSessionConfigOptionResponse: Codable, Equatable, Sendable {
  public var configOptions: [ACPSessionConfigOption]
  public var meta: ACPJSONValue?

  public init(configOptions: [ACPSessionConfigOption], meta: ACPJSONValue? = nil) {
    self.configOptions = configOptions
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case configOptions
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    configOptions = container.decodeLenientArray(ACPSessionConfigOption.self, forKey: .configOptions) ?? []
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }

  /// The same result coded with ACP v1 key names.
  public var v1: V1Coding { V1Coding(configOptions: configOptions.map(ACPSessionConfigOption.V1Coding.init), meta: meta) }

  public struct V1Coding: Codable, Equatable, Sendable {
    public var configOptions: [ACPSessionConfigOption.V1Coding]
    public var meta: ACPJSONValue?

    public init(configOptions: [ACPSessionConfigOption.V1Coding], meta: ACPJSONValue? = nil) {
      self.configOptions = configOptions
      self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
      case configOptions
      case meta = "_meta"
    }
  }
}

// MARK: - Slash commands (v2)

/// A slash command advertised by the agent (ACP v2 `AvailableCommand`).
public enum ACPV2AvailableCommand: Codable, Equatable, Sendable {
  case command(Command)
  /// A custom or future command type. Clients that do not understand a
  /// command type must not display it as a slash command.
  case other(ACPJSONValue)

  public struct Command: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    /// Input specification (`{"type": "text", "hint": ...}` or a future type).
    public var input: ACPJSONValue?
    public var meta: ACPJSONValue?

    public init(name: String, description: String, input: ACPJSONValue? = nil, meta: ACPJSONValue? = nil) {
      self.name = name
      self.description = description
      self.input = input
      self.meta = meta
    }

    /// Text input specification with the given hint.
    public static func textInput(hint: String) -> ACPJSONValue {
      .object(["type": .string("text"), "hint": .string(hint)])
    }

    private enum CodingKeys: String, CodingKey {
      case name
      case description
      case input
      case meta = "_meta"
    }
  }

  private enum CodingKeys: String, CodingKey {
    case type
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if try container.decode(String.self, forKey: .type) == "command" {
      self = .command(try Command(from: decoder))
    } else {
      self = .other(try ACPJSONValue(from: decoder))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    switch self {
    case .command(let command):
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode("command", forKey: .type)
      try command.encode(to: encoder)
    case .other(let value):
      try value.encode(to: encoder)
    }
  }
}
