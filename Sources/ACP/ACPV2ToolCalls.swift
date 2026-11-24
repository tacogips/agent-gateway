import Foundation

// ACP v2 tool calls, display terminals, child sessions, and permission
// requests. In v2 a tool call is created by the first `tool_call_update`
// for its id; there is no separate `tool_call` variant.

/// Structured file changes plus optional renderable patch text (v2 `Diff`).
/// Replaces v1's `path`/`oldText`/`newText`.
public struct ACPV2Diff: Codable, Equatable, Sendable {
  public struct Change: Codable, Equatable, Sendable {
    /// `add`, `delete`, `modify`, `move`, `copy`, or an unknown operation.
    public var operation: String
    public var path: String
    /// Source path of a `move` or `copy`.
    public var oldPath: String?
    /// `text`, `binary`, `directory`, `symlink`, or an unknown type.
    public var fileType: String?
    public var mimeType: String?
    public var meta: ACPJSONValue?

    public init(
      operation: String,
      path: String,
      oldPath: String? = nil,
      fileType: String? = nil,
      mimeType: String? = nil,
      meta: ACPJSONValue? = nil
    ) {
      self.operation = operation
      self.path = path
      self.oldPath = oldPath
      self.fileType = fileType
      self.mimeType = mimeType
      self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
      case operation
      case path
      case oldPath
      case fileType
      case mimeType
      case meta = "_meta"
    }
  }

  public struct Patch: Codable, Equatable, Sendable {
    /// `git_patch` or an unknown format.
    public var format: String
    public var text: String

    public init(format: String = "git_patch", text: String) {
      self.format = format
      self.text = text
    }
  }

  /// Authoritative list of file-level operations; never empty.
  public var changes: [Change]
  /// Renderable text for some or all changes; absent for binary changes
  /// and similar cases without a useful text rendering.
  public var patch: Patch?
  public var meta: ACPJSONValue?

  public init(changes: [Change], patch: Patch? = nil, meta: ACPJSONValue? = nil) {
    self.changes = changes
    self.patch = patch
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case changes
    case patch
    case meta = "_meta"
  }
}

/// One content item of a tool call (v2 `ToolCallContent`).
public enum ACPV2ToolCallContent: Codable, Equatable, Sendable {
  case content(ACPContentBlock)
  case diff(ACPV2Diff)
  /// Reference to an agent-owned, display-only terminal.
  case terminal(terminalId: String)
  /// Link to another session the tool call operates on, such as a subagent.
  case session(sessionId: ACPSessionID)
  case other(ACPJSONValue)

  private enum CodingKeys: String, CodingKey {
    case type
    case content
    case terminalId
    case sessionId
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .type) {
    case "content": self = .content(try container.decode(ACPContentBlock.self, forKey: .content))
    case "diff": self = .diff(try ACPV2Diff(from: decoder))
    case "terminal": self = .terminal(terminalId: try container.decode(String.self, forKey: .terminalId))
    case "session": self = .session(sessionId: try container.decode(String.self, forKey: .sessionId))
    default: self = .other(try ACPJSONValue(from: decoder))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .content(let block):
      try container.encode("content", forKey: .type)
      try container.encode(block, forKey: .content)
    case .diff(let diff):
      try container.encode("diff", forKey: .type)
      try diff.encode(to: encoder)
    case .terminal(let terminalId):
      try container.encode("terminal", forKey: .type)
      try container.encode(terminalId, forKey: .terminalId)
    case .session(let sessionId):
      try container.encode("session", forKey: .type)
      try container.encode(sessionId, forKey: .sessionId)
    case .other(let value):
      try value.encode(to: encoder)
    }
  }
}

/// Tool-call upsert keyed by `toolCallId` (v2 `ToolCallUpdate`). The first
/// update for an id creates the tool call; later ones patch it. `kind` and
/// `status` are open strings (`status` adds `paused` and `cancelled`).
public struct ACPV2ToolCallUpdate: Codable, Equatable, Sendable {
  public var toolCallId: ACPToolCallID
  public var name: ACPPatch<String>
  public var title: ACPPatch<String>
  public var kind: ACPPatch<String>
  public var status: ACPPatch<String>
  /// Replaces the accumulated content, including earlier content chunks.
  public var content: ACPPatch<[ACPV2ToolCallContent]>
  public var locations: ACPPatch<[ACPToolCallLocation]>
  public var rawInput: ACPPatch<ACPJSONValue>
  public var rawOutput: ACPPatch<ACPJSONValue>
  /// While it advertises `cancel`, the client may send `tool_call/cancel`.
  public var capabilities: ACPPatch<ACPJSONValue>
  public var meta: ACPPatch<ACPJSONValue>

