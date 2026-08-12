import AgentGateway
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Lists the models a vendor can run. API vendors are enumerated through
/// their model-listing endpoints; CLI vendors (claude-code, codex, cursor)
/// have no machine-readable enumeration and are rejected with
/// `gatewayModelListingUnsupportedCode` rather than a guessed list.
public protocol GatewayModelListing: Sendable {
  func models(_ params: GatewayModelCatalogParams) async throws -> GatewayModelCatalogResult
}

/// Error code for vendors that cannot enumerate models.
public let gatewayModelListingUnsupportedCode = -32020

extension ProductionGatewayExecutor: GatewayModelListing {
  public func models(_ params: GatewayModelCatalogParams) async throws -> GatewayModelCatalogResult {
    guard params.protocolVersion == GatewayProtocolVersion.current else {
      throw GatewayRPCError(code: -32602, message: "unsupported protocol version '\(params.protocolVersion)'")
    }
    let request = try makeModelListRequest(params)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw GatewayRPCError(code: -32010, message: "vendor did not return an HTTP response")
    }
    guard (200...299).contains(http.statusCode) else {
      let body = String(bytes: data.prefix(500), encoding: .utf8) ?? "invalid UTF-8 response"
      throw GatewayRPCError(code: -32010, message: "vendor HTTP \(http.statusCode): \(body)")
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw GatewayRPCError(code: -32010, message: "vendor returned invalid model list JSON")
    }
    return GatewayModelCatalogResult(
      vendor: params.vendor,
      models: parseVendorModelList(object, vendor: params.vendor)
    )
  }
}

func makeModelListRequest(
  _ params: GatewayModelCatalogParams,
  environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> URLRequest {
  guard !params.vendor.isCLI else {
    throw GatewayRPCError(
      code: gatewayModelListingUnsupportedCode,
      message: "\(params.vendor.rawValue) does not support model enumeration"
    )
  }
  let keyName = params.apiKeyEnvironment ?? defaultAPIKeyEnvironment(for: params.vendor)
  guard let apiKey = environment[keyName], !apiKey.isEmpty else {
    throw GatewayRPCError(code: -32011, message: "missing credential environment '\(keyName)'")
  }
  let base = try params.baseURL ?? defaultGatewayBaseURL(for: params.vendor)
  let value = params.vendor == .gemini
    ? appendPath(base, "models") + "?key=\(apiKey)"
    : appendPath(base, "models")
  guard let url = URL(string: value) else {
    throw GatewayRPCError(code: -32602, message: "invalid base URL")
  }
  var request = URLRequest(url: url)
  request.httpMethod = "GET"
  request.timeoutInterval = 15
  try applyGatewayAPIKeyHeaders(&request, vendor: params.vendor, apiKey: apiKey)
  return request
}

func parseVendorModelList(_ object: [String: Any], vendor: GatewayVendor) -> [GatewayModelInfo] {
  switch vendor {
  case .openAI, .anthropic, .openRouter:
    // {"data":[{"id":..., "display_name"/"name":..., "description":...}]}
    let entries = object["data"] as? [[String: Any]] ?? []
    return entries.compactMap { entry in
      guard let id = entry["id"] as? String else { return nil }
      return GatewayModelInfo(
        modelId: id,
        name: entry["display_name"] as? String ?? entry["name"] as? String,
        description: entry["description"] as? String
      )
    }
  case .gemini:
    // {"models":[{"name":"models/gemini-...","displayName":...,"description":...}]}
    let entries = object["models"] as? [[String: Any]] ?? []
    return entries.compactMap { entry in
      guard let name = entry["name"] as? String else { return nil }
      let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
      return GatewayModelInfo(
        modelId: id,
        name: entry["displayName"] as? String,
        description: entry["description"] as? String
      )
    }
  case .cursorAPI:
    // {"models":["model-id", ...]}
    let entries = object["models"] as? [String] ?? []
    return entries.map { GatewayModelInfo(modelId: $0) }
  case .claudeCode, .codex, .cursor:
    return []
  }
}
