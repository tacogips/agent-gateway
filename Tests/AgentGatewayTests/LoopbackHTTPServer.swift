import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class LoopbackHTTPServer: @unchecked Sendable {
  private let lock = NSLock()
  private var routes: [String: String]
  private var counts: [String: Int] = [:]
  private var listener: Int32 = -1
  private let finished = DispatchSemaphore(value: 0)

  init(routes: [String: String]) { self.routes = routes }

  func setRoute(_ path: String, response: String) {
    lock.lock()
    routes[path] = response
    lock.unlock()
  }

  func requestCount(path: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return counts[path, default: 0]
  }

  func start() throws -> UInt16 {
    #if canImport(Darwin)
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    #else
    let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard descriptor >= 0 else { throw serverError() }
    var reuse: Int32 = 1
    _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
    var address = sockaddr_in()
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(0).bigEndian
    address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(descriptor, 8) == 0 else {
      close(descriptor)
      throw serverError()
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    guard named == 0 else { close(descriptor); throw serverError() }
    listener = descriptor
    Thread { [self] in
      defer { finished.signal() }
      while true {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { break }
        handle(client)
        close(client)
      }
    }.start()
    return UInt16(bigEndian: address.sin_port)
  }

  func stop() {
    guard listener >= 0 else { return }
    _ = shutdown(listener, Int32(SHUT_RDWR))
    close(listener)
    listener = -1
    _ = finished.wait(timeout: .now() + 5)
  }

  private func handle(_ client: Int32) {
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    var bytes = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let separator = Data("\r\n\r\n".utf8)
    var headerEnd: Data.Index?
    var contentLength = 0
    while true {
      let count = recv(client, &buffer, buffer.count, 0)
      guard count > 0 else { return }
      bytes.append(contentsOf: buffer.prefix(count))
      if headerEnd == nil, let range = bytes.range(of: separator) {
        headerEnd = range.upperBound
        guard let headers = String(bytes: bytes[..<range.lowerBound], encoding: .utf8) else { return }
        for line in headers.components(separatedBy: "\r\n").dropFirst() {
          let parts = line.split(separator: ":", maxSplits: 1)
          if parts.count == 2, parts[0].lowercased() == "content-length" {
            contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
          }
        }
      }
      if let headerEnd, bytes.count - headerEnd >= contentLength { break }
    }
    guard let headerEnd, let request = String(bytes: bytes[..<headerEnd], encoding: .utf8),
          let line = request.components(separatedBy: "\r\n").first,
          let path = line.split(separator: " ").dropFirst().first else { return }
    lock.lock()
    counts[String(path), default: 0] += 1
    let response = routes[String(path)] ?? "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    lock.unlock()
    let responseBytes = Array(response.utf8)
    responseBytes.withUnsafeBytes { raw in
      var sent = 0
      while sent < raw.count {
        let count = send(client, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
        guard count > 0 else { break }
        sent += count
      }
    }
  }

  private func serverError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
