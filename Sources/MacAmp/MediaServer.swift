import Foundation
import MacAmpCore
import Network
import os

/// Serves the local files queued on Sonos over HTTP in the home network. Every file gets an unguessable token in
/// its URL; nothing else on the Mac is reachable. Byte ranges are supported so Sonos can seek.
// ponytail: token-only access and one connection per request; add auth or keep-alive if this ever leaves the home.
final class MediaServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.andrehickmann.macamp.media-server")
    private let files = OSAllocatedUnfairLock(initialState: [String: URL]())
    private var listener: NWListener?
    private var port: UInt16?

    /// A URL for `file` that a player at `host` (an IPv4 address) can fetch.
    @MainActor
    func url(for file: URL, reachableFrom host: String) async throws -> URL {
        let port = try await start()
        guard let address = Self.localAddress(near: host) else { throw URLError(.cannotFindHost) }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        files.withLock { $0[token] = file }
        let name = file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "file"
        guard let url = URL(string: "http://\(address):\(port)/\(token)/\(name)") else { throw URLError(.badURL) }
        return url
    }

    @MainActor
    private func start() async throws -> UInt16 {
        if let port { return port }
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        self.listener = listener
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.port = port
        return port
    }

    // MARK: HTTP

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeader(connection, buffer: Data())
    }

    private func receiveHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self?.respond(connection, header: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if isComplete || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self?.receiveHeader(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        guard request.count >= 2, request[0] == "GET" || request[0] == "HEAD" else {
            return send(connection, status: "405 Method Not Allowed", headers: [:])
        }
        let token = request[1].split(separator: "/").first.map(String.init) ?? ""
        guard let file = files.withLock({ $0[token] }),
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0,
              let handle = try? FileHandle(forReadingFrom: file) else {
            return send(connection, status: "404 Not Found", headers: [:])
        }
        let rangeHeader = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        let range = Sonos.byteRange(rangeHeader, size: size)
        if rangeHeader != nil, range == nil {
            try? handle.close()
            return send(connection, status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(size)"])
        }
        let bytes = range ?? 0...(size - 1)
        var headers = ["Content-Type": Sonos.mimeType(forExtension: file.pathExtension), "Accept-Ranges": "bytes",
                       "Content-Length": String(bytes.count)]
        if range != nil { headers["Content-Range"] = "bytes \(bytes.lowerBound)-\(bytes.upperBound)/\(size)" }
        let isHead = request[0] == "HEAD"
        send(connection, status: range == nil ? "200 OK" : "206 Partial Content", headers: headers, close: isHead) { [weak self] in
            guard !isHead else {
                try? handle.close()
                return
            }
            try? handle.seek(toOffset: UInt64(bytes.lowerBound))
            self?.stream(connection, handle: handle, remaining: bytes.count)
        }
    }

    private func send(_ connection: NWConnection, status: String, headers: [String: String], close: Bool = true,
                      then: (@Sendable () -> Void)? = nil) {
        var text = "HTTP/1.1 \(status)\r\nConnection: close\r\n"
        if headers["Content-Length"] == nil { text += "Content-Length: 0\r\n" }
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        connection.send(content: Data((text + "\r\n").utf8), completion: .contentProcessed { error in
            if error != nil || close { return connection.cancel() }
            then?()
        })
    }

    /// Sends the file in 256 KiB chunks, each after the previous one went out.
    private func stream(_ connection: NWConnection, handle: FileHandle, remaining: Int) {
        let chunk = remaining > 0 ? handle.readData(ofLength: min(262_144, remaining)) : Data()
        guard !chunk.isEmpty else {
            try? handle.close()
            return connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                   completion: .contentProcessed { _ in connection.cancel() })
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                try? handle.close()
                return connection.cancel()
            }
            self?.stream(connection, handle: handle, remaining: remaining - chunk.count)
        })
    }

    // MARK: Network address

    /// This Mac's IPv4 address in the same /24 network as `host`, else its first non-loopback IPv4 address.
    static func localAddress(near host: String) -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }
        let prefix = host.split(separator: ".").prefix(3).joined(separator: ".") + "."
        var fallback: String?
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if ip.hasPrefix(prefix) { return ip }
            fallback = fallback ?? ip
        }
        return fallback
    }
}
