import Foundation

// ACP protocol version 2 wire types: initialization, session lifecycle, and
// prompt requests. v2 shapes are kept separate from the v1 types (`ACP…`)
// because the two versions differ in lifecycle, not just in field names; a
// connection speaks exactly one of them after `initialize`.

/// Message identifier owned by the agent (the schema's `MessageId`).
public typealias ACPMessageID = String

// MARK: - Capabilities

/// Client capabilities for ACP v2 (`ClientCapabilities`). The v1 `fs` and
/// `terminal` groups do not exist in v2.
public struct ACPV2ClientCapabilities: Codable, Equatable, Sendable {
  public struct Auth: Codable, Equatable, Sendable {
    /// The client can launch the agent interactively for `terminal` auth methods.
    public var terminal: ACPSupportMarker?
    public var meta: ACPJSONValue?

    public init(terminal: ACPSupportMarker? = nil, meta: ACPJSONValue? = nil) {
      self.terminal = terminal
      self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
      case terminal
      case meta = "_meta"
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      terminal = container.decodeLenient(ACPSupportMarker.self, forKey: .terminal)
      meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
    }
  }

  public struct Elicitation: Codable, Equatable, Sendable {
    public var form: ACPSupportMarker?
    public var url: ACPSupportMarker?
    public var meta: ACPJSONValue?

    public init(form: ACPSupportMarker? = nil, url: ACPSupportMarker? = nil, meta: ACPJSONValue? = nil) {
      self.form = form
      self.url = url
      self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
      case form
      case url
      case meta = "_meta"
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      form = container.decodeLenient(ACPSupportMarker.self, forKey: .form)
      url = container.decodeLenient(ACPSupportMarker.self, forKey: .url)
      meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
    }
  }

  public var auth: Auth?
  public var elicitation: Elicitation?
  public var meta: ACPJSONValue?

  public init(auth: Auth? = nil, elicitation: Elicitation? = nil, meta: ACPJSONValue? = nil) {
    self.auth = auth
    self.elicitation = elicitation
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case auth
    case elicitation
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    auth = container.decodeLenient(Auth.self, forKey: .auth)
    elicitation = container.decodeLenient(Elicitation.self, forKey: .elicitation)
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }
}

/// Prompt content extensions beyond the baseline `text` and `resource_link`.
public struct ACPV2PromptCapabilities: Codable, Equatable, Sendable {
  public var image: ACPSupportMarker?
  public var audio: ACPSupportMarker?
  public var embeddedContext: ACPSupportMarker?
  public var meta: ACPJSONValue?

  public init(
    image: ACPSupportMarker? = nil,
    audio: ACPSupportMarker? = nil,
    embeddedContext: ACPSupportMarker? = nil,
    meta: ACPJSONValue? = nil
  ) {
    self.image = image
    self.audio = audio
    self.embeddedContext = embeddedContext
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case image
    case audio
    case embeddedContext
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    image = container.decodeLenient(ACPSupportMarker.self, forKey: .image)
    audio = container.decodeLenient(ACPSupportMarker.self, forKey: .audio)
    embeddedContext = container.decodeLenient(ACPSupportMarker.self, forKey: .embeddedContext)
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }
}

/// MCP server transports the agent accepts on session lifecycle requests.
public struct ACPV2MCPCapabilities: Codable, Equatable, Sendable {
  public var stdio: ACPSupportMarker?
  public var http: ACPSupportMarker?
  public var meta: ACPJSONValue?

  public init(stdio: ACPSupportMarker? = nil, http: ACPSupportMarker? = nil, meta: ACPJSONValue? = nil) {
    self.stdio = stdio
    self.http = http
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case stdio
    case http
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    stdio = container.decodeLenient(ACPSupportMarker.self, forKey: .stdio)
    http = container.decodeLenient(ACPSupportMarker.self, forKey: .http)
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }
}

