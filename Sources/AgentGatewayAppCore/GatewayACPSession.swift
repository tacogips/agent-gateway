import ACP
import AgentGateway
import Foundation

/// One retained conversation message of a gateway session, kept so
/// `session/load` (v1) and `session/resume` with replay (v2) can report
/// history, and so idempotency keys stay tied to their user message.
struct GatewayHistoryMessage: Equatable, Sendable {
  enum Role: Equatable, Sendable {
    case user
    case agent
    case thought
  }

  var role: Role
  var messageId: ACPMessageID
  var content: [ACPContentBlock]
}

/// A v2 prompt received while foreground work was active: it is inserted,
/// in arrival order, when that work ends. Its `session/prompt` response
/// stays pending until then.
final class GatewayHeldPrompt: @unchecked Sendable {
  let id = UUID()
  let prompt: [ACPContentBlock]
  let idempotencyKey: String?
  private let lock = NSLock()
  private var outcome: Result<ACPMessageID, ACPError>?
  private var waiters: [CheckedContinuation<Result<ACPMessageID, ACPError>, Never>] = []

  init(prompt: [ACPContentBlock], idempotencyKey: String?) {
    self.prompt = prompt
    self.idempotencyKey = idempotencyKey
  }

  /// Settles the prompt once: inserted (its `messageId`) or dropped.
  func resolve(_ result: Result<ACPMessageID, ACPError>) {
    let pending = lock.withLock { () -> [CheckedContinuation<Result<ACPMessageID, ACPError>, Never>] in
      guard outcome == nil else { return [] }
      outcome = result
      defer { waiters.removeAll() }
      return waiters
    }
    for waiter in pending {
      waiter.resume(returning: result)
    }
  }

  /// Suspends until the prompt is inserted or dropped.
  func wait() async -> Result<ACPMessageID, ACPError> {
    await withCheckedContinuation { continuation in
      let settled = lock.withLock { () -> Result<ACPMessageID, ACPError>? in
        if let outcome { return outcome }
        waiters.append(continuation)
        return nil
      }
      if let settled {
        continuation.resume(returning: settled)
      }
    }
  }
}

/// Foreground work of a v2 session: one vendor execution started by an
/// inserted prompt.
struct GatewayForegroundTurn {
  var task: Task<Void, Never>
  var agentMessageId: ACPMessageID
  var thoughtMessageId: ACPMessageID
  var cancelRequested = false
  /// Text streamed so far, kept so a resume replay can cut the in-progress
  /// message at the current point and history can retain it afterwards.
  var agentText = ""
  var thoughtText = ""
  /// Callers (`session/close`, `session/delete`) waiting for this work to
  /// end and its idle update to be sent.
  var endWaiters: [CheckedContinuation<Void, Never>] = []
}

/// Everything the gateway keeps for one ACP session.
struct GatewaySession {
  var sessionId: ACPSessionID
  var cwd: String
  var configuration: GatewayAgentDefaults
  /// System prompt text supplied through the standard `systemPrompt`
  /// parameter (`append` mode), combined with the configured one.
  var clientSystemPrompt: String?
  var vendorSessionId: String?
  var title: String?
  var updatedAt: Date
  var history: [GatewayHistoryMessage] = []
  /// Idempotency keys of inserted prompts, by key, to their `messageId`.
  var promptKeys: [String: ACPMessageID] = [:]
  /// Models advertised for this session; empty when the vendor has no listing.
  var availableModels: [ACPModelInfo] = []

  /// Whether the session is active on the connection: created or resumed
  /// and not closed since. Closed sessions stay listed and resumable.
  var isActive = true
  var isClosing = false
  /// Where v2 updates for the session go while it is active.
  var connection: ACPAgentSideConnection?
  var turn: GatewayForegroundTurn?
  var heldPrompts: [GatewayHeldPrompt] = []

  // v1 prompt bookkeeping: the request stays pending for the whole turn.
  var activeTask: Task<GatewayExecuteResult, any Error>?
  var cancelRequested = false

  var info: ACPSessionInfo {
    ACPSessionInfo(
      sessionId: sessionId, cwd: cwd, title: title, updatedAt: gatewayTimestamp(updatedAt)
    )
  }

  /// The system prompt handed to the vendor: the configured prompt
  /// followed by the client-appended one.
  var effectiveSystemPrompt: String? {
    let parts = [configuration.systemPrompt, clientSystemPrompt].compactMap { $0 }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
  }

