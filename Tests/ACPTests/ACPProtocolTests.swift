import Foundation
import Testing
@testable import ACP

@Test func contentBlocksRoundTripThroughACPWireFormat() throws {
  let blocks: [ACPContentBlock] = [
    .text("hello"),
    .image(ACPImageContent(data: "aGk=", mimeType: "image/png")),
    .resourceLink(ACPResourceLink(uri: "file:///tmp/a.swift", name: "a.swift")),
    .resource(ACPEmbeddedResource(resource: ACPEmbeddedResourceContents(
      uri: "file:///tmp/a.swift", mimeType: "text/x-swift", text: "let a = 1"
    )))
  ]
  let data = try JSONEncoder().encode(blocks)
  let decoded = try JSONDecoder().decode([ACPContentBlock].self, from: data)
  #expect(decoded == blocks)
  let json = try #require(String(bytes: data, encoding: .utf8))
  #expect(json.contains(#""type":"text""#))
  #expect(json.contains(#""type":"resource_link""#))
}

@Test func sessionUpdatesUseSpecDiscriminatorStrings() throws {
  let updates: [ACPSessionUpdate] = [
    .agentMessageChunk(.text("to")),
    .agentThoughtChunk(.text("hmm")),
    .toolCall(ACPToolCall(toolCallId: "call-1", title: "read file", kind: .read, status: .pending)),
    .toolCallUpdate(ACPToolCallUpdate(toolCallId: "call-1", status: .completed)),
    .plan([ACPPlanEntry(content: "step", priority: .high, status: .inProgress)])
  ]
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let payloads = try updates.map { try #require(String(bytes: encoder.encode($0), encoding: .utf8)) }
  #expect(payloads[0].contains(#""sessionUpdate":"agent_message_chunk""#))
  #expect(payloads[1].contains(#""sessionUpdate":"agent_thought_chunk""#))
  #expect(payloads[2].contains(#""sessionUpdate":"tool_call""#))
  #expect(payloads[3].contains(#""sessionUpdate":"tool_call_update""#))
  #expect(payloads[4].contains(#""sessionUpdate":"plan""#))
  for (update, payload) in zip(updates, payloads) {
    let decoded = try JSONDecoder().decode(ACPSessionUpdate.self, from: Data(payload.utf8))
    #expect(decoded == update)
  }
}

@Test func initializeRequestDefaultsMissingCapabilities() throws {
  let request = try JSONDecoder().decode(
    ACPInitializeRequest.self,
    from: Data(#"{"protocolVersion":1}"#.utf8)
  )
  #expect(request.protocolVersion == 1)
  #expect(request.clientCapabilities == ACPClientCapabilities())
}

@Test func stopReasonsMatchSpecConstants() {
  #expect(ACPStopReason.endTurn.rawValue == "end_turn")
  #expect(ACPStopReason.maxTokens.rawValue == "max_tokens")
  #expect(ACPStopReason.maxTurnRequests.rawValue == "max_turn_requests")
  #expect(ACPStopReason.cancelled.rawValue == "cancelled")
}

@Test func requestIDSupportsNumbersAndStrings() throws {
  let numeric = try JSONDecoder().decode(ACPRequestID.self, from: Data("7".utf8))
  #expect(numeric == .number(7))
  let text = try JSONDecoder().decode(ACPRequestID.self, from: Data(#""abc""#.utf8))
  #expect(text == .string("abc"))
}

private struct EchoAgent: ACPAgent {
  func initialize(_ request: ACPInitializeRequest) async throws -> ACPInitializeResponse {
    ACPInitializeResponse(
      protocolVersion: min(request.protocolVersion, ACPProtocol.versionV1),
      agentInfo: ACPImplementation(name: "echo", version: "0.0.1")
    )
  }

  func newSession(
    _ request: ACPNewSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPNewSessionResponse {
    ACPNewSessionResponse(sessionId: "echo-session")
  }

  func prompt(
    _ request: ACPPromptRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPPromptResponse {
    for block in request.prompt {
      if case .text(let content) = block {
        for character in content.text {
          await connection.sendUpdate(ACPSessionNotification(
            sessionId: request.sessionId,
            update: .agentMessageChunk(.text(String(character)))
          ))
        }
      }
    }
    return ACPPromptResponse(stopReason: .endTurn)
  }

  func cancel(_ notification: ACPCancelNotification) async {}
}

private actor UpdateCollector: ACPClientDelegate {
  private(set) var chunks: [String] = []
  private var waiter: CheckedContinuation<Void, Never>?
  private var expected = 0

  func sessionUpdate(_ notification: ACPSessionNotification) async {
    if case .agentMessageChunk(.text(let content)) = notification.update {
      chunks.append(content.text)
      if chunks.count >= expected {
        waiter?.resume()
        waiter = nil
      }
    }
  }

  func waitForChunks(_ count: Int) async {
    expected = count
    if chunks.count >= count { return }
    await withCheckedContinuation { waiter = $0 }
  }
}

@Test func clientAndAgentCompleteAPromptTurnOverInMemoryTransport() async throws {
  let (clientSide, agentSide) = ACPInMemoryTransport.pair()
  let server = ACPAgentServer(agent: EchoAgent(), transport: agentSide)
  await server.start()

  let collector = UpdateCollector()
  let client = ACPClientConnection(transport: clientSide, delegate: collector)
  await client.start()

  let initialized = try await client.initialize()
  #expect(initialized.protocolVersion == ACPProtocol.versionV1)
  #expect(initialized.agentInfo?.name == "echo")

  let session = try await client.newSession(ACPNewSessionRequest(cwd: "/tmp"))
  #expect(session.sessionId == "echo-session")

  let response = try await client.prompt(
    ACPPromptRequest(sessionId: session.sessionId, prompt: [.text("hey")])
  )
  #expect(response.stopReason == .endTurn)
  await collector.waitForChunks(3)
  let chunks = await collector.chunks
  #expect(chunks.joined() == "hey")
  await client.stop()
}

@Test func agentServerRejectsUnknownMethodsWithMethodNotFound() async throws {
  let (clientSide, agentSide) = ACPInMemoryTransport.pair()
  let server = ACPAgentServer(agent: EchoAgent(), transport: agentSide)
  await server.start()
  let client = ACPClientConnection(transport: clientSide)
  await client.start()
  await #expect(throws: ACPError.self) {
    struct Empty: Codable {}
    let _: Empty = try await client.connection.sendRequest(method: "session/load", params: Empty())
  }
  await client.stop()
}
