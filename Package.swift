// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "agent-gateway",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "ACP", targets: ["ACP"]),
    .library(name: "AgentGateway", targets: ["AgentGateway"]),
    .library(name: "AgentGatewayAppCore", targets: ["AgentGatewayAppCore"]),
    .executable(name: "agent-gateway", targets: ["AgentGatewayCLI"])
  ],
  targets: [
    .target(name: "ACP"),
    .target(name: "AgentGateway"),
    .target(name: "AgentGatewayAppCore", dependencies: ["ACP", "AgentGateway"]),
    .executableTarget(
      name: "AgentGatewayCLI",
      dependencies: ["AgentGatewayAppCore"]
    ),
    .testTarget(
      name: "ACPTests",
      dependencies: ["ACP"]
    ),
    .testTarget(
      name: "AgentGatewayAppCoreTests",
      dependencies: ["AgentGatewayAppCore"]
    ),
    .testTarget(
      name: "AgentGatewayTests",
      dependencies: ["ACP", "AgentGateway", "AgentGatewayAppCore"]
    )
  ],
  swiftLanguageModes: [.v6]
)
