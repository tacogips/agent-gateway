import Foundation

/// `session/update` notification params for ACP v2 (`UpdateSessionNotification`).
public struct ACPV2SessionNotification: Codable, Equatable, Sendable {
  public var sessionId: ACPSessionID
  public var update: ACPV2SessionUpdate
  /// Metadata about this one report (not stored entity state).
  public var meta: ACPJSONValue?

  public init(sessionId: ACPSessionID, update: ACPV2SessionUpdate, meta: ACPJSONValue? = nil) {
    self.sessionId = sessionId
    self.update = update
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case sessionId
    case update
    case meta = "_meta"
  }
}

// MARK: - Messages

/// One appended content block of a message (`ContentChunk`). In v2 every
/// chunk names the message it belongs to.
public struct ACPV2ContentChunk: Codable, Equatable, Sendable {
  public var messageId: ACPMessageID
  public var content: ACPContentBlock
  /// Chunk-scoped metadata; does not patch the message's metadata.
  public var meta: ACPJSONValue?

  public init(messageId: ACPMessageID, content: ACPContentBlock, meta: ACPJSONValue? = nil) {
    self.messageId = messageId
    self.content = content
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case messageId
    case content
    case meta = "_meta"
  }
}

/// Whole-message upsert keyed by `messageId` (`UserMessage`, `AgentMessage`,
/// `AgentThought`): omitted `content` leaves the stored content unchanged,
/// `null` or `[]` clears it, and an array replaces it, including content
/// accumulated from earlier chunks.
public struct ACPV2Message: Codable, Equatable, Sendable {
  public var messageId: ACPMessageID
  public var content: ACPPatch<[ACPContentBlock]>
  /// Key-level patch of the message's stored metadata.
  public var meta: ACPPatch<ACPJSONValue>

  public init(
    messageId: ACPMessageID,
    content: ACPPatch<[ACPContentBlock]> = .unchanged,
    meta: ACPPatch<ACPJSONValue> = .unchanged
  ) {
    self.messageId = messageId
    self.content = content
    self.meta = meta
  }

  /// A message whose whole content is `content`.
  public init(messageId: ACPMessageID, content: [ACPContentBlock]) {
    self.init(messageId: messageId, content: .set(content))
  }

  private enum CodingKeys: String, CodingKey {
    case messageId
    case content
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    messageId = try container.decode(ACPMessageID.self, forKey: .messageId)
    content = container.decodePatchArray(ACPContentBlock.self, forKey: .content)
    meta = container.decodePatch(ACPJSONValue.self, forKey: .meta)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(messageId, forKey: .messageId)
    try container.encodePatch(content, forKey: .content)
    try container.encodePatch(meta, forKey: .meta)
  }
}

// MARK: - State

/// Aggregate foreground activity of a session (`state_update.state`).
/// Open enum: unknown values are preserved and must not be read as `idle`.
public struct ACPV2SessionState: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  /// Foreground work is in progress.
  public static let running = ACPV2SessionState(rawValue: "running")
  /// No foreground work is active; background activity may continue.
  public static let idle = ACPV2SessionState(rawValue: "idle")
  /// Foreground work as a whole is blocked on user action.
  public static let requiresAction = ACPV2SessionState(rawValue: "requires_action")
  /// The agent cannot currently determine foreground activity.
  public static let unknown = ACPV2SessionState(rawValue: "unknown")

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Why foreground work stopped (`stopReason` on an idle `state_update`).
/// Open enum: v2 adds `error` to the v1 reasons and reserves `_`-prefixed
/// values for extensions.
public struct ACPV2StopReason: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let endTurn = ACPV2StopReason(rawValue: "end_turn")
  public static let maxTokens = ACPV2StopReason(rawValue: "max_tokens")
  public static let maxTurnRequests = ACPV2StopReason(rawValue: "max_turn_requests")
  public static let refusal = ACPV2StopReason(rawValue: "refusal")
  public static let cancelled = ACPV2StopReason(rawValue: "cancelled")
  /// Foreground work ended because something failed; see `ACPV2StateUpdate.error`.
  public static let error = ACPV2StopReason(rawValue: "error")

  public init(_ v1: ACPStopReason) {
    rawValue = v1.rawValue
  }

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Snapshot of a session's aggregate foreground activity (`StateUpdate`).
///
/// It is not an event for one prompt: repeats are idempotent, and an idle
/// snapshot on resume may carry the last stop reason without reporting a
/// new completion.
public struct ACPV2StateUpdate: Codable, Equatable, Sendable {
  public var state: ACPV2SessionState
  /// Present on idle snapshots that end foreground work.
  public var stopReason: ACPV2StopReason?
  /// The failure behind an `error` stop reason, as a JSON-RPC error object.
  public var error: ACPError?
  /// Work running independently of foreground work. `nil` means not
  /// reported (not "nothing is running"); `[]` means nothing is running.
  public var background: [ACPJSONValue]?
  public var meta: ACPJSONValue?
  /// Fields this library does not model (fields of custom stop reasons or
  /// future states), preserved for proxying.
  public var extraFields: [String: ACPJSONValue]

