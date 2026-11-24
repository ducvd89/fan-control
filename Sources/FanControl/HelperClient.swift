import Foundation

/// Talks to the root helper over its Unix socket. All I/O runs on a private queue.
final class HelperClient: @unchecked Sendable {
    static let socketPath = "/var/run/fancontrol.sock"

    private let queue = DispatchQueue(label: "fancontrol.client")
    private var fd: Int32 = -1

    var isInstalled: Bool { FileManager.default.fileExists(atPath: Self.socketPath) }

    /// Sends one command and calls back on the main queue with the reply (nil on failure).
    func send(_ command: String, completion: (@Sendable (String?) -> Void)? = nil) {
        queue.async {
            var reply = self.roundTrip(command)
            if reply == nil {            // helper restarted, or first use: reconnect once
                self.disconnect()
                reply = self.roundTrip(command)
            }
            if let completion { DispatchQueue.main.async { completion(reply) } }
        }
    }

    /// Synchronous variant used at quit time.
    func sendAndWait(_ command: String) {
        queue.sync { _ = roundTrip(command) }
    }

    private func roundTrip(_ command: String) -> String? {
        if fd < 0 { connect() }
        guard fd >= 0 else { return nil }
        let line = command + "\n"
        let wrote = line.withCString { Darwin.write(fd, $0, strlen($0)) }
        guard wrote > 0 else { disconnect(); return nil }
        var data = Data()
        var byte: UInt8 = 0
        while Darwin.read(fd, &byte, 1) == 1 {
            if byte == 0x0A { return String(decoding: data, as: UTF8.self) }
            data.append(byte)
        }
        disconnect()
        return nil
    }

    private func connect() {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in Self.socketPath.utf8.enumerated() where i < raw.count - 1 { raw[i] = b }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if ok == 0 { fd = s } else { close(s) }
    }

    private func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
    }
}