/// `systemPrompt` support on session lifecycle requests. Presence means
/// `append` mode; `mode.override` additionally advertises `override`.
public struct ACPSystemPromptCapabilities: Codable, Equatable, Sendable {
  public struct Mode: Codable, Equatable, Sendable {
    public var override: ACPSupportMarker?

    public init(override: ACPSupportMarker? = nil) {
      self.override = override
    }

    private enum CodingKeys: String, CodingKey {
      case override
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      override = container.decodeLenient(ACPSupportMarker.self, forKey: .override)
    }
  }

  public var mode: Mode?
  public var meta: ACPJSONValue?

  public init(mode: Mode? = nil, meta: ACPJSONValue? = nil) {
    self.mode = mode
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case mode
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    mode = container.decodeLenient(Mode.self, forKey: .mode)
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }
}

/// `capabilities.session`: its presence commits the agent to the baseline
/// `session/new`, `session/list`, `session/resume`, `session/close`,
/// `session/prompt`, `session/cancel`, and `session/update`.
public struct ACPV2SessionCapabilities: Codable, Equatable, Sendable {
  public var prompt: ACPV2PromptCapabilities?
  public var mcp: ACPV2MCPCapabilities?
  public var delete: ACPSupportMarker?
  public var additionalDirectories: ACPSupportMarker?
  public var systemPrompt: ACPSystemPromptCapabilities?
  public var meta: ACPJSONValue?

  public init(
    prompt: ACPV2PromptCapabilities? = nil,
    mcp: ACPV2MCPCapabilities? = nil,
    delete: ACPSupportMarker? = nil,
    additionalDirectories: ACPSupportMarker? = nil,
    systemPrompt: ACPSystemPromptCapabilities? = nil,
    meta: ACPJSONValue? = nil
  ) {
    self.prompt = prompt
    self.mcp = mcp
    self.delete = delete
    self.additionalDirectories = additionalDirectories
    self.systemPrompt = systemPrompt
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case prompt
    case mcp
    case delete
    case additionalDirectories
    case systemPrompt
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    prompt = container.decodeLenient(ACPV2PromptCapabilities.self, forKey: .prompt)
    mcp = container.decodeLenient(ACPV2MCPCapabilities.self, forKey: .mcp)
    delete = container.decodeLenient(ACPSupportMarker.self, forKey: .delete)
    additionalDirectories = container.decodeLenient(ACPSupportMarker.self, forKey: .additionalDirectories)
    systemPrompt = container.decodeLenient(ACPSystemPromptCapabilities.self, forKey: .systemPrompt)
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }
}

/// Agent capabilities for ACP v2 (`AgentCapabilities`).
public struct ACPV2AgentCapabilities: Codable, Equatable, Sendable {
  public var session: ACPV2SessionCapabilities?
  /// Authentication-related extensions; orthogonal to `authMethods`.
  public var auth: ACPJSONValue?
  public var meta: ACPJSONValue?

  public init(session: ACPV2SessionCapabilities? = nil, auth: ACPJSONValue? = nil, meta: ACPJSONValue? = nil) {
    self.session = session
    self.auth = auth
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case session
    case auth
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    session = container.decodeLenient(ACPV2SessionCapabilities.self, forKey: .session)
    auth = container.decodeLenient(ACPJSONValue.self, forKey: .auth)
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }
}

/// Authentication method descriptor for ACP v2 (`AuthMethod`): `methodId`
/// replaces v1's `id`, and the `type` discriminator is required.
public struct ACPV2AuthMethod: Codable, Equatable, Sendable {
  public var methodId: String
  /// `agent`, `terminal`, or a custom (`_`-prefixed) / future type.
  public var type: String
  public var name: String
  public var description: String?
  /// Launch arguments for `terminal` methods.
  public var args: [String]?
  /// Environment entries for `terminal` methods.
  public var env: [ACPEnvVariable]?
  public var meta: ACPJSONValue?

