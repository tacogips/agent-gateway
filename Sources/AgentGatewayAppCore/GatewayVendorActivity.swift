import ACP
import AgentGateway
import Foundation

/// Tool calls, todo list, and context usage read from one vendor line.
struct ParsedVendorActivity: Equatable {
  var toolCalls: [GatewayToolCallEvent] = []
  var plan: GatewayPlanEvent?
  var context: GatewayContextUsage?
}

/// Reads the activity a CLI vendor line reports. API vendors run no tools
/// through the gateway, so their lines carry none.
///
/// `object` is the line as already parsed for text; it is used to skip the
/// second, typed decode for the lines that cannot carry activity (token
/// deltas are by far the most frequent lines).
func parseVendorActivity(data: Data, object: [String: Any], vendor: GatewayVendor) -> ParsedVendorActivity {
  let type = object["type"] as? String ?? ""
  switch vendor {
  case .claudeCode:
    if type == "stream_event" {
      let eventType = (object["event"] as? [String: Any])?["type"] as? String ?? ""
      guard ["content_block_start", "message_start", "message_delta"].contains(eventType) else {
        return ParsedVendorActivity()
      }
    } else if !["assistant", "user", "result"].contains(type) {
      return ParsedVendorActivity()
    }
  case .codex:
    guard ["item.started", "item.updated", "item.completed"].contains(type) else { return ParsedVendorActivity() }
  case .cursor:
    guard type == "tool_call" else { return ParsedVendorActivity() }
  case .antigravity:
    guard object["event"] as? String == "step_update",
          let stepUpdate = object["step_update"] as? [String: Any],
          stepUpdate["step_type"] as? String == "tool" else {
      return ParsedVendorActivity()
    }
  case .cursorAPI, .openAI, .anthropic, .gemini, .openRouter:
    return ParsedVendorActivity()
  }
  guard let value = try? JSONDecoder().decode(ACPJSONValue.self, from: data) else { return ParsedVendorActivity() }
  switch vendor {
  case .claudeCode: return claudeCodeActivity(value)
  case .codex: return codexActivity(value)
  case .cursor: return cursorActivity(value)
  case .antigravity: return antigravityActivity(value)
  case .cursorAPI, .openAI, .anthropic, .gemini, .openRouter: return ParsedVendorActivity()
  }
}

// MARK: - JSON helpers

