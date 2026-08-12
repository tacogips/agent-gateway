# Architecture

## Status

Draft

## Overview

`agent-gateway` is the provider-routing boundary between host applications and
CLI-backed agent runtimes. It is a Swift Package Manager project with reusable
library targets, an executable target, tests, and release automation for
Homebrew.

## Targets

- `AgentGateway`: validated provider configuration and backend-specific routing
- `AgentGatewayAppCore`: command-line application logic
- `AgentGatewayCLI`: command line entry point
- `AgentGatewayTests` and `AgentGatewayAppCoreTests`: package tests

## Release Surfaces

- Homebrew formula archives under `dist/homebrew/`
- Signed and notarized Cask DMGs under `dist/homebrew-cask/`