  public init(
    methodId: String,
    type: String,
    name: String,
    description: String? = nil,
    args: [String]? = nil,
    env: [ACPEnvVariable]? = nil,
    meta: ACPJSONValue? = nil
  ) {
    self.methodId = methodId
    self.type = type
    self.name = name
    self.description = description
    self.args = args
    self.env = env
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case methodId
    case type
    case name
    case description
    case args
    case env
    case meta = "_meta"
  }
}

// MARK: - initialize

public struct ACPV2InitializeRequest: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  /// Required in v2 on both sides.
  public var info: ACPImplementation
  public var capabilities: ACPV2ClientCapabilities
  public var meta: ACPJSONValue?

  public init(
    protocolVersion: Int = ACPProtocol.versionV2,
    info: ACPImplementation,
    capabilities: ACPV2ClientCapabilities = ACPV2ClientCapabilities(),
    meta: ACPJSONValue? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.info = info
    self.capabilities = capabilities
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case info
    case capabilities
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    info = try container.decode(ACPImplementation.self, forKey: .info)
    capabilities = container.decodeLenient(ACPV2ClientCapabilities.self, forKey: .capabilities)
      ?? ACPV2ClientCapabilities()
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }
}

public struct ACPV2InitializeResponse: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  public var info: ACPImplementation
  public var capabilities: ACPV2AgentCapabilities
  /// Omitted or empty means `auth/login` and `auth/logout` are unavailable.
  public var authMethods: [ACPV2AuthMethod]
  public var meta: ACPJSONValue?

  public init(
    protocolVersion: Int = ACPProtocol.versionV2,
    info: ACPImplementation,
    capabilities: ACPV2AgentCapabilities = ACPV2AgentCapabilities(),
    authMethods: [ACPV2AuthMethod] = [],
    meta: ACPJSONValue? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.info = info
    self.capabilities = capabilities
    self.authMethods = authMethods
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case info
    case capabilities
    case authMethods
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    info = try container.decode(ACPImplementation.self, forKey: .info)
    capabilities = container.decodeLenient(ACPV2AgentCapabilities.self, forKey: .capabilities)
      ?? ACPV2AgentCapabilities()
    authMethods = container.decodeLenientArray(ACPV2AuthMethod.self, forKey: .authMethods) ?? []
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(protocolVersion, forKey: .protocolVersion)
    try container.encode(info, forKey: .info)
    try container.encode(capabilities, forKey: .capabilities)
    if !authMethods.isEmpty {
      try container.encode(authMethods, forKey: .authMethods)
    }
    try container.encodeIfPresent(meta, forKey: .meta)
  }
}

// MARK: - MCP servers and system prompt

/// MCP server configuration for ACP v2 (`McpServer`): every entry carries a
/// `type` discriminator, and the legacy SSE transport is gone.
public enum ACPV2MCPServer: Codable, Equatable, Sendable {
  case stdio(Stdio)
  case http(HTTP)
  /// A custom (`_`-prefixed) or future transport, preserved as raw JSON.
  case other(ACPJSONValue)

  public struct Stdio: Codable, Equatable, Sendable {
    public var name: String
    /// Absolute path of the server executable.
    public var command: String
    public var args: [String]?
    public var env: [ACPEnvVariable]?
    public var meta: ACPJSONValue?

    public init(
      name: String, command: String, args: [String]? = nil, env: [ACPEnvVariable]? = nil, meta: ACPJSONValue? = nil
    ) {
      self.name = name
      self.command = command
      self.args = args
      self.env = env
      self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
      case name
      case command
      case args
      case env
      case meta = "_meta"
    }
  }

  public struct HTTP: Codable, Equatable, Sendable {
    public var name: String
    public var url: String
    public var headers: [ACPEnvVariable]?
    public var meta: ACPJSONValue?

