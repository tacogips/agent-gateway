import Foundation

/// Session identifier issued by the agent in `session/new`
/// (the schema's `SessionId`).
public typealias ACPSessionID = String

/// Tool call identifier issued by the agent (the schema's `ToolCallId`).
public typealias ACPToolCallID = String

// MARK: - Method names

public enum ACPMethod {
  public static let initialize = "initialize"
  public static let authenticate = "authenticate"
  public static let sessionNew = "session/new"
  public static let sessionLoad = "session/load"
  public static let sessionPrompt = "session/prompt"
  public static let sessionSetModel = "session/set_model"
  public static let sessionCancel = "session/cancel"
  public static let sessionUpdate = "session/update"
  public static let sessionRequestPermission = "session/request_permission"
  public static let fsReadTextFile = "fs/read_text_file"
  public static let fsWriteTextFile = "fs/write_text_file"
  public static let sessionList = "session/list"
  public static let sessionResume = "session/resume"
  public static let sessionClose = "session/close"
  public static let sessionDelete = "session/delete"
  public static let sessionSetMode = "session/set_mode"
  public static let sessionSetConfigOption = "session/set_config_option"
  public static let logout = "logout"
  public static let elicitationCreate = "elicitation/create"
  public static let elicitationComplete = "elicitation/complete"
  /// Protocol-level notification cancelling a request the sender issued.
  public static let cancelRequest = "$/cancel_request"
  // ACP v2 renames and additions.
  public static let authLogin = "auth/login"
  public static let authLogout = "auth/logout"
  public static let toolCallCancel = "tool_call/cancel"
  public static let terminalCancel = "terminal/cancel"
}

// MARK: - Capabilities

public struct ACPFileSystemCapabilities: Codable, Equatable, Sendable {
  public var readTextFile: Bool
  public var writeTextFile: Bool

  public init(readTextFile: Bool = false, writeTextFile: Bool = false) {
    self.readTextFile = readTextFile
    self.writeTextFile = writeTextFile
  }

  private enum CodingKeys: String, CodingKey {
    case readTextFile
    case writeTextFile
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    readTextFile = try container.decodeIfPresent(Bool.self, forKey: .readTextFile) ?? false
    writeTextFile = try container.decodeIfPresent(Bool.self, forKey: .writeTextFile) ?? false
  }
}

public struct ACPClientCapabilities: Codable, Equatable, Sendable {
  public var fs: ACPFileSystemCapabilities
  public var terminal: Bool
  public var meta: ACPJSONValue?

  public init(
    fs: ACPFileSystemCapabilities = ACPFileSystemCapabilities(),
    terminal: Bool = false,
    meta: ACPJSONValue? = nil
  ) {
    self.fs = fs
    self.terminal = terminal
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case fs
    case terminal
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    fs = try container.decodeIfPresent(ACPFileSystemCapabilities.self, forKey: .fs) ?? ACPFileSystemCapabilities()
    terminal = try container.decodeIfPresent(Bool.self, forKey: .terminal) ?? false
    meta = try container.decodeIfPresent(ACPJSONValue.self, forKey: .meta)
  }
}

public struct ACPPromptCapabilities: Codable, Equatable, Sendable {
  public var image: Bool
  public var audio: Bool
  public var embeddedContext: Bool

  public init(image: Bool = false, audio: Bool = false, embeddedContext: Bool = false) {
    self.image = image
    self.audio = audio
    self.embeddedContext = embeddedContext
  }

  private enum CodingKeys: String, CodingKey {
    case image
    case audio
    case embeddedContext
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    image = try container.decodeIfPresent(Bool.self, forKey: .image) ?? false
    audio = try container.decodeIfPresent(Bool.self, forKey: .audio) ?? false
    embeddedContext = try container.decodeIfPresent(Bool.self, forKey: .embeddedContext) ?? false
  }
}

/// MCP transports beyond stdio that a v1 agent accepts (`McpCapabilities`).
public struct ACPMCPCapabilities: Codable, Equatable, Sendable {
  public var http: Bool
  public var sse: Bool

  public init(http: Bool = false, sse: Bool = false) {
    self.http = http
    self.sse = sse
  }

