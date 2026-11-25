import ACP
import AgentGateway
import Foundation

/// What one vendor event says about a tool invocation.
///
/// Every field except the id is optional: a vendor reports a tool call
/// across several events (announced, input complete, finished), and each
/// event carries only what that vendor line contained. Consumers merge
/// events with the same `toolCallId`.
public struct GatewayToolCallEvent: Equatable, Sendable {
  /// One file a tool call changed, as the vendor reported it.
  public struct FileChange: Equatable, Sendable {
    public var path: String
    /// ACP diff operation: `add`, `delete`, or `modify`.
    public var operation: String

    public init(path: String, operation: String) {
      self.path = path
      self.operation = operation
    }
  }

  /// The vendor's own id for the call. Unique within one vendor execution
  /// only (codex numbers its items from zero on every run).
  public var toolCallId: String
  /// The vendor's tool name (`Bash`, `mcp_tool_call` tool, ...).
  public var name: String?
  public var title: String?
  public var kind: ACPToolKind?
  public var status: ACPToolCallStatus?
  public var rawInput: ACPJSONValue?
  public var rawOutput: ACPJSONValue?
  /// Textual output of the call, when the vendor reported text.
  public var outputText: String?
  public var locations: [ACPToolCallLocation]?
  public var fileChanges: [FileChange]?

  public init(
    toolCallId: String,
    name: String? = nil,
    title: String? = nil,
    kind: ACPToolKind? = nil,
    status: ACPToolCallStatus? = nil,
    rawInput: ACPJSONValue? = nil,
    rawOutput: ACPJSONValue? = nil,
    outputText: String? = nil,
    locations: [ACPToolCallLocation]? = nil,
    fileChanges: [FileChange]? = nil
  ) {
    self.toolCallId = toolCallId
    self.name = name
    self.title = title
    self.kind = kind
    self.status = status
    self.rawInput = rawInput
    self.rawOutput = rawOutput
    self.outputText = outputText
    self.locations = locations
    self.fileChanges = fileChanges
  }
}

/// A vendor's complete todo list at one point in time.
public struct GatewayPlanEvent: Equatable, Sendable {
  /// The vendor's id for the list, when it has one (codex `todo_list`
  /// item id). Unique within one vendor execution only.
  public var planId: String?
  public var entries: [ACPPlanEntry]

  public init(planId: String? = nil, entries: [ACPPlanEntry]) {
    self.planId = planId
    self.entries = entries
  }
}

/// Context-window and cost facts a vendor event reported. Vendors split
/// them across events, so every field is optional.
public struct GatewayContextUsage: Equatable, Sendable {
  /// Tokens in the model's context after its latest call.
  public var usedTokens: Int?
  /// The model that call ran on.
  public var model: String?
  /// Context window size in tokens, by model.
  public var windowSizes: [String: Int]
  /// Cost of this vendor execution in US dollars.
  public var costUSD: Double?

  public init(
    usedTokens: Int? = nil, model: String? = nil, windowSizes: [String: Int] = [:], costUSD: Double? = nil
  ) {
    self.usedTokens = usedTokens
    self.model = model
    self.windowSizes = windowSizes
    self.costUSD = costUSD
  }
}

/// Tool-call progress as the stream bridge reports it: the first chunk for
/// an id (`isNew`) carries everything known, later ones only what changed.
struct GatewayToolCallChunk: Equatable, Sendable {
  var isNew: Bool
  /// Session-unique id: the turn scope followed by the vendor's id.
  var toolCallId: ACPToolCallID
  var name: String?
  var title: String?
  var kind: ACPToolKind?
  var status: ACPToolCallStatus?
  var rawInput: ACPJSONValue?
  var rawOutput: ACPJSONValue?
  var outputText: String?
  var locations: [ACPToolCallLocation]?
  var fileChanges: [GatewayToolCallEvent.FileChange]?

  /// Whether the chunk carries anything besides its id.
  var isEmpty: Bool {
    name == nil && title == nil && kind == nil && status == nil && rawInput == nil && rawOutput == nil
      && outputText == nil && locations == nil && fileChanges == nil
  }
}

/// The complete current plan with a session-unique id.
struct GatewayPlanChunk: Equatable, Sendable {
  var planId: String
  var entries: [ACPPlanEntry]
}

/// Everything known about usage at one point of a turn.
struct GatewayUsageChunk: Equatable, Sendable {
  var tokens: GatewayUsage?
  var contextUsed: Int?
  var contextSize: Int?
  /// Cost of this turn's vendor execution so far.
  var costUSD: Double?
}