    public init(name: String, url: String, headers: [ACPEnvVariable]? = nil, meta: ACPJSONValue? = nil) {
      self.name = name
      self.url = url
      self.headers = headers
      self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
      case name
      case url
      case headers
      case meta = "_meta"
    }
  }

  /// The wire `type` discriminator.
  public var type: String {
    switch self {
    case .stdio: "stdio"
    case .http: "http"
    case .other(let value): value["type"]?.stringValue ?? ""
    }
  }

  /// The server's name, when the entry carries one.
  public var name: String? {
    switch self {
    case .stdio(let server): server.name
    case .http(let server): server.name
    case .other(let value): value["name"]?.stringValue
    }
  }

  private enum CodingKeys: String, CodingKey {
    case type
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .type) {
    case "stdio": self = .stdio(try Stdio(from: decoder))
    case "http": self = .http(try HTTP(from: decoder))
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
    case .stdio(let server): try server.encode(to: encoder)
    case .http(let server): try server.encode(to: encoder)
    case .other: preconditionFailure("handled above")
    }
  }
}

/// System-level instructions supplied on session lifecycle requests
/// (`SystemPrompt`). Shared by v1 and v2, which define the same shape.
public struct ACPSystemPrompt: Codable, Equatable, Sendable {
  public static let appendMode = "append"
  public static let overrideMode = "override"

  /// `append`, `override`, or a custom (`_`-prefixed) / future mode.
  public var mode: String
  public var content: [ACPContentBlock]
  public var meta: ACPJSONValue?

  public init(mode: String = ACPSystemPrompt.appendMode, content: [ACPContentBlock], meta: ACPJSONValue? = nil) {
    self.mode = mode
    self.content = content
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case mode
    case content
    case meta = "_meta"
  }
}

// MARK: - session/new, session/resume

public struct ACPV2NewSessionRequest: Codable, Equatable, Sendable {
  public var cwd: String
  public var additionalDirectories: [String]
  /// Optional in v2; omitted and `[]` are equivalent.
  public var mcpServers: [ACPV2MCPServer]
  public var systemPrompt: ACPSystemPrompt?
  public var meta: ACPJSONValue?

  public init(
    cwd: String,
    additionalDirectories: [String] = [],
    mcpServers: [ACPV2MCPServer] = [],
    systemPrompt: ACPSystemPrompt? = nil,
    meta: ACPJSONValue? = nil
  ) {
    self.cwd = cwd
    self.additionalDirectories = additionalDirectories
    self.mcpServers = mcpServers
    self.systemPrompt = systemPrompt
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case cwd
    case additionalDirectories
    case mcpServers
    case systemPrompt
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    cwd = try container.decode(String.self, forKey: .cwd)
    additionalDirectories = try container.decodeIfPresent([String].self, forKey: .additionalDirectories) ?? []
    mcpServers = try container.decodeIfPresent([ACPV2MCPServer].self, forKey: .mcpServers) ?? []
    systemPrompt = try container.decodeIfPresent(ACPSystemPrompt.self, forKey: .systemPrompt)
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(cwd, forKey: .cwd)
    if !additionalDirectories.isEmpty {
      try container.encode(additionalDirectories, forKey: .additionalDirectories)
    }
    if !mcpServers.isEmpty {
      try container.encode(mcpServers, forKey: .mcpServers)
    }
    try container.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
    try container.encodeIfPresent(meta, forKey: .meta)
  }
}

/// Session setup result shared by `session/new` and `session/resume`: the
/// complete current config options and commands. Omitted lists mean none.
public struct ACPV2NewSessionResponse: Codable, Equatable, Sendable {
  public var sessionId: ACPSessionID
  public var configOptions: [ACPSessionConfigOption]
  public var availableCommands: [ACPV2AvailableCommand]
  public var meta: ACPJSONValue?