  public init(
    state: ACPV2SessionState,
    stopReason: ACPV2StopReason? = nil,
    error: ACPError? = nil,
    background: [ACPJSONValue]? = nil,
    meta: ACPJSONValue? = nil,
    extraFields: [String: ACPJSONValue] = [:]
  ) {
    self.state = state
    self.stopReason = stopReason
    self.error = error
    self.background = background
    self.meta = meta
    self.extraFields = extraFields
  }

  public static func running(meta: ACPJSONValue? = nil) -> ACPV2StateUpdate {
    ACPV2StateUpdate(state: .running, meta: meta)
  }

  public static func idle(
    stopReason: ACPV2StopReason?, error: ACPError? = nil, meta: ACPJSONValue? = nil
  ) -> ACPV2StateUpdate {
    ACPV2StateUpdate(state: .idle, stopReason: stopReason, error: error, meta: meta)
  }

  /// Whether this snapshot reports active foreground work. An unknown or
  /// unrecognized state is neither active nor idle.
  public var isActive: Bool {
    state == .running || state == .requiresAction
  }

  private static let modeledKeys: Set<String> = [
    "sessionUpdate", "state", "stopReason", "error", "background", "_meta"
  ]

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: ACPDynamicKey.self)
    state = try container.decode(ACPV2SessionState.self, forKey: ACPDynamicKey("state"))
    stopReason = container.decodeLenient(ACPV2StopReason.self, forKey: ACPDynamicKey("stopReason"))
    error = container.decodeLenient(ACPError.self, forKey: ACPDynamicKey("error"))
    background = container.decodeLenient([ACPJSONValue].self, forKey: ACPDynamicKey("background"))
    meta = container.decodeLenient(ACPJSONValue.self, forKey: ACPDynamicKey("_meta"))
    var extra: [String: ACPJSONValue] = [:]
    for key in container.allKeys where !Self.modeledKeys.contains(key.stringValue) {
      extra[key.stringValue] = try? container.decode(ACPJSONValue.self, forKey: key)
    }
    extraFields = extra
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: ACPDynamicKey.self)
    for (key, value) in extraFields where !Self.modeledKeys.contains(key) {
      try container.encode(value, forKey: ACPDynamicKey(key))
    }
    try container.encode(state, forKey: ACPDynamicKey("state"))
    try container.encodeIfPresent(stopReason, forKey: ACPDynamicKey("stopReason"))
    try container.encodeIfPresent(error, forKey: ACPDynamicKey("error"))
    try container.encodeIfPresent(background, forKey: ACPDynamicKey("background"))
    try container.encodeIfPresent(meta, forKey: ACPDynamicKey("_meta"))
  }
}

// MARK: - Session metadata, usage, notices