// MARK: - ACP updates

/// `planId` of a vendor todo list that has no id of its own.
let gatewayDefaultPlanId = "plan"

extension GatewayToolCallChunk {
  private var v1Content: [ACPToolCallContent]? {
    outputText.map { [.content(.text($0))] }
  }

  /// The v1 update: `tool_call` for a new call, else `tool_call_update`.
  var v1Update: ACPSessionUpdate {
    if isNew {
      return .toolCall(ACPToolCall(
        toolCallId: toolCallId, title: title ?? name ?? "Tool call", kind: kind, status: status,
        content: v1Content, locations: locations, rawInput: rawInput, rawOutput: rawOutput, name: name
      ))
    }
    return .toolCallUpdate(ACPToolCallUpdate(
      toolCallId: toolCallId, title: title, kind: kind, status: status,
      content: v1Content, locations: locations, rawInput: rawInput, rawOutput: rawOutput, name: name
    ))
  }

  /// The v2 upsert. File changes with absolute paths become a `diff`
  /// content item (v2 diffs need no file text).
  var v2Update: ACPV2ToolCallUpdate {
    var content: [ACPV2ToolCallContent] = []
    if let outputText {
      content.append(.content(.text(outputText)))
    }
    let changes = (fileChanges ?? [])
      .filter { $0.path.hasPrefix("/") }
      .map { ACPV2Diff.Change(operation: $0.operation, path: $0.path) }
    if !changes.isEmpty {
      content.append(.diff(ACPV2Diff(changes: changes)))
    }
    func patch<Value>(_ value: Value?) -> ACPPatch<Value> {
      value.map { .set($0) } ?? .unchanged
    }
    return ACPV2ToolCallUpdate(
      toolCallId: toolCallId,
      name: patch(name),
      title: isNew ? .set(title ?? name ?? "Tool call") : patch(title),
      kind: patch(kind?.rawValue),
      status: patch(status?.rawValue),
      content: content.isEmpty ? .unchanged : .set(content),
      locations: patch(locations),
      rawInput: patch(rawInput),
      rawOutput: patch(rawOutput)
    )
  }
}

extension GatewayPlanChunk {
  var v2Update: ACPV2SessionUpdate {
    .planUpdate(.items(
      planId: planId,
      entries: entries.map {
        ACPV2PlanEntry(content: $0.content, priority: $0.priority.rawValue, status: $0.status.rawValue)
      }
    ))
  }
}

extension GatewayUsageChunk {
  /// Token counts for the gateway's `_meta` extension object.
  private func meta(key: String) -> ACPJSONValue? {
    var counts: [String: ACPJSONValue] = [:]
    if let input = tokens?.inputTokens { counts["inputTokens"] = .integer(input) }
    if let output = tokens?.outputTokens { counts["outputTokens"] = .integer(output) }
    if let total = tokens?.totalTokens { counts["totalTokens"] = .integer(total) }
    return counts.isEmpty ? nil : .object([key: .object(counts)])
  }

  /// Session-cumulative cost: earlier turns plus this one.
  private func cost(priorCostUSD: Double) -> ACPCost? {
    costUSD.map { ACPCost(amount: priorCostUSD + $0, currency: "USD") }
  }

  /// The v1 `usage_update`, or nil while the context window is unknown:
  /// ACP requires both `used` and `size`. The v1 library does not model
  /// this update, so it travels as raw JSON.
  func v1Update(priorCostUSD: Double) -> ACPSessionUpdate? {
    guard let contextUsed, let contextSize else { return nil }
    var update: [String: ACPJSONValue] = [
      "sessionUpdate": .string("usage_update"),
      "used": .integer(contextUsed),
      "size": .integer(contextSize)
    ]
    if let cost = cost(priorCostUSD: priorCostUSD) {
      update["cost"] = .object(["amount": .number(cost.amount), "currency": .string(cost.currency)])
    }
    if let meta = meta(key: GatewayACPMetaKey.v1) {
      update["_meta"] = meta
    }
    return .other(.object(update))
  }

  /// The v2 `usage_update`, or nil while the context window is unknown.
  func v2Update(priorCostUSD: Double) -> ACPV2SessionUpdate? {
    guard let contextUsed, let contextSize else { return nil }
    return .usageUpdate(ACPV2UsageUpdate(
      used: contextUsed,
      size: contextSize,
      cost: cost(priorCostUSD: priorCostUSD).map { .set($0) } ?? .unchanged,
      meta: meta(key: GatewayACPMetaKey.v2).map { .set($0) } ?? .unchanged
    ))
  }
}