  public init(
    sessionId: ACPSessionID,
    configOptions: [ACPSessionConfigOption] = [],
    availableCommands: [ACPV2AvailableCommand] = [],
    meta: ACPJSONValue? = nil
  ) {
    self.sessionId = sessionId
    self.configOptions = configOptions
    self.availableCommands = availableCommands
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case sessionId
    case configOptions
    case availableCommands
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionId = try container.decode(ACPSessionID.self, forKey: .sessionId)
    configOptions = container.decodeLenientArray(ACPSessionConfigOption.self, forKey: .configOptions) ?? []
    availableCommands = container.decodeLenientArray(ACPV2AvailableCommand.self, forKey: .availableCommands) ?? []
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sessionId, forKey: .sessionId)
    if !configOptions.isEmpty {
      try container.encode(configOptions, forKey: .configOptions)
    }
    if !availableCommands.isEmpty {
      try container.encode(availableCommands, forKey: .availableCommands)
    }
    try container.encodeIfPresent(meta, forKey: .meta)
  }
}

/// Where a `session/resume` history replay starts (`ReplayFrom`).
public enum ACPV2ReplayFrom: Codable, Equatable, Sendable {
  /// Replay all retained conversation history.
  case start
  /// A custom or future cursor type, preserved as raw JSON. Agents reject
  /// cursors they do not support with `-32602`.
  case other(ACPJSONValue)

  private enum CodingKeys: String, CodingKey {
    case type
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if try container.decode(String.self, forKey: .type) == "start" {
      self = .start
    } else {
      self = .other(try ACPJSONValue(from: decoder))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    switch self {
    case .start:
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode("start", forKey: .type)
    case .other(let value):
      try value.encode(to: encoder)
    }
  }
}

public struct ACPV2ResumeSessionRequest: Codable, Equatable, Sendable {
  public var sessionId: ACPSessionID
  public var cwd: String
  public var additionalDirectories: [String]
  public var mcpServers: [ACPV2MCPServer]
  /// Omitted reattaches without replay (v1 `session/resume`);
  /// `.start` replays retained history (v1 `session/load`).
  public var replayFrom: ACPV2ReplayFrom?
  public var systemPrompt: ACPSystemPrompt?
  public var meta: ACPJSONValue?

  public init(
    sessionId: ACPSessionID,
    cwd: String,
    additionalDirectories: [String] = [],
    mcpServers: [ACPV2MCPServer] = [],
    replayFrom: ACPV2ReplayFrom? = nil,
    systemPrompt: ACPSystemPrompt? = nil,
    meta: ACPJSONValue? = nil
  ) {
    self.sessionId = sessionId
    self.cwd = cwd
    self.additionalDirectories = additionalDirectories
    self.mcpServers = mcpServers
    self.replayFrom = replayFrom
    self.systemPrompt = systemPrompt
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case sessionId
    case cwd
    case additionalDirectories
    case mcpServers
    case replayFrom
    case systemPrompt
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionId = try container.decode(ACPSessionID.self, forKey: .sessionId)
    cwd = try container.decode(String.self, forKey: .cwd)
    additionalDirectories = try container.decodeIfPresent([String].self, forKey: .additionalDirectories) ?? []
    mcpServers = try container.decodeIfPresent([ACPV2MCPServer].self, forKey: .mcpServers) ?? []
    replayFrom = try container.decodeIfPresent(ACPV2ReplayFrom.self, forKey: .replayFrom)
    systemPrompt = try container.decodeIfPresent(ACPSystemPrompt.self, forKey: .systemPrompt)
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sessionId, forKey: .sessionId)
    try container.encode(cwd, forKey: .cwd)
    if !additionalDirectories.isEmpty {
      try container.encode(additionalDirectories, forKey: .additionalDirectories)
    }
    if !mcpServers.isEmpty {
      try container.encode(mcpServers, forKey: .mcpServers)
    }
    try container.encodeIfPresent(replayFrom, forKey: .replayFrom)
    try container.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
    try container.encodeIfPresent(meta, forKey: .meta)
  }
}