public struct ACPV2SessionInfoUpdate: Codable, Equatable, Sendable {
  public var title: ACPPatch<String>
  public var updatedAt: ACPPatch<String>
  public var meta: ACPPatch<ACPJSONValue>

  public init(
    title: ACPPatch<String> = .unchanged,
    updatedAt: ACPPatch<String> = .unchanged,
    meta: ACPPatch<ACPJSONValue> = .unchanged
  ) {
    self.title = title
    self.updatedAt = updatedAt
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case title
    case updatedAt
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = container.decodePatch(String.self, forKey: .title)
    updatedAt = container.decodePatch(String.self, forKey: .updatedAt)
    meta = container.decodePatch(ACPJSONValue.self, forKey: .meta)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodePatch(title, forKey: .title)
    try container.encodePatch(updatedAt, forKey: .updatedAt)
    try container.encodePatch(meta, forKey: .meta)
  }
}

/// Cumulative session cost (`Cost`): `currency` is an ISO 4217 code or
/// another unit such as `"credits"`.
public struct ACPCost: Codable, Equatable, Sendable {
  public var amount: Double
  public var currency: String

  public init(amount: Double, currency: String) {
    self.amount = amount
    self.currency = currency
  }
}

/// Current context-window usage and cumulative cost (`UsageUpdate`).
public struct ACPV2UsageUpdate: Codable, Equatable, Sendable {
  /// Tokens currently in the session context.
  public var used: Int
  /// Size of the context window in tokens.
  public var size: Int
  public var cost: ACPPatch<ACPCost>
  public var meta: ACPPatch<ACPJSONValue>

  public init(
    used: Int, size: Int, cost: ACPPatch<ACPCost> = .unchanged, meta: ACPPatch<ACPJSONValue> = .unchanged
  ) {
    self.used = used
    self.size = size
    self.cost = cost
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case used
    case size
    case cost
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    used = try container.decode(Int.self, forKey: .used)
    size = try container.decode(Int.self, forKey: .size)
    cost = container.decodePatch(ACPCost.self, forKey: .cost)
    meta = container.decodePatch(ACPJSONValue.self, forKey: .meta)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(used, forKey: .used)
    try container.encode(size, forKey: .size)
    try container.encodePatch(cost, forKey: .cost)
    try container.encodePatch(meta, forKey: .meta)
  }
}

/// A live, user-facing notice (`Notice`). Not part of session history and
/// never required for protocol correctness.
public struct ACPV2Notice: Codable, Equatable, Sendable {
  /// `info`, `warning`, `error`, or an unknown severity.
  public var severity: String
  public var title: String
  public var description: String?
  public var meta: ACPJSONValue?

  public init(severity: String, title: String, description: String? = nil, meta: ACPJSONValue? = nil) {
    self.severity = severity
    self.title = title
    self.description = description
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case severity
    case title
    case description
    case meta = "_meta"
  }
}

// MARK: - Plans

/// A plan identified by `planId` (`PlanUpdateContent`). Each update
/// replaces the whole plan with that id.
public enum ACPV2Plan: Codable, Equatable, Sendable {
  case items(planId: String, entries: [ACPV2PlanEntry])
  case markdown(planId: String, content: String, path: String?)
  /// A custom or future plan type, preserved as raw JSON.
  case other(ACPJSONValue)

  public var planId: String? {
    switch self {
    case .items(let planId, _): planId
    case .markdown(let planId, _, _): planId
    case .other(let value): value["planId"]?.stringValue
    }
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case planId
    case entries
    case content
    case path
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .type) {
    case "items":
      self = .items(
        planId: try container.decode(String.self, forKey: .planId),
        entries: try container.decode([ACPV2PlanEntry].self, forKey: .entries)
      )
    case "markdown":
      self = .markdown(
        planId: try container.decode(String.self, forKey: .planId),
        content: try container.decode(String.self, forKey: .content),
        path: try container.decodeIfPresent(String.self, forKey: .path)
      )
    default:
      self = .other(try ACPJSONValue(from: decoder))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .items(let planId, let entries):
      try container.encode("items", forKey: .type)
      try container.encode(planId, forKey: .planId)
      try container.encode(entries, forKey: .entries)
    case .markdown(let planId, let content, let path):
      try container.encode("markdown", forKey: .type)
      try container.encode(planId, forKey: .planId)
      try container.encode(content, forKey: .content)
      try container.encodeIfPresent(path, forKey: .path)
    case .other(let value):
      try value.encode(to: encoder)
    }
  }
}