  public init(
    toolCallId: ACPToolCallID,
    name: ACPPatch<String> = .unchanged,
    title: ACPPatch<String> = .unchanged,
    kind: ACPPatch<String> = .unchanged,
    status: ACPPatch<String> = .unchanged,
    content: ACPPatch<[ACPV2ToolCallContent]> = .unchanged,
    locations: ACPPatch<[ACPToolCallLocation]> = .unchanged,
    rawInput: ACPPatch<ACPJSONValue> = .unchanged,
    rawOutput: ACPPatch<ACPJSONValue> = .unchanged,
    capabilities: ACPPatch<ACPJSONValue> = .unchanged,
    meta: ACPPatch<ACPJSONValue> = .unchanged
  ) {
    self.toolCallId = toolCallId
    self.name = name
    self.title = title
    self.kind = kind
    self.status = status
    self.content = content
    self.locations = locations
    self.rawInput = rawInput
    self.rawOutput = rawOutput
    self.capabilities = capabilities
    self.meta = meta
  }

  /// Whether this tool call currently advertises `capabilities.cancel`.
  public var advertisesCancel: Bool {
    guard let cancel = capabilities.value?["cancel"] else { return false }
    return cancel != .null
  }

  private enum CodingKeys: String, CodingKey {
    case toolCallId
    case name
    case title
    case kind
    case status
    case content
    case locations
    case rawInput
    case rawOutput
    case capabilities
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    toolCallId = try container.decode(ACPToolCallID.self, forKey: .toolCallId)
    name = container.decodePatch(String.self, forKey: .name)
    title = container.decodePatch(String.self, forKey: .title)
    kind = container.decodePatch(String.self, forKey: .kind)
    status = container.decodePatch(String.self, forKey: .status)
    content = container.decodePatchArray(ACPV2ToolCallContent.self, forKey: .content)
    locations = container.decodePatchArray(ACPToolCallLocation.self, forKey: .locations)
    rawInput = container.decodePatch(ACPJSONValue.self, forKey: .rawInput)
    rawOutput = container.decodePatch(ACPJSONValue.self, forKey: .rawOutput)
    capabilities = container.decodePatch(ACPJSONValue.self, forKey: .capabilities)
    meta = container.decodePatch(ACPJSONValue.self, forKey: .meta)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(toolCallId, forKey: .toolCallId)
    try container.encodePatch(name, forKey: .name)
    try container.encodePatch(title, forKey: .title)
    try container.encodePatch(kind, forKey: .kind)
    try container.encodePatch(status, forKey: .status)
    try container.encodePatch(content, forKey: .content)
    try container.encodePatch(locations, forKey: .locations)
    try container.encodePatch(rawInput, forKey: .rawInput)
    try container.encodePatch(rawOutput, forKey: .rawOutput)
    try container.encodePatch(capabilities, forKey: .capabilities)
    try container.encodePatch(meta, forKey: .meta)
  }
}

/// Appends one content item to a tool call (`ToolCallContentChunk`).
public struct ACPV2ToolCallContentChunk: Codable, Equatable, Sendable {
  public var toolCallId: ACPToolCallID
  public var content: ACPV2ToolCallContent
  public var meta: ACPJSONValue?

  public init(toolCallId: ACPToolCallID, content: ACPV2ToolCallContent, meta: ACPJSONValue? = nil) {
    self.toolCallId = toolCallId
    self.content = content
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case toolCallId
    case content
    case meta = "_meta"
  }
}

// MARK: - Display terminals

/// Upsert of an agent-owned, display-only terminal (`TerminalUpdate`).
public struct ACPV2TerminalUpdate: Codable, Equatable, Sendable {
  public struct Output: Codable, Equatable, Sendable {
    /// Base64 of the complete byte sequence to retain; replaces all
    /// previously stored bytes.
    public var data: String

    public init(data: String) {
      self.data = data
    }
  }

  public struct ExitStatus: Codable, Equatable, Sendable {
    public var exitCode: Int?
    public var signal: String?

    public init(exitCode: Int? = nil, signal: String? = nil) {
      self.exitCode = exitCode
      self.signal = signal
    }
  }