extension ACPJSONValue {
  fileprivate var arrayValue: [ACPJSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  fileprivate var doubleValue: Double? {
    switch self {
    case .number(let value): value
    case .integer(let value): Double(value)
    default: nil
    }
  }

  /// The value unless it is JSON `null`.
  fileprivate var nonNull: ACPJSONValue? {
    self == .null ? nil : self
  }
}

/// ACP locations hold absolute paths; vendors sometimes report relative ones.
private func gatewayLocation(_ path: String?, line: Int? = nil) -> [ACPToolCallLocation]? {
  guard let path, path.hasPrefix("/") else { return nil }
  return [ACPToolCallLocation(path: path, line: line.flatMap { $0 >= 1 ? $0 : nil })]
}

/// A one-line title from possibly long, multi-line vendor text.
private func gatewayShortTitle(_ text: String, limit: Int = 120) -> String {
  let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
  return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
}

// MARK: - Claude Code

/// Claude Code `stream-json` lines.
///
/// A tool call appears three times: `content_block_start` announces it
/// while its input streams (pending), the `assistant` message carries the
/// complete input (in progress), and a `user` message carries its
/// `tool_result` (completed or failed).
private func claudeCodeActivity(_ value: ACPJSONValue) -> ParsedVendorActivity {
  var activity = ParsedVendorActivity()
  // Messages of a subagent carry the id of the tool call that spawned it;
  // their token counts describe the subagent's context, not the session's.
  let isMainThread = value["parent_tool_use_id"]?.nonNull == nil
  switch value["type"]?.stringValue {
  case "stream_event":
    let event = value["event"]
    switch event?["type"]?.stringValue {
    case "content_block_start":
      let block = event?["content_block"]
      guard block?["type"]?.stringValue == "tool_use", let id = block?["id"]?.stringValue else { break }
      let name = block?["name"]?.stringValue
      activity.toolCalls.append(GatewayToolCallEvent(
        toolCallId: id, name: name, title: name, kind: name.map(claudeCodeToolKind), status: .pending
      ))
    case "message_start":
      guard isMainThread, let model = event?["message"]?["model"]?.stringValue else { break }
      activity.context = GatewayContextUsage(
        usedTokens: claudeCodeContextTokens(event?["message"]?["usage"]), model: model
      )
    case "message_delta":
      guard isMainThread, let used = claudeCodeContextTokens(event?["usage"]) else { break }
      activity.context = GatewayContextUsage(usedTokens: used)
    default:
      break
    }
  case "assistant":
    for block in value["message"]?["content"]?.arrayValue ?? [] {
      guard block["type"]?.stringValue == "tool_use", let id = block["id"]?.stringValue else { continue }
      let name = block["name"]?.stringValue
      let input = block["input"]
      activity.toolCalls.append(GatewayToolCallEvent(
        toolCallId: id,
        name: name,
        title: name.map { claudeCodeToolTitle(name: $0, input: input) },
        kind: name.map(claudeCodeToolKind),
        status: .inProgress,
        rawInput: input,
        locations: claudeCodeToolLocations(input)
      ))
      if name == "TodoWrite", let entries = claudeCodeTodoEntries(input) {
        activity.plan = GatewayPlanEvent(entries: entries)
      }
    }
  case "user":
    let blocks = (value["message"]?["content"]?.arrayValue ?? []).filter { $0["type"]?.stringValue == "tool_result" }
    for block in blocks {
      guard let id = block["tool_use_id"]?.stringValue else { continue }
      // `tool_use_result` is the structured result of the message's tool
      // call; it can only be attributed when the message has exactly one.
      let structured = blocks.count == 1 ? value["tool_use_result"]?.nonNull : nil
      activity.toolCalls.append(GatewayToolCallEvent(
        toolCallId: id,
        status: block["is_error"]?.boolValue == true ? .failed : .completed,
        rawOutput: structured ?? block["content"]?.nonNull,
        outputText: claudeCodeResultText(block["content"])
      ))
    }
  case "result":
    var context = GatewayContextUsage(costUSD: value["total_cost_usd"]?.doubleValue)
    for (model, usage) in value["modelUsage"]?.objectValue ?? [:] {
      if let window = usage["contextWindow"]?.integerValue, window > 0 {
        context.windowSizes[model] = window
      }
    }
    if context != GatewayContextUsage() {
      activity.context = context
    }
  default:
    break
  }
  return activity
}

/// Tokens occupying the context after one model call: everything the call
/// read (fresh, cache-written, and cache-read input) plus what it wrote.
private func claudeCodeContextTokens(_ usage: ACPJSONValue?) -> Int? {
  guard let input = usage?["input_tokens"]?.integerValue else { return nil }
  return input
    + (usage?["cache_creation_input_tokens"]?.integerValue ?? 0)
    + (usage?["cache_read_input_tokens"]?.integerValue ?? 0)
    + (usage?["output_tokens"]?.integerValue ?? 0)
}

private func claudeCodeToolKind(_ name: String) -> ACPToolKind {
  switch name {
  case "Read", "NotebookRead": .read
  case "Write", "Edit", "MultiEdit", "NotebookEdit": .edit
  case "Bash", "BashOutput", "KillShell": .execute
  case "Grep", "Glob", "LS": .search
  case "WebFetch", "WebSearch": .fetch
  case "Task", "Agent", "TodoWrite": .think
  default: .other
  }
}

private func claudeCodeToolTitle(name: String, input: ACPJSONValue?) -> String {
  let detail: String? = switch name {
  case "Bash": input?["command"]?.stringValue
  case "Read", "Write", "Edit", "MultiEdit": input?["file_path"]?.stringValue
  case "NotebookEdit": input?["notebook_path"]?.stringValue
  case "Grep", "Glob": input?["pattern"]?.stringValue
  case "WebFetch": input?["url"]?.stringValue
  case "WebSearch": input?["query"]?.stringValue
  case "Task", "Agent": input?["description"]?.stringValue
  default: nil
  }
  guard let detail, !detail.isEmpty else { return name }
  // A shell command is its own best title; other tools keep their name.
  return gatewayShortTitle(name == "Bash" ? detail : "\(name) \(detail)")
}

private func claudeCodeToolLocations(_ input: ACPJSONValue?) -> [ACPToolCallLocation]? {
  gatewayLocation(
    input?["file_path"]?.stringValue ?? input?["notebook_path"]?.stringValue,
    line: input?["offset"]?.integerValue
  )
}

/// The todo list of a `TodoWrite` call. Claude Code todos have no
/// priority, so entries take ACP's required field at its neutral value.
private func claudeCodeTodoEntries(_ input: ACPJSONValue?) -> [ACPPlanEntry]? {
  guard let todos = input?["todos"]?.arrayValue else { return nil }
  return todos.compactMap { todo in
    guard let content = todo["content"]?.stringValue else { return nil }
    let status = todo["status"]?.stringValue.flatMap(ACPPlanEntry.Status.init(rawValue:)) ?? .pending
    return ACPPlanEntry(content: content, priority: .medium, status: status)
  }
}

/// Text of a `tool_result`: a plain string, or the text blocks of an array.
private func claudeCodeResultText(_ content: ACPJSONValue?) -> String? {
  if let text = content?.stringValue {
    return text.isEmpty ? nil : text
  }
  let text = (content?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
  return text.isEmpty ? nil : text
}

// MARK: - Codex

/// `codex exec --json` thread items. Items that are tool work
/// (`command_execution`, `file_change`, `mcp_tool_call`, `web_search`)
/// become tool calls; a `todo_list` item is the plan.
private func codexActivity(_ value: ACPJSONValue) -> ParsedVendorActivity {
  var activity = ParsedVendorActivity()
  guard let item = value["item"], let id = item["id"]?.stringValue,
        let itemType = item["type"]?.stringValue else { return activity }
  let finished = value["type"]?.stringValue == "item.completed"
  let status = codexStatus(item["status"]?.stringValue, finished: finished)
  switch itemType {
  case "command_execution":
    let command = item["command"]?.stringValue
    var call = GatewayToolCallEvent(
      toolCallId: id, name: itemType, title: command.map { gatewayShortTitle($0) }, kind: .execute, status: status,
      rawInput: command.map { .object(["command": .string($0)]) }
    )
    if let output = item["aggregated_output"]?.stringValue, !output.isEmpty {
      call.outputText = output
    }
    if finished {
      var raw: [String: ACPJSONValue] = [:]
      if let output = item["aggregated_output"]?.nonNull { raw["aggregated_output"] = output }
      if let exitCode = item["exit_code"]?.nonNull { raw["exit_code"] = exitCode }
      call.rawOutput = raw.isEmpty ? nil : .object(raw)
    }
    activity.toolCalls.append(call)
  case "file_change":
    let rawChanges = item["changes"]?.arrayValue ?? []
    let changes = rawChanges.compactMap { change -> GatewayToolCallEvent.FileChange? in
      guard let path = change["path"]?.stringValue,
            let operation = codexFileOperation(change["kind"]?.stringValue) else { return nil }
      return GatewayToolCallEvent.FileChange(path: path, operation: operation)
    }
    let paths = rawChanges.compactMap { $0["path"]?.stringValue }
    let locations = paths.compactMap { gatewayLocation($0)?.first }
    activity.toolCalls.append(GatewayToolCallEvent(
      toolCallId: id,
      name: itemType,
      title: paths.count == 1 ? "Edit \(paths[0])" : "Edit \(paths.count) files",
      kind: !changes.isEmpty && changes.allSatisfy({ $0.operation == "delete" }) ? .delete : .edit,
      status: status,
      rawInput: item["changes"].map { .object(["changes": $0]) },
      locations: locations.isEmpty ? nil : locations,
      fileChanges: changes.isEmpty ? nil : changes
    ))
  case "mcp_tool_call":
    let tool = item["tool"]?.stringValue
    let title = [item["server"]?.stringValue, tool].compactMap { $0 }.joined(separator: ".")
    let error = item["error"]?.nonNull
    activity.toolCalls.append(GatewayToolCallEvent(
      toolCallId: id,
      name: tool,
      title: title.isEmpty ? nil : title,
      kind: .other,
      status: status,
      rawInput: item["arguments"]?.nonNull,
      rawOutput: item["result"]?.nonNull ?? error,
      outputText: error?["message"]?.stringValue
    ))
  case "web_search":
    let query = item["query"]?.stringValue
    activity.toolCalls.append(GatewayToolCallEvent(
      toolCallId: id,
      name: itemType,
      title: query.flatMap { $0.isEmpty ? nil : gatewayShortTitle($0) } ?? "Web search",
      kind: .fetch,
      status: status,
      rawInput: query.map { .object(["query": .string($0)]) }
    ))
  case "todo_list":
    let entries = (item["items"]?.arrayValue ?? []).compactMap { entry -> ACPPlanEntry? in
      guard let text = entry["text"]?.stringValue else { return nil }
      // Codex todos are done or not done, and have no priority.
      return ACPPlanEntry(
        content: text, priority: .medium, status: entry["completed"]?.boolValue == true ? .completed : .pending
      )
    }
    activity.plan = GatewayPlanEvent(planId: id, entries: entries)
  default:
    break
  }
  return activity
}

/// An item's `status`, or what its event implies when it has none
/// (`web_search` items carry no status). A finished item with any status
/// other than `completed` did not succeed.
private func codexStatus(_ status: String?, finished: Bool) -> ACPToolCallStatus {
  switch status {
  case "completed": .completed
  case "in_progress": finished ? .completed : .inProgress
  case nil: finished ? .completed : .inProgress
  default: finished ? .failed : .inProgress
  }
}

private func codexFileOperation(_ kind: String?) -> String? {
  switch kind {
  case "add": "add"
  case "delete": "delete"
  case "update": "modify"
  default: nil
  }
}

// MARK: - Cursor

/// cursor-agent `stream-json` `tool_call` lines: `subtype` is `started` or
/// `completed`, and `tool_call` holds one object keyed by the tool
/// (`readToolCall`, `writeToolCall`, ... with `args` and `result`) or a
/// generic `function` with `name` and `arguments`.
private func cursorActivity(_ value: ACPJSONValue) -> ParsedVendorActivity {
  var activity = ParsedVendorActivity()
  guard let id = value["call_id"]?.stringValue,
        let call = value["tool_call"]?.objectValue,
        let key = call.keys.sorted().first, let body = call[key] else { return activity }
  let isFunction = key == "function"
  let name = isFunction ? body["name"]?.stringValue : key
  let input = isFunction ? body["arguments"]?.nonNull : body["args"]?.nonNull
  let result = body["result"]?.nonNull
  let status: ACPToolCallStatus
  if value["subtype"]?.stringValue == "completed" {
    let failed = result?.objectValue.map { $0["success"] == nil && ($0["error"] != nil || $0["rejected"] != nil) }
    status = failed == true ? .failed : .completed
  } else {
    status = .inProgress
  }
  let path = input?["path"]?.stringValue
  let display = name.map { $0.hasSuffix("ToolCall") ? String($0.dropLast("ToolCall".count)) : $0 }
  let detail = path ?? input?["command"]?.stringValue
  activity.toolCalls.append(GatewayToolCallEvent(
    toolCallId: id,
    name: name,
    title: display.map { title in detail.map { gatewayShortTitle("\(title) \($0)") } ?? title },
    kind: display.map(cursorToolKind),
    status: status,
    rawInput: input,
    rawOutput: result,
    locations: gatewayLocation(path)
  ))
  return activity
}

private func cursorToolKind(_ name: String) -> ACPToolKind {
  let lowered = name.lowercased()
  if lowered.hasPrefix("read") { return .read }
  if lowered.hasPrefix("write") || lowered.hasPrefix("edit") { return .edit }
  if lowered.hasPrefix("delete") { return .delete }
  if lowered.hasPrefix("shell") { return .execute }
  if lowered.hasPrefix("grep") || lowered.hasPrefix("glob") || lowered.hasPrefix("ls") { return .search }
  return .other
}

// MARK: - Antigravity

/// Antigravity (`agy`) `stream-json` tool step updates:
/// `{"event":"step_update","step_update":{"step_index":2,"state":"ACTIVE"|"DONE","step_type":"tool","tool_name":"read_file","tool_info":{"name":"read_file","parameters":{...},"output":"..."}}}`.
private func antigravityActivity(_ value: ACPJSONValue) -> ParsedVendorActivity {
  var activity = ParsedVendorActivity()
  guard let stepUpdate = value["step_update"] else { return activity }
  let stepIndex = stepUpdate["step_index"]?.integerValue
  let id = stepUpdate["tool_call_id"]?.stringValue ?? stepIndex.map { "step-\($0)" } ?? "tool"
  let toolInfo = stepUpdate["tool_info"]
  let name = stepUpdate["tool_name"]?.stringValue ?? toolInfo?["name"]?.stringValue
  let parameters = toolInfo?["parameters"]?.nonNull
  let output = toolInfo?["output"]?.stringValue
  let state = stepUpdate["state"]?.stringValue?.uppercased()
  let status: ACPToolCallStatus = switch state {
  case "DONE", "COMPLETED": .completed
  case "ERROR", "FAILED": .failed
  case "ACTIVE", "RUNNING": .inProgress
  default: .pending
  }
  let path = parameters?["Path"]?.stringValue ?? parameters?["path"]?.stringValue
  let detail = path ?? parameters?["CommandLine"]?.stringValue ?? parameters?["command"]?.stringValue
  activity.toolCalls.append(GatewayToolCallEvent(
    toolCallId: id,
    name: name,
    title: name.map { tool in detail.map { gatewayShortTitle("\(tool) \($0)") } ?? tool },
    kind: name.map(antigravityToolKind),
    status: status,
    rawInput: parameters,
    outputText: output,
    locations: gatewayLocation(path)
  ))
  return activity
}

private func antigravityToolKind(_ name: String) -> ACPToolKind {
  switch name {
  case "read_file", "view_file", "view_file_outline", "view_code_item": .read
  case "write_file", "write_to_file", "edit_file", "replace_file_content", "multi_replace_file_content", "sed_file", "notebook_edit": .edit
  case "run_command", "send_command_input", "command_status": .execute
  case "grep_search", "find_by_name", "list_dir": .search
  case "search_web", "read_url_content", "open_browser_url", "read_browser_page": .fetch
  default: .other
  }
}
