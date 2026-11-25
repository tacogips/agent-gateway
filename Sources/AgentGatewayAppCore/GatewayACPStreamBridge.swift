import ACP
import AgentGateway
import Foundation

/// One piece of streamed vendor output.
enum GatewayStreamChunk: Equatable, Sendable {
  case message(String)
  case thought(String)
  case toolCall(GatewayToolCallChunk)
  case plan(GatewayPlanChunk)
  case usage(GatewayUsageChunk)
}

/// What a v1 turn streamed: the text retained for history replay and the
/// cost the vendor reported for the turn's execution.
struct GatewayStreamedOutput: Sendable {
  var message: String
  var thought: String
  var costUSD: Double?
}

/// Prefix that makes vendor tool-call and plan ids unique within an ACP
/// session: vendors only keep them unique within one execution, and every
/// turn is a new execution.
func gatewayActivityScope(turn: Int) -> String {
  "t\(turn)-"
}

/// Converts gateway emitter callbacks into ordered output chunks.
///
/// Streaming vendors produce token deltas that map 1:1 to message chunks.
/// Non-streaming vendors produce whole-message snapshots; those are
/// de-duplicated so a final echo of already-streamed text (e.g. Claude
/// Code's `result` event or cursor-agent's `result` after deltas) is not
/// emitted twice.
///
/// Tool calls are merged by id: the first event for an id yields a new
/// call, later events yield only the fields that changed, repeats yield
/// nothing, and nothing follows a final status. `settleOpenToolCalls`
/// gives every call still open a final status when the turn ends.
final class GatewayACPStreamBridge: @unchecked Sendable {
  private let lock = NSLock()
  private let yield: @Sendable (GatewayStreamChunk) -> Void
  private let scope: String
  private var accumulated = ""
  /// Merged state of every tool call seen, by vendor id.
  private var toolCalls: [String: GatewayToolCallEvent] = [:]
  private var toolCallOrder: [String] = []
  private var plans: [String: [ACPPlanEntry]] = [:]
  private var usage: GatewayUsage?
  private var context = GatewayContextUsage()
  private var lastUsage: GatewayUsageChunk?

  /// - Parameter scope: prefix for tool-call and plan ids; see `gatewayActivityScope`.
  init(scope: String = "", yield: @escaping @Sendable (GatewayStreamChunk) -> Void) {
    self.scope = scope
    self.yield = yield
  }

  var emitter: GatewayEventEmitter {
    { [self] event in consume(event) }
  }

  func consume(_ event: GatewayEvent) {
    lock.withLock {
      consumeText(event)
      for call in event.toolCalls {
        consumeToolCall(call)
      }
      if let plan = event.plan {
        consumePlan(plan)
      }
      consumeUsage(event)
    }
  }

  /// Gives every tool call without a final status `status`, in the order
  /// the calls started. Called once the vendor execution has ended, so a
  /// client never keeps a tool call that looks like it is still running.
  func settleOpenToolCalls(_ status: ACPToolCallStatus) {
    lock.withLock {
      for id in toolCallOrder {
        guard var call = toolCalls[id], !Self.isFinal(call.status) else { continue }
        call.status = status
        toolCalls[id] = call
        yield(.toolCall(GatewayToolCallChunk(isNew: false, toolCallId: scope + id, status: status)))
      }
    }
  }

  private func consumeText(_ event: GatewayEvent) {
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

  private static func isFinal(_ status: ACPToolCallStatus?) -> Bool {
    status == .completed || status == .failed
  }

  /// Order of the statuses a call moves through; a status never moves back.
  private static func rank(_ status: ACPToolCallStatus?) -> Int {
    switch status {
    case nil, .pending: 0
    case .inProgress: 1
    case .completed, .failed: 2
    }
  }

  /// Stores `new` when it differs from `stored` and reports it as changed.
  private static func merge<Value: Equatable>(_ new: Value?, into stored: inout Value?, changed: inout Value?) {
    guard let new, new != stored else { return }
    stored = new
    changed = new
  }

  private func consumeToolCall(_ event: GatewayToolCallEvent) {
    let id = event.toolCallId
    guard var call = toolCalls[id] else {
      var call = event
      call.status = event.status ?? .pending
      toolCalls[id] = call
      toolCallOrder.append(id)
      yield(.toolCall(GatewayToolCallChunk(
        isNew: true, toolCallId: scope + id, name: call.name, title: call.title, kind: call.kind,
        status: call.status, rawInput: call.rawInput, rawOutput: call.rawOutput, outputText: call.outputText,
        locations: call.locations, fileChanges: call.fileChanges
      )))
      return
    }
    guard !Self.isFinal(call.status) else { return }
    var chunk = GatewayToolCallChunk(isNew: false, toolCallId: scope + id)
    Self.merge(event.name, into: &call.name, changed: &chunk.name)
    Self.merge(event.title, into: &call.title, changed: &chunk.title)
    Self.merge(event.kind, into: &call.kind, changed: &chunk.kind)
    Self.merge(event.rawInput, into: &call.rawInput, changed: &chunk.rawInput)
    Self.merge(event.rawOutput, into: &call.rawOutput, changed: &chunk.rawOutput)
    Self.merge(event.outputText, into: &call.outputText, changed: &chunk.outputText)
    Self.merge(event.locations, into: &call.locations, changed: &chunk.locations)
    Self.merge(event.fileChanges, into: &call.fileChanges, changed: &chunk.fileChanges)
    if let status = event.status, Self.rank(status) > Self.rank(call.status) {
      call.status = status
      chunk.status = status
    }
    guard !chunk.isEmpty else { return }
    toolCalls[id] = call
    yield(.toolCall(chunk))
  }

  private func consumePlan(_ plan: GatewayPlanEvent) {
    let planId = plan.planId.map { scope + $0 } ?? gatewayDefaultPlanId
    guard plans[planId] != plan.entries else { return }
    plans[planId] = plan.entries
    yield(.plan(GatewayPlanChunk(planId: planId, entries: plan.entries)))
  }

  private func consumeUsage(_ event: GatewayEvent) {
    guard event.usage != nil || event.context != nil else { return }
    usage = GatewayUsage.merge(usage, event.usage)
    if let reported = event.context {
      context.usedTokens = reported.usedTokens ?? context.usedTokens
      context.model = reported.model ?? context.model
      context.windowSizes.merge(reported.windowSizes) { _, new in new }
      context.costUSD = reported.costUSD ?? context.costUSD
    }
    let chunk = GatewayUsageChunk(
      tokens: usage, contextUsed: context.usedTokens, contextSize: contextWindowSize, costUSD: context.costUSD
    )
    guard chunk != lastUsage else { return }
    lastUsage = chunk
    yield(.usage(chunk))
  }

  /// The window of the model whose context is being measured. Vendors
  /// report windows for every model an execution touched (helper models
  /// included), so the size is only known when it can be attributed.
  private var contextWindowSize: Int? {
    let sizes = context.windowSizes
    if let model = context.model {
      if let size = sizes[model] { return size }
      let matches = sizes.filter { $0.key.hasPrefix(model) }
      if matches.count == 1 { return matches.first?.value }
      return nil
    }
    return sizes.count == 1 ? sizes.first?.value : nil
  }
}
