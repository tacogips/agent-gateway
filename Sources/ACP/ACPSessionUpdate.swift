import Foundation

/// `session/update` notification params.
public struct ACPSessionNotification: Codable, Equatable, Sendable {
  public var sessionId: ACPSessionID
  public var update: ACPSessionUpdate
  public var meta: ACPJSONValue?

  public init(sessionId: ACPSessionID, update: ACPSessionUpdate, meta: ACPJSONValue? = nil) {
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

public enum ACPToolKind: String, Codable, Sendable {
  case read
  case edit
  case delete
  case move
  case search
  case execute
  case think
  case fetch
  case switchMode = "switch_mode"
  case other
}

public enum ACPToolCallStatus: String, Codable, Sendable {
  case pending
  case inProgress = "in_progress"
  case completed
  case failed
}

/// File modification shown as a tool-call `diff` content item.
public struct ACPToolCallDiff: Codable, Equatable, Sendable {
  public var path: String
  public var oldText: String?
  public var newText: String

  public init(path: String, oldText: String? = nil, newText: String) {
    self.path = path
    self.oldText = oldText
    self.newText = newText
  }
}

public enum ACPToolCallContent: Codable, Equatable, Sendable {
  case content(ACPContentBlock)
  case diff(ACPToolCallDiff)
  /// Embedded terminal output (`terminalId` references a client terminal).
  case terminal(terminalId: String)
  /// Forward-compatible fallback carrying the raw JSON of an unknown type.
  case other(ACPJSONValue)

  private enum CodingKeys: String, CodingKey {
    case type
    case content
    case terminalId
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .type) {
    case "content":
      self = .content(try container.decode(ACPContentBlock.self, forKey: .content))
    case "diff":
      self = .diff(try ACPToolCallDiff(from: decoder))
    case "terminal":
      self = .terminal(terminalId: try container.decode(String.self, forKey: .terminalId))
    default:
      self = .other(try ACPJSONValue(from: decoder))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    if case .other(let value) = self {
      try value.encode(to: encoder)
      return
    }
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
    case .other:
      preconditionFailure("handled above")
    }
  }
}

/// File location a tool call touches, for client "follow along" features.
public struct ACPToolCallLocation: Codable, Equatable, Sendable {
  public var path: String
  public var line: Int?

  public init(path: String, line: Int? = nil) {
    self.path = path
    self.line = line
  }
}

public struct ACPToolCall: Codable, Equatable, Sendable {
  public var toolCallId: ACPToolCallID
  public var title: String
  public var kind: ACPToolKind?
  public var status: ACPToolCallStatus?
  public var content: [ACPToolCallContent]?
  public var locations: [ACPToolCallLocation]?
  public var rawInput: ACPJSONValue?
  public var rawOutput: ACPJSONValue?

  public init(
    toolCallId: ACPToolCallID,
    title: String,
    kind: ACPToolKind? = nil,
    status: ACPToolCallStatus? = nil,
    content: [ACPToolCallContent]? = nil,
    locations: [ACPToolCallLocation]? = nil,
    rawInput: ACPJSONValue? = nil,
    rawOutput: ACPJSONValue? = nil
  ) {
    self.toolCallId = toolCallId
    self.title = title
    self.kind = kind
    self.status = status
    self.content = content
    self.locations = locations
    self.rawInput = rawInput
    self.rawOutput = rawOutput
  }
}

public struct ACPToolCallUpdate: Codable, Equatable, Sendable {
  public var toolCallId: ACPToolCallID
  public var title: String?
  public var kind: ACPToolKind?
  public var status: ACPToolCallStatus?
  public var content: [ACPToolCallContent]?
  public var locations: [ACPToolCallLocation]?
  public var rawInput: ACPJSONValue?
  public var rawOutput: ACPJSONValue?

  public init(
    toolCallId: ACPToolCallID,
    title: String? = nil,
    kind: ACPToolKind? = nil,
    status: ACPToolCallStatus? = nil,
    content: [ACPToolCallContent]? = nil,
    locations: [ACPToolCallLocation]? = nil,
    rawInput: ACPJSONValue? = nil,
    rawOutput: ACPJSONValue? = nil
  ) {
    self.toolCallId = toolCallId
    self.title = title
    self.kind = kind
    self.status = status
    self.content = content
    self.locations = locations
    self.rawInput = rawInput
    self.rawOutput = rawOutput
  }
}

public struct ACPPlanEntry: Codable, Equatable, Sendable {
  public enum Priority: String, Codable, Sendable {
    case high, medium, low
  }
  public enum Status: String, Codable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
  }

  public var content: String
  public var priority: Priority
  public var status: Status

  public init(content: String, priority: Priority = .medium, status: Status = .pending) {
    self.content = content
    self.priority = priority
    self.status = status
  }
}

/// Streaming updates emitted during a prompt turn, discriminated by `sessionUpdate`.
public enum ACPSessionUpdate: Codable, Equatable, Sendable {
  case userMessageChunk(ACPContentBlock)
  case agentMessageChunk(ACPContentBlock)
  case agentThoughtChunk(ACPContentBlock)
  case toolCall(ACPToolCall)
  case toolCallUpdate(ACPToolCallUpdate)
  case plan([ACPPlanEntry])
  /// Forward-compatible fallback for update kinds this library does not
  /// model (e.g. `available_commands_update`); carries the raw JSON params.
  case other(ACPJSONValue)

  private enum CodingKeys: String, CodingKey {
    case sessionUpdate
    case content
    case entries
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .sessionUpdate)
    switch kind {
    case "user_message_chunk":
      self = .userMessageChunk(try container.decode(ACPContentBlock.self, forKey: .content))
    case "agent_message_chunk":
      self = .agentMessageChunk(try container.decode(ACPContentBlock.self, forKey: .content))
    case "agent_thought_chunk":
      self = .agentThoughtChunk(try container.decode(ACPContentBlock.self, forKey: .content))
    case "tool_call":
      self = .toolCall(try ACPToolCall(from: decoder))
    case "tool_call_update":
      self = .toolCallUpdate(try ACPToolCallUpdate(from: decoder))
    case "plan":
      self = .plan(try container.decode([ACPPlanEntry].self, forKey: .entries))
    default:
      self = .other(try ACPJSONValue(from: decoder))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    if case .other(let value) = self {
      try value.encode(to: encoder)
      return
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .userMessageChunk(let content):
      try container.encode("user_message_chunk", forKey: .sessionUpdate)
      try container.encode(content, forKey: .content)
    case .agentMessageChunk(let content):
      try container.encode("agent_message_chunk", forKey: .sessionUpdate)
      try container.encode(content, forKey: .content)
    case .agentThoughtChunk(let content):
      try container.encode("agent_thought_chunk", forKey: .sessionUpdate)
      try container.encode(content, forKey: .content)
    case .toolCall(let value):
      try container.encode("tool_call", forKey: .sessionUpdate)
      try value.encode(to: encoder)
    case .toolCallUpdate(let value):
      try container.encode("tool_call_update", forKey: .sessionUpdate)
      try value.encode(to: encoder)
    case .plan(let entries):
      try container.encode("plan", forKey: .sessionUpdate)
      try container.encode(entries, forKey: .entries)
    case .other:
      preconditionFailure("handled above")
    }
  }
}
