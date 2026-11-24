import Foundation
import Testing
@testable import ACP

// MARK: - Fixtures

/// Sends raw JSON-RPC lines to a server and collects what it writes back.
private final class RawPeer: @unchecked Sendable {
  private let transport: ACPInMemoryTransport
  private var iterator: AsyncStream<Data>.Iterator

  init(v1: (any ACPAgent)?, v2: (any ACPV2Agent)?) async {
    let (clientSide, agentSide) = ACPInMemoryTransport.pair()
    transport = clientSide
    iterator = clientSide.lines.makeAsyncIterator()
    await ACPAgentServer(v1: v1, v2: v2, transport: agentSide).start()
  }

  func send(_ line: String) {
    transport.send(line: Data(line.utf8))
  }

  /// The next message the server wrote.
  func next() async throws -> ACPJSONValue {
    let line = try #require(await iterator.next())
    return try JSONDecoder().decode(ACPJSONValue.self, from: line)
  }

  func request(_ line: String) async throws -> ACPJSONValue {
    send(line)
    return try await next()
  }

  func close() {
    transport.close()
  }
}

private struct V1Agent: ACPAgent {
  func initialize(_ request: ACPInitializeRequest) async throws -> ACPInitializeResponse {
    ACPInitializeResponse(agentInfo: ACPImplementation(name: "v1", version: "1"))
  }

