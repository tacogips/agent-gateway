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
    await connection.sendUpdate(ACPSessionNotification(
      sessionId: request.sessionId,
      update: .agentThoughtChunk(.text("mulling"))
    ))
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

@Test func promptStreamYieldsOrderedUpdatesThenResponse() async throws {
  let (client, _) = await ACPClientConnection.inProcess(agent: EchoAgent())
  _ = try await client.initialize()
  let session = try await client.newSession(ACPNewSessionRequest(cwd: "/tmp"))

  var events: [ACPPromptEvent] = []
  for try await event in client.promptStream(
    ACPPromptRequest(sessionId: session.sessionId, prompt: [.text("hey")])
  ) {
    events.append(event)
  }
  #expect(events.count == 5)
  #expect(events.first == .update(.agentThoughtChunk(.text("mulling"))))
  #expect(events.last == .response(ACPPromptResponse(stopReason: .endTurn)))
  let streamedText = events.compactMap {
    if case .update(.agentMessageChunk(.text(let content))) = $0 { return content.text }
    return nil
  }.joined()
  #expect(streamedText == "hey")
  await client.stop()
}

@Test func promptCollectingAggregatesTheWholeTurn() async throws {
  let (client, _) = await ACPClientConnection.inProcess(agent: EchoAgent())
  _ = try await client.initialize()
  let session = try await client.newSession(ACPNewSessionRequest(cwd: "/tmp"))
  let result = try await client.promptCollecting(
    ACPPromptRequest(sessionId: session.sessionId, prompt: [.text("hey")])
  )
  #expect(result.response.stopReason == .endTurn)
  #expect(result.messageText == "hey")
  #expect(result.thoughtText == "mulling")
  #expect(result.updates.count == 4)
  await client.stop()
}

@Test func unknownSessionUpdateKindsSurviveAsOtherAndRoundTrip() throws {
  let payload = #"{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"web"}]}"#
  let decoded = try JSONDecoder().decode(ACPSessionUpdate.self, from: Data(payload.utf8))
  guard case .other(let value) = decoded else {
    Issue.record("expected .other, got \(decoded)")
    return
  }
  #expect(value["sessionUpdate"]?.stringValue == "available_commands_update")
  let reencoded = try JSONEncoder().encode(decoded)
  let roundTripped = try JSONDecoder().decode(ACPSessionUpdate.self, from: reencoded)
  #expect(roundTripped == decoded)
}

@Test func toolCallContentSupportsDiffTerminalAndUnknownTypes() throws {
  let payload = #"""
  {"sessionUpdate":"tool_call","toolCallId":"call-9","title":"edit",
   "locations":[{"path":"/tmp/a.swift","line":3}],
   "content":[
     {"type":"content","content":{"type":"text","text":"done"}},
     {"type":"diff","path":"/tmp/a.swift","oldText":"a","newText":"b"},
     {"type":"terminal","terminalId":"term-1"},
     {"type":"future_thing","x":1}
   ]}
  """#
  let update = try JSONDecoder().decode(ACPSessionUpdate.self, from: Data(payload.utf8))
  guard case .toolCall(let call) = update else {
    Issue.record("expected .toolCall, got \(update)")
    return
  }
  #expect(call.locations == [ACPToolCallLocation(path: "/tmp/a.swift", line: 3)])
  #expect(call.content?.count == 4)
  #expect(call.content?[1] == .diff(ACPToolCallDiff(path: "/tmp/a.swift", oldText: "a", newText: "b")))
  #expect(call.content?[2] == .terminal(terminalId: "term-1"))
  if case .other(let value)? = call.content?[3] {
    #expect(value["type"]?.stringValue == "future_thing")
  } else {
    Issue.record("expected .other fallback for unknown content type")
  }
  let reencoded = try JSONEncoder().encode(update)
  #expect(try JSONDecoder().decode(ACPSessionUpdate.self, from: reencoded) == update)
}

@Test func lineBufferSplitsChunksAndFlushesTrailingBytes() {
  var buffer = ACPLineBuffer()
  #expect(buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)) == [Data("{\"a\":1}".utf8)])
  #expect(buffer.append(Data(":2}\n\n".utf8)) == [Data("{\"b\":2}".utf8)])
  #expect(buffer.flush() == nil)
  _ = buffer.append(Data("tail".utf8))
  #expect(buffer.flush() == Data("tail".utf8))
}

@Test func setModelDefaultsToMethodNotFoundForAgentsWithoutModels() async throws {
  let (client, _) = await ACPClientConnection.inProcess(agent: EchoAgent())
  _ = try await client.initialize()
  do {
    try await client.setModel(sessionId: "echo-session", modelId: "some-model")
    Issue.record("expected method_not_found from the default setModel")
  } catch let error as ACPError {
    #expect(error.code == -32601)
  }
  await client.stop()
}

@Test func newSessionResponseModelsRoundTripThroughWireFormat() throws {
  let response = ACPNewSessionResponse(
    sessionId: "sess-1",
    models: ACPSessionModelState(
      availableModels: [
        ACPModelInfo(modelId: "gpt-5", name: "GPT-5"),
        ACPModelInfo(modelId: "gpt-5-mini", name: "GPT-5 mini", description: "fast")
      ],
      currentModelId: "gpt-5"
    )
  )
  let data = try JSONEncoder().encode(response)
  let decoded = try JSONDecoder().decode(ACPNewSessionResponse.self, from: data)
  #expect(decoded == response)
  let json = try #require(String(bytes: data, encoding: .utf8))
  #expect(json.contains(#""currentModelId":"gpt-5""#))
  #expect(json.contains(#""availableModels""#))
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