  /// The session's config options: a `model` selector when the vendor can
  /// list models. Vendors without a listing advertise none.
  var configOptions: [ACPSessionConfigOption] {
    guard !availableModels.isEmpty, let current = configuration.model else { return [] }
    var options = availableModels.map {
      ACPSessionConfigOption.SelectOption(value: $0.modelId, name: $0.name, description: $0.description)
    }
    if !options.contains(where: { $0.value == current }) {
      options.insert(ACPSessionConfigOption.SelectOption(value: current, name: current), at: 0)
    }
    return [
      ACPSessionConfigOption(
        configId: gatewayModelConfigId,
        name: "Model",
        category: ACPSessionConfigOption.categoryModel,
        kind: .select(currentValue: current, options: .ungrouped(options))
      )
    ]
  }

  /// Records a retained message and refreshes activity metadata. Returns
  /// true when this message gave the session its title.
  @discardableResult
  mutating func retain(_ message: GatewayHistoryMessage, now: Date = Date()) -> Bool {
    history.append(message)
    updatedAt = now
    guard title == nil, message.role == .user,
          let derived = gatewaySessionTitle(message.content) else { return false }
    title = derived
    return true
  }
}

/// `configId` of the gateway's model selector.
let gatewayModelConfigId = "model"

/// Page size of `session/list`.
let gatewaySessionListPageSize = 50

func gatewayTimestamp(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.string(from: date)
}

/// A plain-text session title from the first text of the first prompt.
func gatewaySessionTitle(_ content: [ACPContentBlock]) -> String? {
  for block in content {
    guard case .text(let text) = block else { continue }
    let line = text.text
      .split(whereSeparator: \.isNewline).first
      .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    guard !line.isEmpty else { continue }
    return line.count > 80 ? String(line.prefix(79)) + "…" : line
  }
  return nil
}

func gatewayNewMessageId() -> ACPMessageID {
  "msg-" + UUID().uuidString.lowercased()
}

/// Paths are compared after dropping a trailing separator, as ACP allows.
func gatewayNormalizedPath(_ path: String) -> String {
  guard path.count > 1, path.hasSuffix("/") else { return path }
  return String(path.dropLast())
}

/// Text and images a prompt contributes to a vendor execution.
struct GatewayPromptInput: Equatable, Sendable {
  var text: String
  var images: [GatewayImageInput]
}

/// Validates prompt content against what the gateway advertises (text and
/// resource links as the baseline, plus images and text embedded
/// resources) and flattens it for vendors. Anything else is rejected with
/// `-32602` before the prompt is inserted.
func gatewayPromptInput(_ blocks: [ACPContentBlock]) throws -> GatewayPromptInput {
  var textParts: [String] = []
  var images: [GatewayImageInput] = []
  for block in blocks {
    switch block {
    case .text(let content):
      textParts.append(content.text)
    case .image(let content):
      images.append(GatewayImageInput(dataBase64: content.data, mimeType: content.mimeType))
    case .resourceLink(let link):
      textParts.append(link.uri)
    case .resource(let embedded):
      guard let text = embedded.resource.text else {
        throw ACPError.invalidParams("binary embedded resources are not supported")
      }
      textParts.append(text)
    case .audio:
      throw ACPError.invalidParams("audio content is not supported")
    case .other(let value):
      throw ACPError.invalidParams(
        "unsupported content block type '\(value["type"]?.stringValue ?? "unknown")'"
      )
    }
  }
  guard !textParts.isEmpty || !images.isEmpty else {
    throw ACPError.invalidParams("prompt must contain at least one supported content block")
  }
  return GatewayPromptInput(text: textParts.joined(separator: "\n\n"), images: images)
}

/// Text of a standard `systemPrompt` parameter. The gateway supports
/// `append` mode with text content only; anything else is `-32602`, so a
/// session is never created or resumed with a prompt it cannot apply.
func gatewaySystemPromptText(_ systemPrompt: ACPSystemPrompt?) throws -> String? {
  guard let systemPrompt else { return nil }
  guard systemPrompt.mode == ACPSystemPrompt.appendMode else {
    throw ACPError.invalidParams("unsupported systemPrompt mode '\(systemPrompt.mode)'")
  }
  guard !systemPrompt.content.isEmpty else {
    throw ACPError.invalidParams("systemPrompt content must not be empty")
  }
  let parts = try systemPrompt.content.map { block -> String in
    guard case .text(let text) = block else {
      throw ACPError.invalidParams("systemPrompt supports only text content blocks")
    }
    return text.text
  }
  return parts.joined(separator: "\n\n")
}