  private enum CodingKeys: String, CodingKey {
    case http
    case sse
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    http = container.decodeLenient(Bool.self, forKey: .http) ?? false
    sse = container.decodeLenient(Bool.self, forKey: .sse) ?? false
  }
}

/// Optional session methods a v1 agent supports (`SessionCapabilities`).
/// Each marker's presence advertises the matching method or parameter.
public struct ACPSessionCapabilities: Codable, Equatable, Sendable {
  public var list: ACPSupportMarker?
  public var resume: ACPSupportMarker?
  public var close: ACPSupportMarker?
  public var delete: ACPSupportMarker?
  public var additionalDirectories: ACPSupportMarker?
  public var systemPrompt: ACPSystemPromptCapabilities?
  public var meta: ACPJSONValue?

  public init(
    list: ACPSupportMarker? = nil,
    resume: ACPSupportMarker? = nil,
    close: ACPSupportMarker? = nil,
    delete: ACPSupportMarker? = nil,
    additionalDirectories: ACPSupportMarker? = nil,
    systemPrompt: ACPSystemPromptCapabilities? = nil,
    meta: ACPJSONValue? = nil
  ) {
    self.list = list
    self.resume = resume
    self.close = close
    self.delete = delete
    self.additionalDirectories = additionalDirectories
    self.systemPrompt = systemPrompt
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case list
    case resume
    case close
    case delete
    case additionalDirectories
    case systemPrompt
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    list = container.decodeLenient(ACPSupportMarker.self, forKey: .list)
    resume = container.decodeLenient(ACPSupportMarker.self, forKey: .resume)
    close = container.decodeLenient(ACPSupportMarker.self, forKey: .close)
    delete = container.decodeLenient(ACPSupportMarker.self, forKey: .delete)
    additionalDirectories = container.decodeLenient(ACPSupportMarker.self, forKey: .additionalDirectories)
    systemPrompt = container.decodeLenient(ACPSystemPromptCapabilities.self, forKey: .systemPrompt)
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }
}

public struct ACPAgentCapabilities: Codable, Equatable, Sendable {
  public var loadSession: Bool
  public var promptCapabilities: ACPPromptCapabilities
  public var mcpCapabilities: ACPMCPCapabilities
  public var sessionCapabilities: ACPSessionCapabilities
  public var meta: ACPJSONValue?

  public init(
    loadSession: Bool = false,
    promptCapabilities: ACPPromptCapabilities = ACPPromptCapabilities(),
    mcpCapabilities: ACPMCPCapabilities = ACPMCPCapabilities(),
    sessionCapabilities: ACPSessionCapabilities = ACPSessionCapabilities(),
    meta: ACPJSONValue? = nil
  ) {
    self.loadSession = loadSession
    self.promptCapabilities = promptCapabilities
    self.mcpCapabilities = mcpCapabilities
    self.sessionCapabilities = sessionCapabilities
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case loadSession
    case promptCapabilities
    case mcpCapabilities
    case sessionCapabilities
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    loadSession = container.decodeLenient(Bool.self, forKey: .loadSession) ?? false
    promptCapabilities =
      container.decodeLenient(ACPPromptCapabilities.self, forKey: .promptCapabilities)
      ?? ACPPromptCapabilities()
    mcpCapabilities =
      container.decodeLenient(ACPMCPCapabilities.self, forKey: .mcpCapabilities) ?? ACPMCPCapabilities()
    sessionCapabilities =
      container.decodeLenient(ACPSessionCapabilities.self, forKey: .sessionCapabilities)
      ?? ACPSessionCapabilities()
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }
}

public struct ACPImplementation: Codable, Equatable, Sendable {
  public var name: String
  public var title: String?
  public var version: String

  public init(name: String, version: String, title: String? = nil) {
    self.name = name
    self.version = version
    self.title = title
  }
}

public struct ACPAuthMethod: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var description: String?

  public init(id: String, name: String, description: String? = nil) {
    self.id = id
    self.name = name
    self.description = description
  }
}

// MARK: - initialize