/// One checklist entry of an `items` plan. Priority and status are open
/// strings in v2 (`status` adds `cancelled`).
public struct ACPV2PlanEntry: Codable, Equatable, Sendable {
  public var content: String
  public var priority: String
  public var status: String
  public var meta: ACPJSONValue?

  public init(content: String, priority: String = "medium", status: String = "pending", meta: ACPJSONValue? = nil) {
    self.content = content
    self.priority = priority
    self.status = status
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case content
    case priority
    case status
    case meta = "_meta"
  }
}

// MARK: - SessionUpdate

/// Updates carried by ACP v2 `session/update`, discriminated by `sessionUpdate`.
///
/// Message, tool-call, and terminal updates are upserts keyed by entity id;
/// chunks append. Variants this library does not model, including custom
/// (`_`-prefixed) and future ones, arrive as `.other` with their raw payload.
public enum ACPV2SessionUpdate: Codable, Equatable, Sendable {
  case userMessageChunk(ACPV2ContentChunk)
  case userMessage(ACPV2Message)
  case agentMessageChunk(ACPV2ContentChunk)
  case agentMessage(ACPV2Message)
  case agentThoughtChunk(ACPV2ContentChunk)
  case agentThought(ACPV2Message)
  case stateUpdate(ACPV2StateUpdate)
  case toolCallUpdate(ACPV2ToolCallUpdate)
  case toolCallContentChunk(ACPV2ToolCallContentChunk)
  case terminalUpdate(ACPV2TerminalUpdate)
  case terminalOutputChunk(ACPV2TerminalOutputChunk)
  case planUpdate(ACPV2Plan)
  case planRemoved(planId: String)
  /// Complete replacement of the session's command list.
  case availableCommandsUpdate([ACPV2AvailableCommand])
  /// Complete replacement of the session's config options.
  case configOptionUpdate([ACPSessionConfigOption])
  case sessionInfoUpdate(ACPV2SessionInfoUpdate)
  case usageUpdate(ACPV2UsageUpdate)
  case notice(ACPV2Notice)
  /// Marks the end of a history replay requested by `session/resume`.
  case replayComplete
  /// Announces or patches a child session. Requires no client capability
  /// in v2, so clients must register the child rather than drop its traffic.
  case subagentUpdate(ACPV2SubagentUpdate)
  case other(ACPJSONValue)

  /// The wire `sessionUpdate` discriminator.
  public var kind: String {
    switch self {
    case .userMessageChunk: "user_message_chunk"
    case .userMessage: "user_message"
    case .agentMessageChunk: "agent_message_chunk"
    case .agentMessage: "agent_message"
    case .agentThoughtChunk: "agent_thought_chunk"
    case .agentThought: "agent_thought"
    case .stateUpdate: "state_update"
    case .toolCallUpdate: "tool_call_update"
    case .toolCallContentChunk: "tool_call_content_chunk"
    case .terminalUpdate: "terminal_update"
    case .terminalOutputChunk: "terminal_output_chunk"
    case .planUpdate: "plan_update"
    case .planRemoved: "plan_removed"
    case .availableCommandsUpdate: "available_commands_update"
    case .configOptionUpdate: "config_option_update"
    case .sessionInfoUpdate: "session_info_update"
    case .usageUpdate: "usage_update"
    case .notice: "notice"
    case .replayComplete: "replay_complete"
    case .subagentUpdate: "subagent_update"
    case .other(let value): value["sessionUpdate"]?.stringValue ?? ""
    }
  }

