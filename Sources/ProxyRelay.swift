import Foundation
import Network

/// Local forwarding HTTP proxy. Listens on 127.0.0.1:<port> and tunnels each client
/// connection to the currently-active upstream (HTTP proxy, SOCKS5 proxy, or direct).
/// The system proxy points here permanently; switching the upstream is internal.
final class ProxyRelay {
    private var listener: NWListener?
    private let listenerQueue = DispatchQueue(label: "switchproxy.relay.listener")
    private let lock = NSLock()
    private var sessions = Set<RelaySession>()

    private(set) var running = false
    private(set) var port: UInt16 = 0

    /// Supplies the upstream to use for new connections (nil == direct).
    var activeConfigProvider: () -> ProxyConfig? = { nil }

    func start(port: UInt16) throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!
        )

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.running = true
            case .failed, .cancelled: self?.running = false
            default: break
            }
        }
        listener.start(queue: listenerQueue)
        self.listener = listener
        self.port = port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        lock.lock()
        let all = sessions
        sessions.removeAll()
        lock.unlock()
        all.forEach { $0.close() }
    }

    func restart(port: UInt16) {
        try? start(port: port)
    }

    private func accept(_ conn: NWConnection) {
        let session = RelaySession(client: conn, upstream: activeConfigProvider())
        lock.lock(); sessions.insert(session); lock.unlock()
        session.onFinished = { [weak self, weak session] in
            guard let self = self, let session = session else { return }
            self.lock.lock(); self.sessions.remove(session); self.lock.unlock()
        }
        session.start()
    }
}

/// Handles one client connection end-to-end.
private final class RelaySession: Hashable {
    let id = UUID()
    private let client: NWConnection
    private let upstream: ProxyConfig?
    private let queue: DispatchQueue
    private var server: NWConnection?
    private var finished = false

    var onFinished: (() -> Void)?

    init(client: NWConnection, upstream: ProxyConfig?) {
        self.client = client
        self.upstream = upstream
        self.queue = DispatchQueue(label: "switchproxy.relay.session")
    }

