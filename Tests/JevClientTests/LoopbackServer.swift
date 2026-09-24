#if os(macOS) || os(Linux)
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct WireRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct WireResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

private enum LoopbackError: Error {
    case socketFailure
    case timedOut
    case malformedRequest
}

/// Owns one bound loopback listener; its task closes the descriptor on every exit.
/// A bounded poll and socket receive timeout prevent a failed assertion from hanging tests.
struct LoopbackServer: Sendable {
    let url: URL
    private let task: Task<[WireRequest], any Error>

    init(
        minimumRequests: Int,
        respond: @escaping @Sendable (WireRequest) -> WireResponse
    ) throws {
        #if os(Linux)
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard descriptor >= 0 else { throw LoopbackError.socketFailure }

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, length)
            }
        }
        guard bindResult == 0,
              listen(descriptor, 8) == 0,
              withUnsafeMutablePointer(to: &address, { pointer in
                  pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                      getsockname(descriptor, $0, &length)
                  }
              }) == 0 else {
            _ = close(descriptor)
            throw LoopbackError.socketFailure
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        self.url = URL(string: "http://127.0.0.1:\(port)")!
        self.task = Task.detached {
            defer { _ = close(descriptor) }
            var requests: [WireRequest] = []
            while true {
                var pending = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let timeout: Int32 = requests.count >= minimumRequests ? 500 : 3_000
                let ready = poll(&pending, 1, timeout)
                if ready == 0 {
                    if requests.count >= minimumRequests { return requests }
                    throw LoopbackError.timedOut
                }
                guard ready > 0 else { throw LoopbackError.socketFailure }
                let connection = accept(descriptor, nil, nil)
                guard connection >= 0 else { throw LoopbackError.socketFailure }
                do {
                    defer { _ = close(connection) }
                    var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
                    _ = withUnsafePointer(to: &receiveTimeout) {
                        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
                    }
                    #if canImport(Darwin)
                    var noSignal: Int32 = 1
                    _ = withUnsafePointer(to: &noSignal) {
                        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
                    }
                    #endif
                    let request = try Self.readRequest(from: connection)
                    requests.append(request)
                    try Self.write(respond(request), to: connection)
                }
            }
        }
    }

    func requests() async throws -> [WireRequest] { try await task.value }

    private static func readRequest(from descriptor: Int32) throws -> WireRequest {
        let terminator = Data("\r\n\r\n".utf8)
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while received.range(of: terminator) == nil {
            let count = buffer.withUnsafeMutableBytes {
                recv(descriptor, $0.baseAddress, $0.count, 0)
            }
            guard count > 0, received.count + count <= 1_048_576 else {
                throw LoopbackError.malformedRequest
            }
            received.append(contentsOf: buffer.prefix(count))
        }
        guard let boundary = received.range(of: terminator) else {
            throw LoopbackError.malformedRequest
        }
        let head = String(decoding: received[..<boundary.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { throw LoopbackError.malformedRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw LoopbackError.malformedRequest }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let bodyLength = Int(headers["content-length"] ?? "0") ?? -1
        guard (0...1_048_576).contains(bodyLength) else { throw LoopbackError.malformedRequest }
        let end = boundary.upperBound + bodyLength
        while received.count < end {
            let count = buffer.withUnsafeMutableBytes {
                recv(descriptor, $0.baseAddress, $0.count, 0)
            }
            guard count > 0, received.count + count <= 1_048_576 else {
                throw LoopbackError.malformedRequest
            }
            received.append(contentsOf: buffer.prefix(count))
        }
        return WireRequest(
            method: String(requestLine[0]), path: String(requestLine[1]),
            headers: headers, body: received.subdata(in: boundary.upperBound..<end)
        )
    }

    private static func write(_ response: WireResponse, to descriptor: Int32) throws {
        var head = "HTTP/1.1 \(response.status) Test\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        var bytes = Data(head.utf8)
        bytes.append(response.body)
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                #if os(Linux)
                let count = Glibc.send(descriptor, base.advanced(by: written), buffer.count - written, Int32(MSG_NOSIGNAL))
                #else
                let count = Darwin.send(descriptor, base.advanced(by: written), buffer.count - written, 0)
                #endif
                guard count > 0 else { throw LoopbackError.socketFailure }
                written += count
            }
        }
    }
}
#endif