public struct ACPV2ResumeSessionResponse: Codable, Equatable, Sendable {
  public var configOptions: [ACPSessionConfigOption]
  public var availableCommands: [ACPV2AvailableCommand]
  public var meta: ACPJSONValue?

  public init(
    configOptions: [ACPSessionConfigOption] = [],
    availableCommands: [ACPV2AvailableCommand] = [],
    meta: ACPJSONValue? = nil
  ) {
    self.configOptions = configOptions
    self.availableCommands = availableCommands
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case configOptions
    case availableCommands
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    configOptions = container.decodeLenientArray(ACPSessionConfigOption.self, forKey: .configOptions) ?? []
    availableCommands = container.decodeLenientArray(ACPV2AvailableCommand.self, forKey: .availableCommands) ?? []
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if !configOptions.isEmpty {
      try container.encode(configOptions, forKey: .configOptions)
    }
    if !availableCommands.isEmpty {
      try container.encode(availableCommands, forKey: .availableCommands)
    }
    try container.encodeIfPresent(meta, forKey: .meta)
  }
}

// MARK: - session/prompt

public struct ACPV2PromptRequest: Codable, Equatable, Sendable {
  public var sessionId: ACPSessionID
  public var prompt: [ACPContentBlock]
  /// Client-generated key (1 to 255 characters) identifying one submission,
  /// so a retry after a lost response does not insert a second message.
  public var idempotencyKey: String?
  public var meta: ACPJSONValue?

  public init(
    sessionId: ACPSessionID,
    prompt: [ACPContentBlock],
    idempotencyKey: String? = nil,
    meta: ACPJSONValue? = nil
  ) {
    self.sessionId = sessionId
    self.prompt = prompt
    self.idempotencyKey = idempotencyKey
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case sessionId
    case prompt
    case idempotencyKey
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionId = try container.decode(ACPSessionID.self, forKey: .sessionId)
    prompt = try container.decode([ACPContentBlock].self, forKey: .prompt)
    // A malformed key is an error, never treated as omitted.
    idempotencyKey = try container.decodeIfPresent(String.self, forKey: .idempotencyKey)
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }
}

/// `session/prompt` result in v2: acknowledges that the user message was
/// inserted. It does not end the turn; completion arrives as an idle
/// `state_update`.
public struct ACPV2PromptResponse: Codable, Equatable, Sendable {
  /// Agent-generated id of the inserted user message.
  public var messageId: ACPMessageID
  public var meta: ACPJSONValue?

  public init(messageId: ACPMessageID, meta: ACPJSONValue? = nil) {
    self.messageId = messageId
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case messageId
    case meta = "_meta"
  }
}

// MARK: - tool_call/cancel, terminal/cancel, auth

public struct ACPV2CancelToolCallRequest: Codable, Equatable, Sendable {
  public var sessionId: ACPSessionID
  public var toolCallId: ACPToolCallID

  public init(sessionId: ACPSessionID, toolCallId: ACPToolCallID) {
    self.sessionId = sessionId
    self.toolCallId = toolCallId
  }
}

public struct ACPV2CancelTerminalRequest: Codable, Equatable, Sendable {
  public var sessionId: ACPSessionID
  public var terminalId: String

  public init(sessionId: ACPSessionID, terminalId: String) {
    self.sessionId = sessionId
    self.terminalId = terminalId
  }
}

/// `auth/login` params (v1 `authenticate` uses the same shape).
public struct ACPLoginRequest: Codable, Equatable, Sendable {
  public var methodId: String

  public init(methodId: String) {
    self.methodId = methodId
  }
}

/// Result object carrying nothing but optional `_meta`.
public struct ACPEmptyResult: Codable, Equatable, Sendable {
  public var meta: ACPJSONValue?

  public init(meta: ACPJSONValue? = nil) {
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    // Tolerates `null` results from lenient peers.
    guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
      meta = nil
      return
    }
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }
}
