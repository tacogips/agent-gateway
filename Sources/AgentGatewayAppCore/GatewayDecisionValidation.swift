import ACP
import AgentGateway
import Foundation

extension GatewayDecisionRequest {
  func validate() throws {
    func invalid(_ message: String) -> GatewayRPCError { GatewayRPCError(code: -32602, message: message) }
    guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid("decision model is required") }
    switch state {
    case .string, .object, .array: break
    default: throw invalid("decision state must be a string, object, or array")
    }
    guard !questions.isEmpty else { throw invalid("decision questions must not be empty") }
    guard (sessionID?.count ?? 0) <= 256, (user?.count ?? 0) <= 256 else {
      throw invalid("decision session_id and user must be at most 256 characters")
    }
    for (id, question) in questions {
      guard !id.isEmpty else { throw invalid("decision question id must not be empty") }
      let instructions: String
      switch question {
      case .choice(let text, let criteria):
        instructions = text
        guard !criteria.isEmpty, criteria.allSatisfy({ !$0.key.isEmpty && !$0.value.isEmpty }) else {
          throw invalid("choice criteria must contain named descriptions")
        }
      case .score(let text, let criteria):
        instructions = text
        guard !criteria.isEmpty, criteria.allSatisfy({ !$0.isEmpty }) else {
          throw invalid("score criteria must contain ordered descriptions")
        }
      case .noul(let text, let criteria):
        instructions = text
        if let criteria {
          guard Set(criteria.keys) == ["true", "false"], criteria.values.allSatisfy({ !$0.isEmpty }) else {
            throw invalid("noul criteria must describe true and false")
          }
        }
      }
      guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw invalid("decision instructions must not be empty")
      }
    }
  }
}

extension GatewayDecisionResult {
  func validate(for request: GatewayDecisionRequest) throws {
    let invalid = GatewayRPCError(code: -32031, message: "invalid OpenRouter decision response")
    guard Set(answers.keys) == Set(request.questions.keys), !model.isEmpty,
          usage.inputTokens >= 0, usage.outputTokens >= 0, usage.cost.isFinite, usage.cost >= 0 else { throw invalid }
    func probability(_ value: Double) -> Bool { value.isFinite && (0...1).contains(value) }
    for (id, question) in request.questions {
      switch (question, answers[id]) {
      case (.choice(_, let criteria), .choice(let choice, let probabilities, let confidence)):
        guard criteria[choice] != nil, Set(probabilities.keys) == Set(criteria.keys),
              probabilities.values.allSatisfy(probability), probability(confidence) else { throw invalid }
      case (.score(_, let criteria), .score(let score, let legend, let probabilities, let confidence)):
        let indices = Set(criteria.indices.map(String.init))
        guard score.isFinite, (0...Double(criteria.count - 1)).contains(score),
              Set(legend.keys) == indices, Set(probabilities.keys) == indices,
              probabilities.values.allSatisfy(probability), probability(confidence) else { throw invalid }
      case (.noul, .noul(let value)):
        guard probability(value) else { throw invalid }
      default: throw invalid
      }
    }
  }
}