  func newSession(
    _ request: ACPNewSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPNewSessionResponse {
    ACPNewSessionResponse(sessionId: "v1-session")
  }

  func prompt(
    _ request: ACPPromptRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPPromptResponse {
    // Stays pending until the request is cancelled.
    try await Task.sleep(for: .seconds(30))
    return ACPPromptResponse(stopReason: .endTurn)
  }

  func cancel(_ notification: ACPCancelNotification) async {}
}

/// Minimal v2 agent: one scripted turn per prompt. Every update of the
/// turn, including the idle state, is sent before the prompt response, so
/// clients are exercised on the "idle arrives first" ordering.
private actor V2Agent: ACPV2Agent {
  enum Script: Sendable {
    case reply(String)
    case fail(ACPError)
  }

  private let script: Script
  private(set) var cancelled: [ACPSessionID] = []
  private var messageCount = 0

  init(script: Script = .reply("pong")) {
    self.script = script
  }

  func initialize(_ request: ACPV2InitializeRequest) async throws -> ACPV2InitializeResponse {
    ACPV2InitializeResponse(
      info: ACPImplementation(name: "v2", version: "2"),
      capabilities: ACPV2AgentCapabilities(session: ACPV2SessionCapabilities())
    )
  }

  func newSession(
    _ request: ACPV2NewSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPV2NewSessionResponse {
    ACPV2NewSessionResponse(sessionId: "v2-session")
  }

  func resumeSession(
    _ request: ACPV2ResumeSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPV2ResumeSessionResponse {
    ACPV2ResumeSessionResponse()
  }

  func listSessions(
    _ request: ACPListSessionsRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPListSessionsResponse {
    ACPListSessionsResponse(sessions: [ACPSessionInfo(sessionId: "v2-session", cwd: "/tmp")])
  }

  func closeSession(_ request: ACPSessionRequest, connection: ACPAgentSideConnection) async throws {}

  func submitPrompt(
    _ request: ACPV2PromptRequest, connection: ACPAgentSideConnection
  ) async -> ACPV2PromptSubmission {
    messageCount += 1
    let messageId = "user-\(messageCount)"
    let sessionId = request.sessionId
    connection.sendUpdate(.userMessage(ACPV2Message(messageId: messageId, content: request.prompt)), sessionId: sessionId)
    connection.sendUpdate(.stateUpdate(.running()), sessionId: sessionId)
    switch script {
    case .reply(let text):
      connection.sendUpdate(
        .agentMessageChunk(ACPV2ContentChunk(messageId: "agent-1", content: .text(text))), sessionId: sessionId
      )
      connection.sendUpdate(.stateUpdate(.idle(stopReason: .endTurn)), sessionId: sessionId)
    case .fail(let error):
      connection.sendUpdate(.stateUpdate(.idle(stopReason: .error, error: error)), sessionId: sessionId)
    }
    return .inserted(messageId: messageId)
  }

  func cancel(_ notification: ACPCancelNotification, connection: ACPAgentSideConnection) async {
    cancelled.append(notification.sessionId)
  }
}

private let initializeV1 = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#
private let initializeV2 =
  #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2,"info":{"name":"t","version":"1"}}}"#

// MARK: - Envelope rules

@Test func batchesAreRejectedWithInvalidRequestAndNullID() async throws {
  let peer = await RawPeer(v1: V1Agent(), v2: nil)
  let response = try await peer.request(#"[{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}]"#)
  #expect(response["error"]?["code"]?.integerValue == -32600)
  #expect(response["id"] == .null)
  peer.close()
}

@Test func requestWithNullIDIsRejectedNotTreatedAsNotification() async throws {
  let peer = await RawPeer(v1: V1Agent(), v2: nil)
  let response = try await peer.request(#"{"jsonrpc":"2.0","id":null,"method":"initialize","params":{"protocolVersion":1}}"#)
  #expect(response["error"]?["code"]?.integerValue == -32600)
  #expect(response["id"] == .null)
  peer.close()
}

@Test func malformedJSONIsAParseError() async throws {
  let peer = await RawPeer(v1: V1Agent(), v2: nil)
  let response = try await peer.request("{not json")
  #expect(response["error"]?["code"]?.integerValue == -32700)
  peer.close()
}

// MARK: - Version negotiation

@Test func dualStackServerSelectsTheRequestedVersionShape() async throws {
  let v1Peer = await RawPeer(v1: V1Agent(), v2: V2Agent())
  let v1 = try await v1Peer.request(initializeV1)
  #expect(v1["result"]?["protocolVersion"]?.integerValue == 1)
  #expect(v1["result"]?["agentInfo"]?["name"]?.stringValue == "v1")
  #expect(v1["result"]?["info"] == nil)
  v1Peer.close()

  let v2Peer = await RawPeer(v1: V1Agent(), v2: V2Agent())
  let v2 = try await v2Peer.request(initializeV2)
  #expect(v2["result"]?["protocolVersion"]?.integerValue == 2)
  #expect(v2["result"]?["info"]?["name"]?.stringValue == "v2")
  #expect(v2["result"]?["capabilities"]?["session"] == .object([:]))
  // v1 field names never appear in a v2 response.
  #expect(v2["result"]?["agentCapabilities"] == nil)
  v2Peer.close()
}

@Test func newerRequestedVersionSelectsLatestSupportedAndIgnoresUnparseableParams() async throws {
  let peer = await RawPeer(v1: V1Agent(), v2: V2Agent())
  // Written for a future version: no `info`, unknown fields.
  let response = try await peer.request(
    #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":65535,"future":{"x":1}}}"#
  )
  #expect(response["result"]?["protocolVersion"]?.integerValue == 2)
  peer.close()
}

@Test func v1OnlyServerSelectsV1ForAV2Request() async throws {
  let peer = await RawPeer(v1: V1Agent(), v2: nil)
  let response = try await peer.request(initializeV2)
  #expect(response["result"]?["protocolVersion"]?.integerValue == 1)
  #expect(response["result"]?["agentInfo"]?["name"]?.stringValue == "v1")
  peer.close()
}

@Test func v2OnlyServerRejectsV1WithUnsupportedProtocolVersion() async throws {
  let peer = await RawPeer(v1: nil, v2: V2Agent())
  let response = try await peer.request(initializeV1)
  #expect(response["error"]?["code"]?.integerValue == -32022)
  #expect(response["error"]?["data"]?["requested"]?.integerValue == 1)
  #expect(response["error"]?["data"]?["supported"] == .array([.integer(2)]))
  // The mismatch does not initialize the connection.
  let session = try await peer.request(#"{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}"#)
  #expect(session["error"]?["code"]?.integerValue == -32600)
  peer.close()
}

@Test func malformedProtocolVersionIsInvalidParamsNotAMismatch() async throws {
  let peer = await RawPeer(v1: V1Agent(), v2: V2Agent())
  for params in [#"{}"#, #"{"protocolVersion":"2"}"#, #"{"protocolVersion":1.5}"#, #"{"protocolVersion":70000}"#, #"{"protocolVersion":true}"#] {
    let response = try await peer.request(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":\#(params)}"#)
    #expect(response["error"]?["code"]?.integerValue == -32602, "params: \(params)")
  }
  // A v2 request without the required `info` is malformed for v2.
  let missingInfo = try await peer.request(
    #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":2}}"#
  )
  #expect(missingInfo["error"]?["code"]?.integerValue == -32602)
  peer.close()
}

@Test func requestsBeforeInitializeAreRejectedAndInitializeCannotRepeatAfterOtherRequests() async throws {
  let peer = await RawPeer(v1: V1Agent(), v2: V2Agent())
  let early = try await peer.request(#"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp"}}"#)
  #expect(early["error"]?["code"]?.integerValue == -32600)

  // initialize may repeat before the first other request; the latest wins.
  #expect(try await peer.request(initializeV2)["result"]?["protocolVersion"]?.integerValue == 2)
  #expect(try await peer.request(initializeV1)["result"]?["protocolVersion"]?.integerValue == 1)
  let session = try await peer.request(
    #"{"jsonrpc":"2.0","id":3,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}"#
  )
  #expect(session["result"]?["sessionId"]?.stringValue == "v1-session")

  let late = try await peer.request(initializeV2)
  #expect(late["error"]?["code"]?.integerValue == -32600)
  peer.close()
}

@Test func unknownAndUnadvertisedMethodsAreMethodNotFound() async throws {
  let peer = await RawPeer(v1: V1Agent(), v2: V2Agent())
  _ = try await peer.request(initializeV2)
  for method in ["_vendor/custom", "session/delete", "auth/login", "session/load", "session/set_mode"] {
    let response = try await peer.request(#"{"jsonrpc":"2.0","id":"x","method":"\#(method)","params":{"sessionId":"s","methodId":"m","cwd":"/tmp"}}"#)
    #expect(response["error"]?["code"]?.integerValue == -32601, "method: \(method)")
    #expect(response["id"]?.stringValue == "x")
  }
  peer.close()
}

// MARK: - $/cancel_request

@Test func cancelRequestStillAnswersTheRequestExactlyOnce() async throws {
  let peer = await RawPeer(v1: V1Agent(), v2: nil)
  _ = try await peer.request(initializeV1)
  peer.send(#"{"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{"sessionId":"v1-session","prompt":[{"type":"text","text":"hi"}]}}"#)
  // An unknown id is ignored; the in-flight one is cancelled.
  peer.send(#"{"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":99}}"#)
  peer.send(#"{"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":7}}"#)
  let response = try await peer.next()
  #expect(response["id"]?.integerValue == 7)
  #expect(response["error"]?["code"]?.integerValue == -32800)
  // A second cancel for the answered request produces no second response.
  peer.send(#"{"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":7}}"#)
  let next = try await peer.request(#"{"jsonrpc":"2.0","id":8,"method":"_ping","params":{}}"#)
  #expect(next["id"]?.integerValue == 8)
  peer.close()
}

// MARK: - Wire coding

private func encode<T: Encodable>(_ value: T) throws -> ACPJSONValue {
  let encoder = JSONEncoder()
  return try JSONDecoder().decode(ACPJSONValue.self, from: encoder.encode(value))
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(json.utf8))
}

@Test func messageUpsertsDistinguishOmittedNullAndValue() throws {
  let omitted = try decode(ACPV2SessionUpdate.self, #"{"sessionUpdate":"agent_message","messageId":"m"}"#)
  let cleared = try decode(ACPV2SessionUpdate.self, #"{"sessionUpdate":"agent_message","messageId":"m","content":null}"#)
  let replaced = try decode(
    ACPV2SessionUpdate.self,
    #"{"sessionUpdate":"agent_message","messageId":"m","content":[{"type":"text","text":"a"}],"_meta":{"k":null}}"#
  )
  #expect(omitted == .agentMessage(ACPV2Message(messageId: "m")))
  #expect(cleared == .agentMessage(ACPV2Message(messageId: "m", content: .clear)))
  #expect(replaced == .agentMessage(
    ACPV2Message(messageId: "m", content: .set([.text("a")]), meta: .set(.object(["k": .null])))
  ))
  // The three states survive a round trip, including the explicit null.
  #expect(try encode(omitted)["content"] == nil)
  #expect(try encode(cleared)["content"] == .null)
  #expect(try encode(replaced)["content"] == .array([.object(["type": .string("text"), "text": .string("a")])]))
}

@Test func metadataPatchesApplyByTopLevelKey() {
  var stored: [String: ACPJSONValue]? = ["keep": .integer(1), "drop": .integer(2)]
  ACPPatch<ACPJSONValue>.unchanged.applyMetadata(to: &stored)
  #expect(stored == ["keep": .integer(1), "drop": .integer(2)])
  ACPPatch.set(ACPJSONValue.object(["drop": .null, "add": .string("x")])).applyMetadata(to: &stored)
  #expect(stored == ["keep": .integer(1), "add": .string("x")])
  ACPPatch<ACPJSONValue>.clear.applyMetadata(to: &stored)
  #expect(stored == nil)
}

@Test func idleStateCarriesStopReasonErrorAndUnknownFields() throws {
  let update = try decode(
    ACPV2SessionUpdate.self,
    #"{"sessionUpdate":"state_update","state":"idle","stopReason":"error","error":{"code":-32000,"message":"auth"},"background":[]}"#
  )
  guard case .stateUpdate(let state) = update else {
    Issue.record("expected a state update")
    return
  }
  #expect(state.state == .idle)
  #expect(state.stopReason == .error)
  #expect(state.error == ACPError(code: -32000, message: "auth"))
  #expect(state.background == [])
  #expect(!state.isActive)

  // Custom stop reasons keep their fields; unknown states are not idle.
  let custom = try decode(
    ACPV2StateUpdate.self, #"{"state":"idle","stopReason":"_com.example/budget","limit":3}"#
  )
  #expect(custom.stopReason?.rawValue == "_com.example/budget")
  #expect(custom.extraFields == ["limit": .integer(3)])
  #expect(try encode(custom)["limit"] == .integer(3))
  let future = try decode(ACPV2StateUpdate.self, #"{"state":"compacting"}"#)
  #expect(future.state != .idle)
  #expect(!future.isActive)
}

@Test func unknownUpdatesAndContentBlocksArePreserved() throws {
  let json = #"{"sessionUpdate":"_com.example/widget","payload":{"a":1}}"#
  let update = try decode(ACPV2SessionUpdate.self, json)
  guard case .other(let raw) = update else {
    Issue.record("expected the unknown-variant fallback")
    return
  }
  #expect(raw["payload"]?["a"]?.integerValue == 1)
  #expect(try encode(update) == raw)

  let block = try decode(ACPContentBlock.self, #"{"type":"_com.example/chart","points":[1,2]}"#)
  #expect(block.type == "_com.example/chart")
  #expect(try encode(block)["points"] == .array([.integer(1), .integer(2)]))
}

@Test func toolCallUpsertIsCreatedByItsFirstUpdate() throws {
  let update = try decode(
    ACPV2SessionUpdate.self,
    #"""
    {"sessionUpdate":"tool_call_update","toolCallId":"call_1","title":"Run tests","kind":"execute","status":"paused",
     "capabilities":{"cancel":{}},"name":null,
     "content":[{"type":"diff","changes":[{"operation":"move","oldPath":"/a","path":"/b"}],"patch":{"format":"git_patch","text":"diff --git /a /b"}},
                {"type":"terminal","terminalId":"term_1"},{"type":"session","sessionId":"child"}]}
    """#
  )
  guard case .toolCallUpdate(let call) = update else {
    Issue.record("expected a tool call update")
    return
  }
  #expect(call.status == .set("paused"))
  #expect(call.name == .clear)
  #expect(call.rawInput == .unchanged)
  #expect(call.advertisesCancel)
  #expect(call.content.value?.count == 3)
  if case .diff(let diff)? = call.content.value?.first {
    #expect(diff.changes == [ACPV2Diff.Change(operation: "move", path: "/b", oldPath: "/a")])
    #expect(diff.patch?.format == "git_patch")
  } else {
    Issue.record("expected a structured diff")
  }
  let roundTripped = try JSONDecoder().decode(ACPV2SessionUpdate.self, from: JSONEncoder().encode(update))
  #expect(roundTripped == update)
}

@Test func configOptionsUseVersionSpecificKeyNames() throws {
  let option = ACPSessionConfigOption(
    configId: "model",
    name: "Model",
    category: ACPSessionConfigOption.categoryModel,
    kind: .select(currentValue: "a", options: .grouped([
      ACPSessionConfigOption.SelectGroup(groupId: "fast", name: "Fast", options: [
        ACPSessionConfigOption.SelectOption(value: "a", name: "A")
      ])
    ]))
  )
  let v2 = try encode(option)
  #expect(v2["configId"]?.stringValue == "model")
  #expect(v2["id"] == nil)
  #expect(v2["options"] == .array([.object([
    "groupId": .string("fast"), "name": .string("Fast"),
    "options": .array([.object(["value": .string("a"), "name": .string("A")])])
  ])]))
  let v1 = try encode(ACPSessionConfigOption.V1Coding(option))
  #expect(v1["id"]?.stringValue == "model")
  #expect(v1["configId"] == nil)
  // Readers accept either spelling.
  let fromV1 = try JSONDecoder().decode(ACPSessionConfigOption.self, from: JSONEncoder().encode(v1))
  #expect(fromV1 == option)

  // v2 requires the `type` discriminator on set requests; v1 omits it for ids.
  let request = ACPSetSessionConfigOptionRequest(sessionId: "s", configId: "model", value: .id("a"))
  #expect(try encode(request)["type"]?.stringValue == "id")
  var legacy = request
  legacy.usesV1Encoding = true
  #expect(try encode(legacy)["type"] == nil)
  let boolean = try decode(
    ACPSetSessionConfigOptionRequest.self, #"{"sessionId":"s","configId":"brave","type":"boolean","value":true}"#
  )
  #expect(boolean.value == .boolean(true))
}

@Test func v2SessionRequestsOmitEmptyOptionalLists() throws {
  let request = try encode(ACPV2NewSessionRequest(cwd: "/tmp"))
  #expect(request == .object(["cwd": .string("/tmp")]))
  let response = try encode(ACPV2NewSessionResponse(sessionId: "s"))
  // Setup responses never send `null` lists: omission means none.
  #expect(response == .object(["sessionId": .string("s")]))
  let resume = try decode(
    ACPV2ResumeSessionRequest.self,
    #"{"sessionId":"s","cwd":"/tmp","replayFrom":{"type":"_cursor","at":3},"mcpServers":[{"type":"stdio","name":"fs","command":"/bin/mcp"}]}"#
  )
  #expect(resume.mcpServers.first?.type == "stdio")
  if case .other(let cursor)? = resume.replayFrom {
    #expect(cursor["at"]?.integerValue == 3)
  } else {
    Issue.record("expected the custom replay cursor to be preserved")
  }
}

@Test func textAccumulatorAppliesUpsertSemantics() {
  var text = ACPV2MessageTextAccumulator()
  text.apply(ACPV2Message(messageId: "m1", content: [.text("A")]))
  text.append(ACPV2ContentChunk(messageId: "m1", content: .text("B")))
  #expect(text.text(of: "m1") == "AB")
  // A whole-message update replaces everything accumulated so far.
  text.apply(ACPV2Message(messageId: "m1", content: [.text("C")]))
  text.append(ACPV2ContentChunk(messageId: "m1", content: .text("D")))
  // A chunk for an unseen id creates the message; order is first-seen.
  text.append(ACPV2ContentChunk(messageId: "m2", content: .text("x")))
  text.apply(ACPV2Message(messageId: "m1"))
  #expect(text.messages.map(\.text) == ["CD", "x"])
  text.apply(ACPV2Message(messageId: "m2", content: .clear))
  #expect(text.joinedText == "CD")
}

// MARK: - Client

@Test func clientNegotiatesV2AndRunsATurnToTheIdleState() async throws {
  let (client, _) = await ACPClientConnection.inProcess(v1: V1Agent(), v2: V2Agent(script: .reply("pong")))
  let negotiated = try await client.negotiate(
    ACPV2InitializeRequest(info: ACPImplementation(name: "test", version: "1"))
  )
  #expect(negotiated.protocolVersion == 2)
  #expect(await client.negotiatedVersion == 2)
  let session = try await client.newSessionV2(ACPV2NewSessionRequest(cwd: "/tmp"))
  let turn = try await client.promptTurnCollecting(
    ACPV2PromptRequest(sessionId: session.sessionId, prompt: [.text("ping")])
  )
  #expect(turn.messageId == "user-1")
  #expect(turn.stopReason == .endTurn)
  #expect(turn.messageText == "pong")
  #expect(turn.updates.first?.kind == "user_message")
  #expect(try await client.listSessions().sessions.map(\.sessionId) == ["v2-session"])
  await client.stop()
}

@Test func clientFallsBackToV1WhenTheAgentOnlySpeaksV1() async throws {
  let (client, _) = await ACPClientConnection.inProcess(v1: V1Agent(), v2: nil)
  let negotiated = try await client.negotiate(
    ACPV2InitializeRequest(info: ACPImplementation(name: "test", version: "1"))
  )
  guard case .v1(let response) = negotiated else {
    Issue.record("expected the agent to select v1")
    return
  }
  #expect(response.agentInfo?.name == "v1")
  #expect(await client.negotiatedVersion == 1)
  // The connection continues with the v1 API.
  let session = try await client.newSession(ACPNewSessionRequest(cwd: "/tmp"))
  #expect(session.sessionId == "v1-session")
  await client.stop()
}

@Test func failureAfterInsertionArrivesAsIdleErrorNotAsAThrow() async throws {
  let failure = ACPError(code: -32010, message: "vendor HTTP 500")
  let (client, _) = await ACPClientConnection.inProcess(v1: nil, v2: V2Agent(script: .fail(failure)))
  _ = try await client.negotiate(ACPV2InitializeRequest(info: ACPImplementation(name: "test", version: "1")))
  let turn = try await client.promptTurnCollecting(
    ACPV2PromptRequest(sessionId: "v2-session", prompt: [.text("ping")])
  )
  #expect(turn.stopReason == .error)
  #expect(turn.finalState.error == failure)
  await client.stop()
}

@Test func v1ClientAgainstV2OnlyAgentSeesAnInitializationError() async throws {
  let (client, _) = await ACPClientConnection.inProcess(v1: nil, v2: V2Agent())
  do {
    _ = try await client.initialize()
    Issue.record("expected initialize to fail")
  } catch let error as ACPError {
    #expect(error.code == ACPErrorCode.unsupportedProtocolVersion)
    #expect(error.data?["supported"] == .array([.integer(2)]))
  }
  await client.stop()
}
