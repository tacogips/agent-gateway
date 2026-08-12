import AgentGateway
import Foundation

public final class GatewayJSONLWriter: @unchecked Sendable {
  private let lock = NSLock()
  private let writeData: @Sendable (Data) -> Void
  private let encoder = JSONEncoder()

  public init(writeData: @escaping @Sendable (Data) -> Void) {
    self.writeData = writeData
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  }

  public func write<T: Encodable>(_ value: T) {
    lock.withLock {
      guard let data = try? encoder.encode(value) else { return }
      writeData(data + Data([10]))
    }
  }
}

public struct GatewayJSONLServer: Sendable {
  public var executor: any GatewayExecuting

  public init(executor: any GatewayExecuting = ProductionGatewayExecutor()) {
    self.executor = executor
  }

  public func serveStandardIO() async -> Int32 {
    let writer = GatewayJSONLWriter { FileHandle.standardOutput.write($0) }
    while let line = readLine() {
      await handle(line: line, writer: writer)
    }
    return 0
  }

  public func handle(line: String, writer: GatewayJSONLWriter) async {
    let request: GatewayRPCRequest
    do {
      request = try JSONDecoder().decode(GatewayRPCRequest.self, from: Data(line.utf8))
    } catch {
      writer.write(GatewayRPCResponse(id: "", error: GatewayRPCError(code: -32700, message: "invalid JSONL request")))
      return
    }
    await handle(request: request, writer: writer)
  }

  public func handle(request: GatewayRPCRequest, writer: GatewayJSONLWriter) async {
    guard request.jsonrpc == GatewayProtocolVersion.jsonRPC, request.method == "agent/execute" else {
      writer.write(GatewayRPCResponse(id: request.id, error: GatewayRPCError(code: -32601, message: "method not found")))
      return
    }
    let sequence = GatewaySequence()
    do {
      let result = try await executor.execute(request.params) { type, channel, delta, snapshot, payload in
        writer.write(GatewayRPCNotification(event: GatewayStreamEvent(
          requestId: request.id,
          sequence: sequence.next(),
          vendor: request.params.vendor,
          type: type,
          channel: channel,
          textDelta: delta,
          textSnapshot: snapshot,
          vendorPayload: payload
        )))
      }
      writer.write(GatewayRPCResponse(id: request.id, result: result))
    } catch let error as GatewayRPCError {
      writer.write(GatewayRPCResponse(id: request.id, error: error))
    } catch {
      writer.write(GatewayRPCResponse(id: request.id, error: GatewayRPCError(code: -32603, message: error.localizedDescription)))
    }
  }
}

private final class GatewaySequence: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func next() -> Int {
    lock.withLock {
      value += 1
      return value
    }
  }
}