  public struct Size: Codable, Equatable, Sendable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
      self.cols = cols
      self.rows = rows
    }
  }

  public var terminalId: String
  public var command: ACPPatch<String>
  public var cwd: ACPPatch<String>
  public var output: ACPPatch<Output>
  /// A concrete value marks the terminal as exited.
  public var exitStatus: ACPPatch<ExitStatus>
  public var size: ACPPatch<Size>
  /// While it advertises `cancel`, the client may send `terminal/cancel`.
  public var capabilities: ACPPatch<ACPJSONValue>
  public var meta: ACPPatch<ACPJSONValue>

  public init(
    terminalId: String,
    command: ACPPatch<String> = .unchanged,
    cwd: ACPPatch<String> = .unchanged,
    output: ACPPatch<Output> = .unchanged,
    exitStatus: ACPPatch<ExitStatus> = .unchanged,
    size: ACPPatch<Size> = .unchanged,
    capabilities: ACPPatch<ACPJSONValue> = .unchanged,
    meta: ACPPatch<ACPJSONValue> = .unchanged
  ) {
    self.terminalId = terminalId
    self.command = command
    self.cwd = cwd
    self.output = output
    self.exitStatus = exitStatus
    self.size = size
    self.capabilities = capabilities
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case terminalId
    case command
    case cwd
    case output
    case exitStatus
    case size
    case capabilities
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    terminalId = try container.decode(String.self, forKey: .terminalId)
    command = container.decodePatch(String.self, forKey: .command)
    cwd = container.decodePatch(String.self, forKey: .cwd)
    output = container.decodePatch(Output.self, forKey: .output)
    exitStatus = container.decodePatch(ExitStatus.self, forKey: .exitStatus)
    size = container.decodePatch(Size.self, forKey: .size)
    capabilities = container.decodePatch(ACPJSONValue.self, forKey: .capabilities)
    meta = container.decodePatch(ACPJSONValue.self, forKey: .meta)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(terminalId, forKey: .terminalId)
    try container.encodePatch(command, forKey: .command)
    try container.encodePatch(cwd, forKey: .cwd)
    try container.encodePatch(output, forKey: .output)
    try container.encodePatch(exitStatus, forKey: .exitStatus)
    try container.encodePatch(size, forKey: .size)
    try container.encodePatch(capabilities, forKey: .capabilities)
    try container.encodePatch(meta, forKey: .meta)
  }
}

/// Appends bytes to a display terminal (`TerminalOutputChunk`). Each
/// chunk's `data` is independently base64-encoded: decode, then append.
public struct ACPV2TerminalOutputChunk: Codable, Equatable, Sendable {
  public var terminalId: String
  public var data: String
  public var meta: ACPJSONValue?

  public init(terminalId: String, data: String, meta: ACPJSONValue? = nil) {
    self.terminalId = terminalId
    self.data = data
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case terminalId
    case data
    case meta = "_meta"
  }
}

// MARK: - Child sessions

/// Announces a child session or patches its labels, directories,
/// capabilities, and mirrored work state (`SubagentUpdate`).
public struct ACPV2SubagentUpdate: Codable, Equatable, Sendable {
  /// The child session's id; its own updates arrive with this `sessionId`.
  public var sessionId: ACPSessionID
  public var title: ACPPatch<String>
  public var capabilities: ACPPatch<ACPJSONValue>
  public var state: ACPPatch<ACPV2StateUpdate>
  public var cwd: ACPPatch<String>
  public var additionalDirectories: ACPPatch<[String]>
  public var meta: ACPPatch<ACPJSONValue>

  public init(
    sessionId: ACPSessionID,
    title: ACPPatch<String> = .unchanged,
    capabilities: ACPPatch<ACPJSONValue> = .unchanged,
    state: ACPPatch<ACPV2StateUpdate> = .unchanged,
    cwd: ACPPatch<String> = .unchanged,
    additionalDirectories: ACPPatch<[String]> = .unchanged,
    meta: ACPPatch<ACPJSONValue> = .unchanged
  ) {
    self.sessionId = sessionId
    self.title = title
    self.capabilities = capabilities
    self.state = state
    self.cwd = cwd
    self.additionalDirectories = additionalDirectories
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case sessionId
    case title
    case capabilities
    case state
    case cwd
    case additionalDirectories
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionId = try container.decode(ACPSessionID.self, forKey: .sessionId)
    title = container.decodePatch(String.self, forKey: .title)
    capabilities = container.decodePatch(ACPJSONValue.self, forKey: .capabilities)
    state = container.decodePatch(ACPV2StateUpdate.self, forKey: .state)
    cwd = container.decodePatch(String.self, forKey: .cwd)
    additionalDirectories = container.decodePatch([String].self, forKey: .additionalDirectories)
    meta = container.decodePatch(ACPJSONValue.self, forKey: .meta)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sessionId, forKey: .sessionId)
    try container.encodePatch(title, forKey: .title)
    try container.encodePatch(capabilities, forKey: .capabilities)
    try container.encodePatch(state, forKey: .state)
    try container.encodePatch(cwd, forKey: .cwd)
    try container.encodePatch(additionalDirectories, forKey: .additionalDirectories)
    try container.encodePatch(meta, forKey: .meta)
  }
}

// MARK: - Permission requests

public struct ACPPermissionOption: Codable, Equatable, Sendable {
  public static let allowOnce = "allow_once"
  public static let allowAlways = "allow_always"
  public static let rejectOnce = "reject_once"
  public static let rejectAlways = "reject_always"