public struct ACPInitializeRequest: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  public var clientCapabilities: ACPClientCapabilities
  public var clientInfo: ACPImplementation?
  public var meta: ACPJSONValue?

  public init(
    protocolVersion: Int = ACPProtocol.versionV1,
    clientCapabilities: ACPClientCapabilities = ACPClientCapabilities(),
    clientInfo: ACPImplementation? = nil,
    meta: ACPJSONValue? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.clientCapabilities = clientCapabilities
    self.clientInfo = clientInfo
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case clientCapabilities
    case clientInfo
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    clientCapabilities =
      try container.decodeIfPresent(ACPClientCapabilities.self, forKey: .clientCapabilities)
      ?? ACPClientCapabilities()
    clientInfo = try container.decodeIfPresent(ACPImplementation.self, forKey: .clientInfo)
    meta = try container.decodeIfPresent(ACPJSONValue.self, forKey: .meta)
  }
}

public struct ACPInitializeResponse: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  public var agentCapabilities: ACPAgentCapabilities
  public var authMethods: [ACPAuthMethod]
  public var agentInfo: ACPImplementation?
  public var meta: ACPJSONValue?

  public init(
    protocolVersion: Int = ACPProtocol.versionV1,
    agentCapabilities: ACPAgentCapabilities = ACPAgentCapabilities(),
    authMethods: [ACPAuthMethod] = [],
    agentInfo: ACPImplementation? = nil,
    meta: ACPJSONValue? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.agentCapabilities = agentCapabilities
    self.authMethods = authMethods
    self.agentInfo = agentInfo
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case agentCapabilities
    case authMethods
    case agentInfo
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    agentCapabilities =
      try container.decodeIfPresent(ACPAgentCapabilities.self, forKey: .agentCapabilities)
      ?? ACPAgentCapabilities()
    authMethods = try container.decodeIfPresent([ACPAuthMethod].self, forKey: .authMethods) ?? []
    agentInfo = try container.decodeIfPresent(ACPImplementation.self, forKey: .agentInfo)
    meta = try container.decodeIfPresent(ACPJSONValue.self, forKey: .meta)
  }
}

// MARK: - session/new

public struct ACPMCPServer: Codable, Equatable, Sendable {
  public var name: String
  public var command: String?
  public var args: [String]?
  public var env: [ACPEnvVariable]?
  public var type: String?
  public var url: String?

  public init(
    name: String,
    command: String? = nil,
    args: [String]? = nil,
    env: [ACPEnvVariable]? = nil,
    type: String? = nil,
    url: String? = nil
  ) {
    self.name = name
    self.command = command
    self.args = args
    self.env = env
    self.type = type
    self.url = url
  }
}

public struct ACPEnvVariable: Codable, Equatable, Sendable {
  public var name: String
  public var value: String

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }
}

public struct ACPNewSessionRequest: Codable, Equatable, Sendable {
  public var cwd: String
  public var mcpServers: [ACPMCPServer]
  /// Requires `sessionCapabilities.systemPrompt`.
  public var systemPrompt: ACPSystemPrompt?
  public var meta: ACPJSONValue?

  public init(
    cwd: String,
    mcpServers: [ACPMCPServer] = [],
    systemPrompt: ACPSystemPrompt? = nil,
    meta: ACPJSONValue? = nil
  ) {
    self.cwd = cwd
    self.mcpServers = mcpServers
    self.systemPrompt = systemPrompt
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case cwd
    case mcpServers
    case systemPrompt
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    cwd = try container.decode(String.self, forKey: .cwd)
    mcpServers = try container.decodeIfPresent([ACPMCPServer].self, forKey: .mcpServers) ?? []
    systemPrompt = try container.decodeIfPresent(ACPSystemPrompt.self, forKey: .systemPrompt)
    meta = try container.decodeIfPresent(ACPJSONValue.self, forKey: .meta)
  }
}

/// Params of v1 `session/load` (replays history) and `session/resume`
/// (reattaches without replay); both name an existing session.
public struct ACPLoadSessionRequest: Codable, Equatable, Sendable {
  public var sessionId: ACPSessionID
  public var cwd: String
  public var mcpServers: [ACPMCPServer]
  public var systemPrompt: ACPSystemPrompt?
  public var meta: ACPJSONValue?