/// The ACP error for a failed execution. Gateway errors keep their code
/// and message; anything else is an internal error.
func gatewayACPError(_ error: any Error) -> ACPError {
  if let acpError = error as? ACPError { return acpError }
  if let gatewayError = error as? GatewayRPCError {
    return ACPError(code: gatewayError.code, message: gatewayError.message)
  }
  return ACPError.internalError(String(describing: error))
}

/// `_meta` keys of the gateway's ACP extension object (vendor selection on
/// `session/new`, execution details on turn completion).
///
/// ACP v2 reserves unprefixed `_meta` keys for the protocol and asks
/// extensions to use a reverse-DNS prefix, so v2 connections use the
/// namespaced key. v1 connections keep the original key for existing hosts.
/// Requests are read under either key in both versions.
public enum GatewayACPMetaKey {
  /// Key used on ACP v1 connections.
  public static let v1 = "agentGateway"
  /// Key used on ACP v2 connections.
  public static let v2 = "io.github.tacogips/agentGateway"

  /// The key the gateway writes on a connection of `protocolVersion`.
  public static func key(protocolVersion: Int) -> String {
    protocolVersion >= ACPProtocol.versionV2 ? v2 : v1
  }
}

/// The gateway's extension object inside an ACP `_meta` value, whichever
/// of the two keys carries it. Hosts use this to read turn results
/// without caring which protocol version the connection negotiated.
public func gatewayACPMeta(_ meta: ACPJSONValue?) -> ACPJSONValue? {
  meta?[GatewayACPMetaKey.v2] ?? meta?[GatewayACPMetaKey.v1]
}

/// The gateway extension object describing a finished execution: vendor,
/// model, token usage, the vendor's session id, and its authoritative
/// final text, under `key`.
func gatewayResultMeta(_ result: GatewayExecuteResult, key: String) -> ACPJSONValue {
  var gateway: [String: ACPJSONValue] = [
    "vendor": .string(result.vendor.rawValue),
    "model": .string(result.model),
    // The vendor's authoritative final text. Streamed chunks may span
    // multiple assistant messages; hosts that need exactly the vendor's
    // final result (e.g. for output contracts) should prefer this value.
    "resultText": .string(result.text)
  ]
  if let sessionId = result.sessionId {
    gateway["vendorSessionId"] = .string(sessionId)
  }
  if let usage = result.usage {
    var tokens: [String: ACPJSONValue] = [:]
    if let input = usage.inputTokens { tokens["inputTokens"] = .integer(input) }
    if let output = usage.outputTokens { tokens["outputTokens"] = .integer(output) }
    if let total = usage.totalTokens { tokens["totalTokens"] = .integer(total) }
    gateway["usage"] = .object(tokens)
  }
  return .object([key: .object(gateway)])
}

/// One piece of streamed vendor output.
enum GatewayStreamChunk: Equatable, Sendable {
  case message(String)
  case thought(String)
}

/// Converts gateway emitter callbacks into ordered output chunks.
///
/// Streaming vendors produce token deltas that map 1:1 to message chunks.
/// Non-streaming vendors produce whole-message snapshots; those are
/// de-duplicated so a final echo of already-streamed text (e.g. Claude
/// Code's `result` event or cursor-agent's `result` after deltas) is not
/// emitted twice.
final class GatewayACPStreamBridge: @unchecked Sendable {
  private let lock = NSLock()
  private let yield: @Sendable (GatewayStreamChunk) -> Void
  private var accumulated = ""

  init(yield: @escaping @Sendable (GatewayStreamChunk) -> Void) {
    self.yield = yield
  }

  var emitter: GatewayEventEmitter {
    { [self] event in consume(event) }
  }

  func consume(_ event: GatewayEvent) {
    lock.withLock {
      switch event.channel {
      case .assistant:
        if let delta = event.textDelta, !delta.isEmpty {
          accumulated += delta
          yield(.message(delta))
        } else if let snapshot = event.textSnapshot, !snapshot.isEmpty {
          guard !accumulated.hasSuffix(snapshot) else { return }
          if snapshot.hasPrefix(accumulated), !accumulated.isEmpty {
            let suffix = String(snapshot.dropFirst(accumulated.count))
            accumulated = snapshot
            if !suffix.isEmpty { yield(.message(suffix)) }
          } else {
            accumulated += snapshot
            yield(.message(snapshot))
          }
        }
      case .thinking:
        if let text = event.textDelta ?? event.textSnapshot, !text.isEmpty {
          yield(.thought(text))
        }
      case .lifecycle, .tool, .usage, .vendor:
        break
      }
    }
  }
}