    static func == (lhs: RelaySession, rhs: RelaySession) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        client.start(queue: queue)
        readHeader()
    }

    func close() {
        queue.async { [weak self] in
            guard let self = self, !self.finished else { return }
            self.finished = true
            self.client.stateUpdateHandler = nil
            self.server?.stateUpdateHandler = nil
            self.client.cancel()
            self.server?.cancel()
            let cb = self.onFinished
            self.onFinished = nil
            cb?()
        }
    }

    // MARK: Request parsing

    private func readHeader(_ buffer: Data = Data()) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil { self.close(); return }
            var buf = buffer
            if let data = data { buf.append(data) }

            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let header = buf.subdata(in: buf.startIndex..<range.upperBound)
                let leftover = buf.subdata(in: range.upperBound..<buf.endIndex)
                self.process(header: header, leftover: leftover)
            } else if buf.count > 256 * 1024 {
                self.close()
            } else if isComplete {
                self.close()
            } else {
                self.readHeader(buf)
            }
        }
    }

    private func process(header: Data, leftover: Data) {
        guard let headStr = String(data: header, encoding: .utf8) ?? String(data: header, encoding: .isoLatin1) else {
            close(); return
        }
        let lines = headStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { close(); return }
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 3 else { close(); return }
        let method = parts[0].uppercased()
        let target = parts[1]

        // HTTP upstream: it already speaks the proxy protocol, so forward bytes verbatim.
        if let up = upstream, up.kind == .http {
            var out = injectAuth(headStr: headStr, original: header, upstream: up)
            out.append(leftover)
            openServer(host: up.host, port: up.port) { [weak self] ok in
                guard let self = self, ok, let server = self.server else { self?.close(); return }
                server.send(content: out, completion: .contentProcessed { err in
                    if err != nil { self.close(); return }
                    self.beginTunnel()
                })
            }
            return
        }

        // SOCKS5 upstream or direct connection.
        if method == "CONNECT" {
            let (host, p) = parseHostPort(target, defaultPort: 443)
            dial(host: host, port: p) { [weak self] ok in
                guard let self = self, ok else { self?.close(); return }
                self.startConnectTunnel(leftover: leftover)
            }
        } else {
            handlePlainHTTP(method: method, target: target, headStr: headStr, leftover: leftover)
        }
    }

    /// Plain (non-CONNECT) HTTP through SOCKS5/direct: rewrite absolute-form to origin-form.
    private func handlePlainHTTP(method: String, target: String, headStr: String, leftover: Data) {
        guard let comps = URLComponents(string: target), let host = comps.host else { close(); return }
        let port = comps.port ?? 80
        var origin = comps.percentEncodedPath.isEmpty ? "/" : comps.percentEncodedPath
        if let query = comps.percentEncodedQuery { origin += "?" + query }

        var out = Data(rewriteHead(headStr: headStr, method: method, origin: origin).utf8)
        out.append(leftover)
        dial(host: host, port: port) { [weak self] ok in
            guard let self = self, ok, let server = self.server else { self?.close(); return }
            server.send(content: out, completion: .contentProcessed { err in
                if err != nil { self.close(); return }
                self.beginTunnel()
            })
        }
    }

    // MARK: Connecting

    private func makeConnection(_ host: String, _ port: Int) -> NWConnection {
        let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 80
        return NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
    }

    /// Establish a connection to (host, port) via the SOCKS5 upstream or directly.
    private func dial(host: String, port: Int, completion: @escaping (Bool) -> Void) {
        var done = false
        func finish(_ ok: Bool) { if done { return }; done = true; completion(ok) }

        if let up = upstream, up.kind == .socks5 {
            let conn = makeConnection(up.host, up.port)
            server = conn
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Socks5.connect(over: conn, targetHost: host, targetPort: port,
                                   username: up.username, password: up.password) { ok in finish(ok) }
                case .failed, .cancelled:
                    finish(false)
                default: break
                }
            }
            conn.start(queue: queue)
        } else {
            openServer(host: host, port: port, completion: completion)
        }
    }

    /// Direct TCP connection (no SOCKS handshake).
    private func openServer(host: String, port: Int, completion: @escaping (Bool) -> Void) {
        var done = false
        func finish(_ ok: Bool) { if done { return }; done = true; completion(ok) }
        let conn = makeConnection(host, port)
        server = conn
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed, .cancelled: finish(false)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    // MARK: Tunneling

    private func startConnectTunnel(leftover: Data) {
        let ok = Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8)
        client.send(content: ok, completion: .contentProcessed { [weak self] err in
            guard let self = self else { return }
            if err != nil { self.close(); return }
            if !leftover.isEmpty, let server = self.server {
                server.send(content: leftover, completion: .contentProcessed { e in
                    if e != nil { self.close(); return }
                    self.beginTunnel()
                })
            } else {
                self.beginTunnel()
            }
        })
    }

    private func beginTunnel() {
        guard let server = self.server else { close(); return }
        pipe(from: client, to: server)
        pipe(from: server, to: client)
    }

    private func pipe(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { err in
                    if err != nil { self.close(); return }
                    self.pipe(from: from, to: to)
                })
            } else if isComplete || error != nil {
                self.close()
            } else {
                self.pipe(from: from, to: to)
            }
        }
    }

    // MARK: Header rewriting

    /// Inject Proxy-Authorization for an HTTP upstream that needs credentials.
    private func injectAuth(headStr: String, original: Data, upstream up: ProxyConfig) -> Data {
        guard let user = up.username, !user.isEmpty else { return original }
        let token = Data("\(user):\(up.password ?? "")".utf8).base64EncodedString()
        let lines = headStr.components(separatedBy: "\r\n")
        var out: [String] = []
        if let first = lines.first { out.append(first) }
        out.append("Proxy-Authorization: Basic \(token)")
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            if line.lowercased().hasPrefix("proxy-authorization:") { continue }
            out.append(line)
        }
        return Data((out.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// Rewrite an absolute-form request line to origin-form and force a single request
    /// per connection (so we don't have to re-parse subsequent absolute-form requests).
    private func rewriteHead(headStr: String, method: String, origin: String) -> String {
        let lines = headStr.components(separatedBy: "\r\n")
        var out = ["\(method) \(origin) HTTP/1.1"]
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("proxy-connection:") || lower.hasPrefix("connection:") || lower.hasPrefix("proxy-authorization:") {
                continue
            }
            out.append(line)
        }
        out.append("Connection: close")
        return out.joined(separator: "\r\n") + "\r\n\r\n"
    }

    private func parseHostPort(_ s: String, defaultPort: Int) -> (String, Int) {
        if s.hasPrefix("["), let end = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<end])
            let rest = s[s.index(after: end)...]
            if rest.hasPrefix(":"), let p = Int(rest.dropFirst()) { return (host, p) }
            return (host, defaultPort)
        }
        let comps = s.split(separator: ":")
        if comps.count == 2, let p = Int(comps[1]) { return (String(comps[0]), p) }
        return (s, defaultPort)
    }
}
