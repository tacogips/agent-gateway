import ACP
import AgentGateway
import Foundation

/// A stdio MCP server a client supplied for a session, in the form the
/// gateway hands to vendor CLIs.
struct GatewayMCPServer: Equatable, Sendable {
  var name: String
  var command: String
  var arguments: [String]
  var environment: [ACPEnvVariable]
}

extension GatewayVendor {
  /// Whether sessions on this vendor can connect to client-provided stdio
  /// MCP servers. The gateway does not run an MCP client itself: it passes
  /// the server configuration to vendor CLIs that take one on their command
  /// line. API vendors run no tool loop, and cursor-agent reads MCP servers
  /// only from its own configuration files.
  var connectsToMCPServers: Bool {
    switch self {
    case .claudeCode, .codex: true
    case .cursor, .cursorAPI, .openAI, .anthropic, .gemini, .openRouter: false
    }
  }
}

/// Stdio servers of a v1 request. v1 entries without a `type` are stdio;
/// `http` and `sse` are optional transports the gateway does not advertise.
func gatewayMCPServers(v1 servers: [ACPMCPServer]) throws -> [GatewayMCPServer] {
  try servers.map { server in
    guard server.type == nil || server.type == "stdio", let command = server.command else {
      throw ACPError.invalidParams("unsupported MCP server transport '\(server.type ?? "unknown")'")
    }
    return GatewayMCPServer(
      name: server.name, command: command, arguments: server.args ?? [], environment: server.env ?? []
    )
  }
}

/// Stdio servers of a v2 request, validated as v2 requires: a transport the
/// agent did not advertise, a duplicate name, and a relative `command` are
/// each rejected with `-32602`.
func gatewayMCPServers(v2 servers: [ACPV2MCPServer]) throws -> [GatewayMCPServer] {
  var names: Set<String> = []
  return try servers.map { server in
    guard case .stdio(let stdio) = server else {
      throw ACPError.invalidParams("unsupported MCP server transport '\(server.type)'")
    }
    guard names.insert(stdio.name).inserted else {
      throw ACPError.invalidParams("duplicate MCP server name '\(stdio.name)'")
    }
    guard stdio.command.hasPrefix("/") else {
      throw ACPError.invalidParams("MCP server command must be an absolute path")
    }
    return GatewayMCPServer(
      name: stdio.name, command: stdio.command, arguments: stdio.args ?? [], environment: stdio.env ?? []
    )
  }
}

/// Vendor CLI arguments that make the vendor connect to `servers`.
///
/// - claude-code: `--mcp-config <json>` with a `mcpServers` object.
/// - codex: one `-c mcp_servers.<name>.<field>=<toml>` override per field.
///
/// Returns no arguments for vendors that cannot connect to MCP servers.
func gatewayMCPArguments(vendor: GatewayVendor, servers: [GatewayMCPServer]) -> [String] {
  guard !servers.isEmpty else { return [] }
  switch vendor {
  case .claudeCode:
    var entries: [String: ACPJSONValue] = [:]
    for server in servers {
      var environment: [String: ACPJSONValue] = [:]
      // The last entry with a given name wins, as the spec describes.
      for variable in server.environment {
        environment[variable.name] = .string(variable.value)
      }
      entries[server.name] = .object([
        "type": .string("stdio"),
        "command": .string(server.command),
        "args": .array(server.arguments.map { .string($0) }),
        "env": .object(environment)
      ])
    }
    return ["--mcp-config", gatewayJSONText(.object(["mcpServers": .object(entries)]))]
  case .codex:
    return servers.flatMap { server -> [String] in
      // codex splits the override key on dots, so the server name is
      // reduced to a TOML bare key. Values are JSON strings, which are
      // valid TOML basic strings.
      let key = "mcp_servers.\(gatewayTOMLBareKey(server.name))"
      var environment: [String: String] = [:]
      for variable in server.environment {
        environment[variable.name] = variable.value
      }
      let table = environment.keys.sorted()
        .map { "\(gatewayJSONText(.string($0))) = \(gatewayJSONText(.string(environment[$0] ?? "")))" }
        .joined(separator: ", ")
      var overrides = [
        "\(key).command=\(gatewayJSONText(.string(server.command)))",
        "\(key).args=\(gatewayJSONText(.array(server.arguments.map { .string($0) })))"
      ]
      if !table.isEmpty {
        overrides.append("\(key).env={ \(table) }")
      }
      return overrides.flatMap { ["-c", $0] }
    }
  case .cursor, .cursorAPI, .openAI, .anthropic, .gemini, .openRouter:
    return []
  }
}

/// A TOML bare key (`A-Za-z0-9_-`) derived from `name`.
func gatewayTOMLBareKey(_ name: String) -> String {
  let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
  let key = String(name.map { allowed.contains($0) ? $0 : "_" })
  return key.isEmpty ? "_" : key
}

private func gatewayJSONText(_ value: ACPJSONValue) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
    return "null"
  }
  return text
}