  public var optionId: String
  public var name: String
  /// `allow_once`, `allow_always`, `reject_once`, `reject_always`, or an
  /// unknown kind, which must never be read as approval.
  public var kind: String
  public var meta: ACPJSONValue?

  public init(optionId: String, name: String, kind: String, meta: ACPJSONValue? = nil) {
    self.optionId = optionId
    self.name = name
    self.kind = kind
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case optionId
    case name
    case kind
    case meta = "_meta"
  }
}

/// What a v2 permission request is about (`RequestPermissionSubject`).
public enum ACPV2PermissionSubject: Codable, Equatable, Sendable {
  /// Tool-call state, in the same upsert shape as `tool_call_update`.
  case toolCall(ACPV2ToolCallUpdate)
  /// A command the agent wants to execute itself.
  case command(command: String, cwd: String, toolCallId: ACPToolCallID?, terminalId: String?)
  case other(ACPJSONValue)

  private enum CodingKeys: String, CodingKey {
    case type
    case toolCall
    case command
    case cwd
    case toolCallId
    case terminalId
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .type) {
    case "tool_call":
      self = .toolCall(try container.decode(ACPV2ToolCallUpdate.self, forKey: .toolCall))
    case "command":
      self = .command(
        command: try container.decode(String.self, forKey: .command),
        cwd: try container.decode(String.self, forKey: .cwd),
        toolCallId: try container.decodeIfPresent(String.self, forKey: .toolCallId),
        terminalId: try container.decodeIfPresent(String.self, forKey: .terminalId)
      )
    default:
      self = .other(try ACPJSONValue(from: decoder))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .toolCall(let toolCall):
      try container.encode("tool_call", forKey: .type)
      try container.encode(toolCall, forKey: .toolCall)
    case .command(let command, let cwd, let toolCallId, let terminalId):
      try container.encode("command", forKey: .type)
      try container.encode(command, forKey: .command)
      try container.encode(cwd, forKey: .cwd)
      try container.encodeIfPresent(toolCallId, forKey: .toolCallId)
      try container.encodeIfPresent(terminalId, forKey: .terminalId)
    case .other(let value):
      try value.encode(to: encoder)
    }
  }
}

/// `session/request_permission` params in v2: prompt copy (`title`,
/// `description`) is separate from the optional `subject`.
public struct ACPV2RequestPermissionRequest: Codable, Equatable, Sendable {
  public var sessionId: ACPSessionID
  public var title: String
  public var description: String?
  public var subject: ACPV2PermissionSubject?
  /// At least one option.
  public var options: [ACPPermissionOption]
  public var meta: ACPJSONValue?

  public init(
    sessionId: ACPSessionID,
    title: String,
    description: String? = nil,
    subject: ACPV2PermissionSubject? = nil,
    options: [ACPPermissionOption],
    meta: ACPJSONValue? = nil
  ) {
    self.sessionId = sessionId
    self.title = title
    self.description = description
    self.subject = subject
    self.options = options
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case sessionId
    case title
    case description
    case subject
    case options
    case meta = "_meta"
  }
}

/// `session/request_permission` result (same shape in v1 and v2).
public struct ACPRequestPermissionResponse: Codable, Equatable, Sendable {
  public enum Outcome: Equatable, Sendable {
    /// The user dismissed the prompt, policy declined it, or the request
    /// was cancelled. The agent must not proceed with the operation.
    case cancelled
    /// The user picked this option. Not approval by itself: the agent
    /// matches `optionId` against the options it offered.
    case selected(optionId: String)
    case other(ACPJSONValue)
  }

  public var outcome: Outcome
  public var meta: ACPJSONValue?

  public init(outcome: Outcome, meta: ACPJSONValue? = nil) {
    self.outcome = outcome
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case outcome
    case meta = "_meta"
  }

  private enum OutcomeKeys: String, CodingKey {
    case outcome
    case optionId
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let nested = try container.nestedContainer(keyedBy: OutcomeKeys.self, forKey: .outcome)
    switch try nested.decode(String.self, forKey: .outcome) {
    case "cancelled": outcome = .cancelled
    case "selected": outcome = .selected(optionId: try nested.decode(String.self, forKey: .optionId))
    default: outcome = .other(try container.decode(ACPJSONValue.self, forKey: .outcome))
    }
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch outcome {
    case .cancelled:
      var nested = container.nestedContainer(keyedBy: OutcomeKeys.self, forKey: .outcome)
      try nested.encode("cancelled", forKey: .outcome)
    case .selected(let optionId):
      var nested = container.nestedContainer(keyedBy: OutcomeKeys.self, forKey: .outcome)
      try nested.encode("selected", forKey: .outcome)
      try nested.encode(optionId, forKey: .optionId)
    case .other(let value):
      try container.encode(value, forKey: .outcome)
    }
    try container.encodeIfPresent(meta, forKey: .meta)
  }
}
