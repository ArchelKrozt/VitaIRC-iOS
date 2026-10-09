import Foundation
import Network

public struct ConnError: Error { public let message: String; public let dns: Bool; public let tls: Bool }

/**
 One IRC connection (TCP or TLS) with a blocking interface for the connection thread.
 Like VitaIRC on the Vita, a certificate that can't be verified does not stop the
 connection (bouncers often use their own); certOk says whether it was trusted.
 */
final class Conn {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "irc.conn")
    private let cond = NSCondition()
    private var buffer = Data()
    private var closed = false
    private(set) var certOk = true

    private init(_ c: NWConnection) { conn = c }

    /// Blocking connect (with TLS handshake). Throws ConnError on failure.
    static func open(host: String, port: Int, ssl: Bool) throws -> Conn {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw ConnError(message: "port", dns: false, tls: false) }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 20
        tcp.enableKeepalive = true
        tcp.noDelay = true
        var holder: Conn?
        let params: NWParameters
        if ssl {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, done in
                let t = sec_trust_copy_ref(trust).takeRetainedValue()
                var err: CFError?
                let ok = SecTrustEvaluateWithError(t, &err)
                if !ok { holder?.certOk = false }
                done(true)
            }, DispatchQueue.global())
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        let c = Conn(NWConnection(host: NWEndpoint.Host(host), port: p, using: params))
        holder = c
        var result: Error?
        var done = false
        let ready = NSCondition()
        c.conn.stateUpdateHandler = { st in
            switch st {
            case .ready:
                ready.lock(); done = true; ready.signal(); ready.unlock()
            case .failed(let e), .waiting(let e):
                ready.lock()
                if !done { result = e; done = true; ready.signal() }
                ready.unlock()
                c.markClosed()
            case .cancelled:
                c.markClosed()
            default: break
            }
        }
        c.conn.start(queue: c.queue)
        ready.lock()
        let deadline = Date().addingTimeInterval(25)
        while !done && ready.wait(until: deadline) {}
        let timedOut = !done
        ready.unlock()
        if timedOut || result != nil {
            c.conn.cancel()
            let msg = result.map { "\($0)" } ?? "timeout"
            var dns = false, tlsErr = false
            if let ne = result as? NWError {
                switch ne {
                case .dns: dns = true
                case .tls: tlsErr = true
                default: break
                }
            }
            throw ConnError(message: msg, dns: dns, tls: tlsErr)
        }
        c.receive()
        return c
    }

    private func markClosed() {
        cond.lock(); closed = true; cond.broadcast(); cond.unlock()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, err in
            guard let self = self else { return }
            self.cond.lock()
            if let d = data, !d.isEmpty { self.buffer.append(d) }
            if complete || err != nil { self.closed = true }
            self.cond.broadcast()
            self.cond.unlock()
            if !(complete || err != nil) { self.receive() }
        }
    }

    func write(_ line: String) throws {
        let sem = DispatchSemaphore(value: 0)
        var failed: Error?
        conn.send(content: Data(line.utf8), completion: .contentProcessed { e in failed = e; sem.signal() })
        if sem.wait(timeout: .now() + 30) == .timedOut { throw ConnError(message: "send timeout", dns: false, tls: false) }
        if let e = failed { throw e }
    }

    /// One line without CRLF; nil when none arrived within the timeout. Throws when closed.
    func readLine(timeout: TimeInterval = 0.1) throws -> String? {
        cond.lock()
        defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let nl = buffer.firstIndex(of: 10) {
                var line = buffer[buffer.startIndex..<nl]
                if line.last == 13 { line = line.dropLast() }
                buffer.removeSubrange(buffer.startIndex...nl)
                return Conn.decode(Data(line))
            }
            if buffer.count > 16384 { buffer.removeAll() }       // overlong line: drop it
            if closed { throw ConnError(message: "closed", dns: false, tls: false) }
            if !cond.wait(until: deadline) { return nil }
        }
    }

    /// UTF-8, or Latin-1 for old clients that don't send UTF-8.
    static func decode(_ b: Data) -> String {
        String(data: b, encoding: .utf8) ?? String(data: b, encoding: .isoLatin1) ?? ""
    }

    func close() {
        conn.cancel()
        markClosed()
    }
}
