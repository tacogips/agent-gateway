import AgentGateway
import Foundation
import Testing
@testable import AgentGatewayAppCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite struct GatewayTranscriptionFailureTests {
  let now = Date(timeIntervalSince1970: 1_700_000_000)

  @Test func retryAfter() {
    let cases: [(String?, Int?)] = [
      ("7", 7), (" 7 ", 7), ("Tue, 14 Nov 2023 22:13:50 GMT", 30),
      ("Wed, 21 Oct 2015 07:28:00 GMT", 0), ("-1", nil), ("7.5", nil),
      ("", nil), ("soon", nil), (nil, nil), ("99999999999999999999", nil)
    ]
    for (value, expected) in cases { #expect(parseGatewayRetryAfter(value, now: now) == expected) }
  }

  @Test func classification() {
    let cases: [((Int?, String?), (String?, GatewayTranscriptionFailure.Classification))] = [
      ((429, "insufficient_quota"), ("credit_balance_exhausted", .quotaExhausted)),
      ((429, nil), ("insufficient_quota", .quotaExhausted)), ((429, "rate_limit_exceeded"), (nil, .rateLimited)),
      ((429, "RESOURCE_EXHAUSTED"), ("429", .rateLimited)), ((429, nil), (nil, .rateLimited)),
      ((402, nil), ("402", .quotaExhausted)), ((401, nil), (nil, .authFailed)), ((403, nil), (nil, .authFailed)),
      ((400, nil), (nil, .invalidRequest)), ((404, nil), (nil, .invalidRequest)),
      ((413, nil), (nil, .invalidRequest)), ((422, nil), (nil, .invalidRequest)),
      ((500, nil), (nil, .serverError)), ((503, nil), (nil, .serverError)),
      ((302, nil), (nil, .unknown)), ((200, nil), (nil, .unknown)), ((nil, nil), (nil, .unknown)),
      ((503, "insufficient_quota"), (nil, .quotaExhausted))
    ]
    for ((status, type), (code, expected)) in cases {
      #expect(classifyGatewayTranscriptionFailure(httpStatus: status, vendorErrorType: type, vendorErrorCode: code)
        == expected)
    }
  }

  @Test func vendorFields() {
    let cases: [((String, String?), (String?, String?))] = [
      ((#"{"error":{"message":"m","type":"insufficient_quota","code":"credit_balance_exhausted"}}"#,
        "insufficient_quota"), ("credit_balance_exhausted", "m")),
      ((#"{"error":{"code":429,"message":"m","status":"RESOURCE_EXHAUSTED"}}"#, "RESOURCE_EXHAUSTED"), ("429", "m")),
      ((#"{"error":{"code":402,"message":"m","metadata":{}}}"#, nil), ("402", "m")),
      ((#"{"error":"plain"}"#, nil), (nil, "plain")), (("not json", nil), (nil, nil)), (("{}", nil), (nil, nil))
    ]
    for ((body, type), (code, message)) in cases {
      let fields = parseGatewayVendorErrorFields(Data(body.utf8))
      #expect(fields.type == type)
      #expect(fields.code == code)
      #expect(fields.message == message)
    }
  }

  func response(_ status: Int = 429) throws -> HTTPURLResponse {
    let url = try #require(URL(string: "https://example.invalid"))
    return try #require(HTTPURLResponse(url: url, statusCode: status,
                                        httpVersion: nil, headerFields: ["Retry-After": "7"]))
  }

  @Test func httpFactory() throws {
    let body = #"{"error":{"message":"m","type":"insufficient_quota","code":"credit_balance_exhausted"}}"#
    let failure = GatewayTranscriptionFailure.httpFailure(
      vendor: .openAI, data: Data(body.utf8), response: try response(), secret: "unused-secret", now: now
    )
    #expect(failure.classification == .quotaExhausted)
    #expect(failure.httpStatus == 429)
    #expect(failure.retryAfterSeconds == 7)
    #expect(failure.vendorErrorCode == "credit_balance_exhausted")
    #expect(failure.rpcError == GatewayRPCError(code: -32010, message: failure.message))
    #expect(failure.errorDescription == failure.message)
    let long = GatewayTranscriptionFailure.httpFailure(
      vendor: .openAI, data: Data(String(repeating: "x", count: 600).utf8),
      response: try response(), secret: "unused-secret", now: now
    )
    #expect(long.message == "vendor HTTP 429: " + String(repeating: "x", count: 500))
    let json = #"{"error":{"message":""# + String(repeating: "x", count: 20_000)
      + #"","code":"credit_balance_exhausted"}}"#
    let large = GatewayTranscriptionFailure.httpFailure(
      vendor: .openAI, data: Data(json.utf8), response: try response(), secret: "unused-secret", now: now
    )
    #expect((large.rawBody?.utf8.count ?? 0) <= 16_384)
    #expect(large.vendorErrorCode == "credit_balance_exhausted")
  }

  @Test func redactionBeforeBothLimits() throws {
    let secret = "fixture-secret-0123456789abcdef"
    for padding in [480, 16_370] {
      let body = String(repeating: "x", count: padding) + secret + String(repeating: "x", count: 100)
      let failure = GatewayTranscriptionFailure.httpFailure(
        vendor: .openAI, data: Data(body.utf8), response: try response(), secret: secret, now: now
      )
      let raw = try #require(failure.rawBody)
      #expect(raw.contains("[REDACTED]"))
      if padding == 480 { #expect(failure.message.contains("[REDACTED]")) }
      for count in 8...31 {
        #expect(!raw.contains(String(secret.prefix(count))))
        #expect(!failure.message.contains(String(secret.prefix(count))))
      }
    }
    #expect(gatewayUTF8Prefix("aé", maxBytes: 2) == "a")
    #expect(gatewayRedactedText(Data([0x61, 0xff]), secret: "") == "a�")
  }

  @Test func otherFactories() {
    let transport = GatewayTranscriptionFailure.transportFailure(
      vendor: .openAI, error: URLError(.timedOut), secret: "unused-secret"
    )
    #expect(transport.classification == .transport)
    #expect(transport.httpStatus == nil)
    #expect(transport.message.hasPrefix("vendor request failed: URLError(-1001)"))
    let response = GatewayTranscriptionFailure.responseFailure(
      vendor: .openAI, httpStatus: 200, data: Data("invalid".utf8),
      message: "vendor returned invalid transcription JSON", secret: "unused-secret"
    )
    #expect(response.classification == .unknown)
    #expect(response.httpStatus == 200)
    #expect(response.rawBody == "invalid")
  }
}
