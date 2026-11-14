import ACP
import Foundation

/// A non-generative OpenRouter Decisions request. Each question evaluates the same state.
public struct GatewayDecisionRequest: Codable, Equatable, Sendable {
  public var model: String
  public var state: ACPJSONValue
  public var questions: [String: GatewayDecisionQuestion]
  public var provider: [String: ACPJSONValue]?
  public var sessionID: String?
  public var trace: [String: ACPJSONValue]?
  public var user: String?

  public init(
    model: String = "typesafe/jev-1.13",
    state: ACPJSONValue,
    questions: [String: GatewayDecisionQuestion],
    provider: [String: ACPJSONValue]? = nil,
    sessionID: String? = nil,
    trace: [String: ACPJSONValue]? = nil,
    user: String? = nil
  ) {
    self.model = model
    self.state = state
    self.questions = questions
    self.provider = provider
    self.sessionID = sessionID
    self.trace = trace
    self.user = user
  }

  enum CodingKeys: String, CodingKey {
    case model, state, questions, provider, trace, user
    case sessionID = "session_id"
  }
}

public enum GatewayDecisionQuestion: Equatable, Sendable {
  case choice(instructions: String, criteria: [String: String])
  case score(instructions: String, criteria: [String])
  /// Optional criteria describe the true and false outcomes.
  case noul(instructions: String, criteria: [String: String]? = nil)
}

extension GatewayDecisionQuestion: Codable {
  private enum CodingKeys: String, CodingKey { case type, instructions, criteria }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let instructions = try container.decode(String.self, forKey: .instructions)
    switch try container.decode(String.self, forKey: .type) {
    case "choice":
      self = .choice(instructions: instructions, criteria: try container.decode([String: String].self, forKey: .criteria))
    case "score":
      self = .score(instructions: instructions, criteria: try container.decode([String].self, forKey: .criteria))
    case "noul":
      self = .noul(instructions: instructions, criteria: try container.decodeIfPresent([String: String].self, forKey: .criteria))
    default:
      throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown decision question type")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .choice(let instructions, let criteria):
      try container.encode("choice", forKey: .type)
      try container.encode(instructions, forKey: .instructions)
      try container.encode(criteria, forKey: .criteria)
    case .score(let instructions, let criteria):
      try container.encode("score", forKey: .type)
      try container.encode(instructions, forKey: .instructions)
      try container.encode(criteria, forKey: .criteria)
    case .noul(let instructions, let criteria):
      try container.encode("noul", forKey: .type)
      try container.encode(instructions, forKey: .instructions)
      try container.encodeIfPresent(criteria, forKey: .criteria)
    }
  }
}

/// Numbers are evidence for the caller's routing policy; no action is executed by the gateway.
public enum GatewayDecisionAnswer: Equatable, Sendable {
  case choice(choice: String, probabilities: [String: Double], confidence: Double)
  case score(score: Double, legend: [String: String], probabilities: [String: Double], confidence: Double)
  case noul(Double)
}

extension GatewayDecisionAnswer: Codable {
  private enum CodingKeys: String, CodingKey { case type, choice, probabilities, confidence, score, legend, noul }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .type) {
    case "choice":
      self = .choice(
        choice: try container.decode(String.self, forKey: .choice),
        probabilities: try container.decode([String: Double].self, forKey: .probabilities),
        confidence: try container.decode(Double.self, forKey: .confidence)
      )
    case "score":
      self = .score(
        score: try container.decode(Double.self, forKey: .score),
        legend: try container.decode([String: String].self, forKey: .legend),
        probabilities: try container.decode([String: Double].self, forKey: .probabilities),
        confidence: try container.decode(Double.self, forKey: .confidence)
      )
    case "noul": self = .noul(try container.decode(Double.self, forKey: .noul))
    default:
      throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown decision answer type")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .choice(let choice, let probabilities, let confidence):
      try container.encode("choice", forKey: .type)
      try container.encode(choice, forKey: .choice)
      try container.encode(probabilities, forKey: .probabilities)
      try container.encode(confidence, forKey: .confidence)
    case .score(let score, let legend, let probabilities, let confidence):
      try container.encode("score", forKey: .type)
      try container.encode(score, forKey: .score)
      try container.encode(legend, forKey: .legend)
      try container.encode(probabilities, forKey: .probabilities)
      try container.encode(confidence, forKey: .confidence)
    case .noul(let probability):
      try container.encode("noul", forKey: .type)
      try container.encode(probability, forKey: .noul)
    }
  }
}

public struct GatewayDecisionResult: Codable, Equatable, Sendable {
  public var model: String
  public var answers: [String: GatewayDecisionAnswer]
  public var usage: GatewayDecisionUsage
  public var id: String?
  public var provider: String?

  public init(model: String, answers: [String: GatewayDecisionAnswer], usage: GatewayDecisionUsage, id: String? = nil, provider: String? = nil) {
    self.model = model
    self.answers = answers
    self.usage = usage
    self.id = id
    self.provider = provider
  }
}

public struct GatewayDecisionUsage: Codable, Equatable, Sendable {
  public var inputTokens: Int
  public var outputTokens: Int
  public var cost: Double

  public init(inputTokens: Int, outputTokens: Int, cost: Double) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cost = cost
  }

  enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cost
  }
}
