import Foundation

/// Line-oriented transport for newline-delimited JSON-RPC messages.
/// `lines` yields complete JSON lines (without the trailing newline) and
/// finishes when the peer closes the stream.
public protocol ACPTransport: Sendable {
  var lines: AsyncStream<Data> { get }
  func send(line: Data)
  func close()
}

/// Transport over a pair of `FileHandle`s (stdio or pipes).
public final class ACPFileHandleTransport: ACPTransport, @unchecked Sendable {
  public let lines: AsyncStream<Data>
  private let output: FileHandle
  private let input: FileHandle
  private let writeLock = NSLock()

  public init(input: FileHandle, output: FileHandle) {
    self.input = input
    self.output = output
    var continuation: AsyncStream<Data>.Continuation!
    lines = AsyncStream { continuation = $0 }
    let splitter = ACPLineSplitter(continuation: continuation)
    input.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        splitter.finish()
      } else {
        splitter.consume(data)
      }
    }
  }

  public static func standardIO() -> ACPFileHandleTransport {
    ACPFileHandleTransport(input: .standardInput, output: .standardOutput)
  }

  public func send(line: Data) {
    writeLock.withLock {
      output.write(line + Data([10]))
    }
  }

  public func close() {
    input.readabilityHandler = nil
    if input !== FileHandle.standardInput {
      try? input.close()
    }
    if output !== FileHandle.standardOutput {
      try? output.close()
    }
  }
}

/// In-memory duplex transport; `pair()` returns two connected endpoints.
/// Useful for tests and for hosting a client and an agent in one process.
public final class ACPInMemoryTransport: ACPTransport, @unchecked Sendable {
  public let lines: AsyncStream<Data>
  private let incoming: AsyncStream<Data>.Continuation
  private let lock = NSLock()
  private var outgoing: AsyncStream<Data>.Continuation?
  private var buffered: [Data] = []
  private var closed = false

  private init() {
    var continuation: AsyncStream<Data>.Continuation!
    lines = AsyncStream { continuation = $0 }
    incoming = continuation
  }

  public static func pair() -> (ACPInMemoryTransport, ACPInMemoryTransport) {
    let first = ACPInMemoryTransport()
    let second = ACPInMemoryTransport()
    first.connect(to: second)
    second.connect(to: first)
    return (first, second)
  }

  private func connect(to peer: ACPInMemoryTransport) {
    lock.withLock {
      outgoing = peer.incoming
      for line in buffered {
        outgoing?.yield(line)
      }
      buffered.removeAll()
      if closed {
        outgoing?.finish()
      }
    }
  }

  public func send(line: Data) {
    lock.withLock {
      if let outgoing {
        outgoing.yield(line)
      } else {
        buffered.append(line)
      }
    }
  }

  public func close() {
    lock.withLock {
      guard !closed else { return }
      closed = true
      outgoing?.finish()
    }
    incoming.finish()
  }
}

final class ACPLineSplitter: @unchecked Sendable {
  private let lock = NSLock()
  private let continuation: AsyncStream<Data>.Continuation
  private var pending = Data()

  init(continuation: AsyncStream<Data>.Continuation) {
    self.continuation = continuation
  }

  func consume(_ data: Data) {
    lock.withLock {
      pending.append(data)
      while let newline = pending.firstIndex(of: 10) {
        let line = pending[..<newline]
        pending.removeSubrange(...newline)
        if !line.isEmpty {
          continuation.yield(Data(line))
        }
      }
    }
  }

  func finish() {
    lock.withLock {
      if !pending.isEmpty {
        continuation.yield(pending)
        pending.removeAll()
      }
      continuation.finish()
    }
  }
}