  public init(
    sessionId: ACPSessionID,
    cwd: String,
    mcpServers: [ACPMCPServer] = [],
    systemPrompt: ACPSystemPrompt? = nil,
    meta: ACPJSONValue? = nil
  ) {
    self.sessionId = sessionId
    self.cwd = cwd
    self.mcpServers = mcpServers
    self.systemPrompt = systemPrompt
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case sessionId
    case cwd
    case mcpServers
    case systemPrompt
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionId = try container.decode(ACPSessionID.self, forKey: .sessionId)
    cwd = try container.decode(String.self, forKey: .cwd)
    mcpServers = try container.decodeIfPresent([ACPMCPServer].self, forKey: .mcpServers) ?? []
    systemPrompt = try container.decodeIfPresent(ACPSystemPrompt.self, forKey: .systemPrompt)
    meta = try container.decodeIfPresent(ACPJSONValue.self, forKey: .meta)
  }
}

/// Result of v1 `session/load` and `session/resume`.
public struct ACPLoadSessionResponse: Codable, Equatable, Sendable {
  public var models: ACPSessionModelState?
  public var configOptions: [ACPSessionConfigOption.V1Coding]?
  public var meta: ACPJSONValue?

  public init(
    models: ACPSessionModelState? = nil,
    configOptions: [ACPSessionConfigOption.V1Coding]? = nil,
    meta: ACPJSONValue? = nil
  ) {
    self.models = models
    self.configOptions = configOptions
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case models
    case configOptions
    case meta = "_meta"
  }
}

/// A model an agent can run a session with (the schema's `ModelInfo`).
public struct ACPModelInfo: Codable, Equatable, Sendable {
  public var modelId: String
  public var name: String
  public var description: String?

  public init(modelId: String, name: String, description: String? = nil) {
    self.modelId = modelId
    self.name = name
    self.description = description
  }
}

/// Session model state advertised in `session/new` (`SessionModelState`).
/// Its presence signals that the agent accepts `session/set_model`.
public struct ACPSessionModelState: Codable, Equatable, Sendable {
  public var availableModels: [ACPModelInfo]
  public var currentModelId: String

  public init(availableModels: [ACPModelInfo], currentModelId: String) {
    self.availableModels = availableModels
    self.currentModelId = currentModelId
  }
}

public struct ACPNewSessionResponse: Codable, Equatable, Sendable {
  public var sessionId: ACPSessionID
  public var models: ACPSessionModelState?
  /// The session's configuration options (v1 key names), when it has any.
  public var configOptions: [ACPSessionConfigOption.V1Coding]?
  public var meta: ACPJSONValue?

  public init(
    sessionId: ACPSessionID,
    models: ACPSessionModelState? = nil,
    configOptions: [ACPSessionConfigOption.V1Coding]? = nil,
    meta: ACPJSONValue? = nil
  ) {
    self.sessionId = sessionId
    self.models = models
    self.configOptions = configOptions
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case sessionId
    case models
    case configOptions
    case meta = "_meta"
  }
}

// MARK: - session/set_model

public struct ACPSetSessionModelRequest: Codable, Equatable, Sendable {
  public var sessionId: ACPSessionID
  public var modelId: String
  public var meta: ACPJSONValue?

  public init(sessionId: ACPSessionID, modelId: String, meta: ACPJSONValue? = nil) {
    self.sessionId = sessionId
    self.modelId = modelId
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case sessionId
    case modelId
    case meta = "_meta"
  }
}

// MARK: - session/prompt

public struct ACPPromptRequest: Codable, Equatable, Sendable {
  public var sessionId: ACPSessionID
  public var prompt: [ACPContentBlock]
  public var meta: ACPJSONValue?

  public init(sessionId: ACPSessionID, prompt: [ACPContentBlock], meta: ACPJSONValue? = nil) {
    self.sessionId = sessionId
    self.prompt = prompt
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case sessionId
    case prompt
    case meta = "_meta"
  }
}

public enum ACPStopReason: String, Codable, Sendable {
  case endTurn = "end_turn"
  case maxTokens = "max_tokens"
  case maxTurnRequests = "max_turn_requests"
  case refusal
  case cancelled
}

public struct ACPPromptResponse: Codable, Equatable, Sendable {
  public var stopReason: ACPStopReason
  public var meta: ACPJSONValue?

  public init(stopReason: ACPStopReason, meta: ACPJSONValue? = nil) {
    self.stopReason = stopReason
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case stopReason
    case meta = "_meta"
  }
}

// MARK: - session/cancel

public struct ACPCancelNotification: Codable, Equatable, Sendable {
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
