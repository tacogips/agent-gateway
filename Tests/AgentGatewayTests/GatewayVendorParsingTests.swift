import Testing
@testable import AgentGateway
@testable import AgentGatewayAppCore

@Test func claudeCodeStreamEventsCarryTokenLevelDeltas() {
  let text = parseVendorJSON(
    #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}},"session_id":"s1"}"#,
    vendor: .claudeCode
  )
  #expect(text.delta == "Hel")
  #expect(text.sessionId == "s1")

  let thinking = parseVendorJSON(
    #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}},"session_id":"s1"}"#,
    vendor: .claudeCode
  )
  #expect(thinking.delta == nil)
  #expect(thinking.thinkingDelta == "hmm")
  #expect(thinking.event(vendorPayload: "{}").channel == .thinking)
}

@Test func claudeCodeResultCarriesUsage() {
  let parsed = parseVendorJSON(
    #"{"type":"result","subtype":"success","result":"done","usage":{"input_tokens":10,"output_tokens":4},"session_id":"s1"}"#,
    vendor: .claudeCode
  )
  #expect(parsed.snapshot == "done")
  #expect(parsed.usage == GatewayUsage(inputTokens: 10, outputTokens: 4, totalTokens: 14))
}

@Test func openAIReasoningDeltasAreThoughtsNotAnswerText() {
  let reasoning = parseVendorJSON(
    #"{"type":"response.reasoning_summary_text.delta","delta":"weighing options"}"#,
    vendor: .openAI
  )
  #expect(reasoning.delta == nil)
  #expect(reasoning.thinkingDelta == "weighing options")

  let text = parseVendorJSON(
    #"{"type":"response.output_text.delta","delta":"Hi"}"#,
    vendor: .openAI
  )
  #expect(text.delta == "Hi")

  let completed = parseVendorJSON(
    #"{"type":"response.completed","response":{"id":"resp-1","usage":{"input_tokens":7,"output_tokens":2,"total_tokens":9}}}"#,
    vendor: .openAI
  )
  #expect(completed.usage == GatewayUsage(inputTokens: 7, outputTokens: 2, totalTokens: 9))
  #expect(completed.sessionId == "resp-1")
}

@Test func anthropicUsageIsMergedAcrossMessageStartAndDelta() {
  let start = parseVendorJSON(
    #"{"type":"message_start","message":{"id":"msg-1","usage":{"input_tokens":12}}}"#,
    vendor: .anthropic
  )
  let delta = parseVendorJSON(
    #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#,
    vendor: .anthropic
  )
  let merged = GatewayUsage.merge(start.usage, delta.usage)
  #expect(merged == GatewayUsage(inputTokens: 12, outputTokens: 5, totalTokens: 17))

  let thinking = parseVendorJSON(
    #"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"let me see"}}"#,
    vendor: .anthropic
  )
  #expect(thinking.thinkingDelta == "let me see")
}

@Test func geminiUsageMetadataIsParsed() {
  let parsed = parseVendorJSON(
    #"{"candidates":[{"content":{"parts":[{"text":"Hi"}]}}],"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":1,"totalTokenCount":4},"responseId":"g1"}"#,
    vendor: .gemini
  )
  #expect(parsed.delta == "Hi")
  #expect(parsed.usage == GatewayUsage(inputTokens: 3, outputTokens: 1, totalTokens: 4))
}

@Test func codexReasoningItemsAndTurnUsageAreParsed() {
  let reasoning = parseVendorJSON(
    #"{"type":"item.completed","item":{"type":"reasoning","text":"planning"},"thread_id":"t1"}"#,
    vendor: .codex
  )
  #expect(reasoning.thinkingDelta == "planning")
  #expect(reasoning.sessionId == "t1")

  let turn = parseVendorJSON(
    #"{"type":"turn.completed","usage":{"input_tokens":20,"output_tokens":6}}"#,
    vendor: .codex
  )
  #expect(turn.usage == GatewayUsage(inputTokens: 20, outputTokens: 6, totalTokens: 26))
}

@Test func claudeCLICommandRequestsPartialMessageStreaming() throws {
  let command = try cliCommand(GatewayExecuteParams(
    vendor: .claudeCode, model: "claude-sonnet-5", prompt: "hi"
  ))
  #expect(command.executable == "claude")
  #expect(command.arguments.contains("--include-partial-messages"))
  #expect(command.arguments.contains("stream-json"))
}