  private enum CodingKeys: String, CodingKey {
    case sessionUpdate
    case plan
    case planId
    case availableCommands
    case configOptions
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .sessionUpdate) {
    case "user_message_chunk": self = .userMessageChunk(try ACPV2ContentChunk(from: decoder))
    case "user_message": self = .userMessage(try ACPV2Message(from: decoder))
    case "agent_message_chunk": self = .agentMessageChunk(try ACPV2ContentChunk(from: decoder))
    case "agent_message": self = .agentMessage(try ACPV2Message(from: decoder))
    case "agent_thought_chunk": self = .agentThoughtChunk(try ACPV2ContentChunk(from: decoder))
    case "agent_thought": self = .agentThought(try ACPV2Message(from: decoder))
    case "state_update": self = .stateUpdate(try ACPV2StateUpdate(from: decoder))
    case "tool_call_update": self = .toolCallUpdate(try ACPV2ToolCallUpdate(from: decoder))
    case "tool_call_content_chunk": self = .toolCallContentChunk(try ACPV2ToolCallContentChunk(from: decoder))
    case "terminal_update": self = .terminalUpdate(try ACPV2TerminalUpdate(from: decoder))
    case "terminal_output_chunk": self = .terminalOutputChunk(try ACPV2TerminalOutputChunk(from: decoder))
    case "plan_update": self = .planUpdate(try container.decode(ACPV2Plan.self, forKey: .plan))
    case "plan_removed": self = .planRemoved(planId: try container.decode(String.self, forKey: .planId))
    case "available_commands_update":
      self = .availableCommandsUpdate(
        container.decodeLenientArray(ACPV2AvailableCommand.self, forKey: .availableCommands) ?? []
      )
    case "config_option_update":
      self = .configOptionUpdate(
        container.decodeLenientArray(ACPSessionConfigOption.self, forKey: .configOptions) ?? []
      )
    case "session_info_update": self = .sessionInfoUpdate(try ACPV2SessionInfoUpdate(from: decoder))
    case "usage_update": self = .usageUpdate(try ACPV2UsageUpdate(from: decoder))
    case "notice": self = .notice(try ACPV2Notice(from: decoder))
    case "replay_complete": self = .replayComplete
    case "subagent_update": self = .subagentUpdate(try ACPV2SubagentUpdate(from: decoder))
    default: self = .other(try ACPJSONValue(from: decoder))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    if case .other(let value) = self {
      try value.encode(to: encoder)
      return
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .sessionUpdate)
    switch self {
    case .userMessageChunk(let chunk), .agentMessageChunk(let chunk), .agentThoughtChunk(let chunk):
      try chunk.encode(to: encoder)
    case .userMessage(let message), .agentMessage(let message), .agentThought(let message):
      try message.encode(to: encoder)
    case .stateUpdate(let state): try state.encode(to: encoder)
    case .toolCallUpdate(let update): try update.encode(to: encoder)
    case .toolCallContentChunk(let chunk): try chunk.encode(to: encoder)
    case .terminalUpdate(let update): try update.encode(to: encoder)
    case .terminalOutputChunk(let chunk): try chunk.encode(to: encoder)
    case .planUpdate(let plan): try container.encode(plan, forKey: .plan)
    case .planRemoved(let planId): try container.encode(planId, forKey: .planId)
    case .availableCommandsUpdate(let commands): try container.encode(commands, forKey: .availableCommands)
    case .configOptionUpdate(let options): try container.encode(options, forKey: .configOptions)
    case .sessionInfoUpdate(let info): try info.encode(to: encoder)
    case .usageUpdate(let usage): try usage.encode(to: encoder)
    case .notice(let notice): try notice.encode(to: encoder)
    case .subagentUpdate(let update): try update.encode(to: encoder)
    case .replayComplete: break
    case .other: preconditionFailure("handled above")
    }
  }
}
