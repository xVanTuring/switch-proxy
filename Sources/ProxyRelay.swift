import Foundation
import Network

/// Local forwarding proxy with a mixed inbound port: the same 127.0.0.1:<port>
/// accepts both HTTP-proxy and SOCKS5 clients (detected from the first byte) and
/// tunnels each connection to the currently-active upstream (HTTP proxy, SOCKS5
/// proxy, or direct). The system proxy points here permanently as an HTTP proxy;
/// apps that prefer SOCKS can use socks5h://127.0.0.1:<port> on the same port.
/// Switching the upstream is internal.
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
    /// Bytes already read from the upstream during handshake that belong to the tunnel
    /// (e.g. early data after an HTTP CONNECT 200) and must be flushed to the client first.
    private var earlyServerData = Data()

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
        detectProtocol()
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

    // MARK: Inbound protocol detection

    /// Peek the first byte to route the connection: 0x05 == SOCKS5, otherwise HTTP.
    /// (HTTP request lines always begin with an ASCII method letter, never 0x05.)
    private func detectProtocol(_ buffer: Data = Data()) {
        if let first = buffer.first {
            if first == 0x05 {
                handleSocksGreeting(buffer)
            } else {
                readHeader(buffer)
            }
            return
        }
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil { self.close(); return }
            var buf = buffer
            if let data = data { buf.append(data) }
            if (data?.isEmpty ?? true) && isComplete { self.close(); return }
            self.detectProtocol(buf)
        }
    }

    // MARK: HTTP inbound parsing

    private func readHeader(_ buffer: Data = Data()) {
        // Process as soon as the buffer holds a full header — the first chunk often does.
        if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let header = buffer.subdata(in: buffer.startIndex..<range.upperBound)
            let leftover = buffer.subdata(in: range.upperBound..<buffer.endIndex)
            process(header: header, leftover: leftover)
            return
        }
        if buffer.count > 256 * 1024 { close(); return }
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil { self.close(); return }
            var buf = buffer
            if let data = data { buf.append(data) }
            if (data?.isEmpty ?? true) && isComplete { self.close(); return }
            self.readHeader(buf)
        }
    }

    // MARK: SOCKS5 inbound (server side)

    /// Accumulate from the client until the buffer holds at least `n` bytes.
    private func readSocks(atLeast n: Int, from buffer: Data, _ completion: @escaping (Data) -> Void) {
        if buffer.count >= n { completion(buffer); return }
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil { self.close(); return }
            var buf = buffer
            if let data = data { buf.append(data) }
            if (data?.isEmpty ?? true) && isComplete { self.close(); return }
            self.readSocks(atLeast: n, from: buf, completion)
        }
    }

    /// Method-negotiation: VER(0x05) NMETHODS METHODS... We always select "no auth"
    /// (the listener is localhost-only).
    private func handleSocksGreeting(_ initial: Data) {
        readSocks(atLeast: 2, from: initial) { [weak self] buf in
            guard let self = self else { return }
            let nmethods = Int([UInt8](buf)[1])
            self.readSocks(atLeast: 2 + nmethods, from: buf) { [weak self] buf in
                guard let self = self else { return }
                self.client.send(content: Data([0x05, 0x00]), completion: .contentProcessed { err in
                    if err != nil { self.close(); return }
                    let consumed = 2 + nmethods
                    let leftover = buf.subdata(in: buf.index(buf.startIndex, offsetBy: consumed)..<buf.endIndex)
                    self.readSocksRequest(leftover)
                })
            }
        }
    }

    /// Request: VER CMD RSV ATYP DST.ADDR DST.PORT. Only CONNECT (0x01) is supported.
    private func readSocksRequest(_ initial: Data) {
        readSocks(atLeast: 4, from: initial) { [weak self] buf in
            guard let self = self else { return }
            let b = [UInt8](buf)
            guard b[0] == 0x05, b[1] == 0x01 else { self.sendSocksFailureAndClose(); return }
            switch b[3] {
            case 0x01: // IPv4
                self.readSocks(atLeast: 4 + 4 + 2, from: buf) { buf in
                    let bb = [UInt8](buf)
                    let host = "\(bb[4]).\(bb[5]).\(bb[6]).\(bb[7])"
                    let port = (Int(bb[8]) << 8) | Int(bb[9])
                    self.socksConnect(host: host, port: port, consumed: 4 + 4 + 2, buffer: buf)
                }
            case 0x04: // IPv6
                self.readSocks(atLeast: 4 + 16 + 2, from: buf) { buf in
                    let bb = [UInt8](buf)
                    let host = Self.formatIPv6(Array(bb[4..<20]))
                    let port = (Int(bb[20]) << 8) | Int(bb[21])
                    self.socksConnect(host: host, port: port, consumed: 4 + 16 + 2, buffer: buf)
                }
            case 0x03: // domain name
                self.readSocks(atLeast: 5, from: buf) { buf in
                    let len = Int([UInt8](buf)[4])
                    let total = 4 + 1 + len + 2
                    self.readSocks(atLeast: total, from: buf) { buf in
                        let bb = [UInt8](buf)
                        let host = String(bytes: bb[5..<(5 + len)], encoding: .utf8) ?? ""
                        let port = (Int(bb[5 + len]) << 8) | Int(bb[5 + len + 1])
                        self.socksConnect(host: host, port: port, consumed: total, buffer: buf)
                    }
                }
            default:
                self.sendSocksFailureAndClose()
            }
        }
    }

    /// Establish the tunnel for a parsed SOCKS CONNECT, reply, then pipe.
    private func socksConnect(host: String, port: Int, consumed: Int, buffer: Data) {
        guard !host.isEmpty else { sendSocksFailureAndClose(); return }
        let leftover = buffer.subdata(in: buffer.index(buffer.startIndex, offsetBy: consumed)..<buffer.endIndex)
        dial(host: host, port: port) { [weak self] ok in
            guard let self = self else { return }
            guard ok else { self.sendSocksFailureAndClose(); return }
            // Success: VER REP=0 RSV ATYP=IPv4 BND.ADDR=0.0.0.0 BND.PORT=0
            let reply = Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
            self.client.send(content: reply, completion: .contentProcessed { err in
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
    }

    private func sendSocksFailureAndClose() {
        let reply = Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) // REP=1 general failure
        client.send(content: reply, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    private static func formatIPv6(_ bytes: [UInt8]) -> String {
        guard bytes.count == 16 else { return "" }
        var groups: [String] = []
        var i = 0
        while i < 16 {
            groups.append(String((UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1]), radix: 16))
            i += 2
        }
        return groups.joined(separator: ":")
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

    /// Establish a raw byte tunnel to (host, port) through the active upstream
    /// (SOCKS5 handshake, HTTP CONNECT) or directly. Used by the SOCKS inbound path
    /// and the HTTP-inbound CONNECT path for SOCKS5/direct upstreams.
    private func dial(host: String, port: Int, completion: @escaping (Bool) -> Void) {
        var done = false
        func finish(_ ok: Bool) { if done { return }; done = true; completion(ok) }

        guard let up = upstream else {
            openServer(host: host, port: port, completion: completion)
            return
        }

        switch up.kind {
        case .socks5:
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
        case .http:
            let conn = makeConnection(up.host, up.port)
            server = conn
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.httpConnect(over: conn, host: host, port: port, upstream: up) { ok in finish(ok) }
                case .failed, .cancelled:
                    finish(false)
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    /// Issue an HTTP CONNECT to an HTTP upstream and wait for a 2xx before tunneling.
    private func httpConnect(over conn: NWConnection, host: String, port: Int,
                             upstream up: ProxyConfig, completion: @escaping (Bool) -> Void) {
        var req = "CONNECT \(host):\(port) HTTP/1.1\r\nHost: \(host):\(port)\r\n"
        if let user = up.username, !user.isEmpty {
            let token = Data("\(user):\(up.password ?? "")".utf8).base64EncodedString()
            req += "Proxy-Authorization: Basic \(token)\r\n"
        }
        req += "\r\n"
        conn.send(content: Data(req.utf8), completion: .contentProcessed { [weak self] err in
            guard let self = self else { return }
            if err != nil { completion(false); return }
            self.readHTTPConnectResponse(over: conn, buffer: Data(), completion: completion)
        })
    }

    private func readHTTPConnectResponse(over conn: NWConnection, buffer: Data,
                                         completion: @escaping (Bool) -> Void) {
        if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let statusLine = String(data: buffer.subdata(in: buffer.startIndex..<range.lowerBound),
                                    encoding: .isoLatin1)?.components(separatedBy: "\r\n").first ?? ""
            let ok = Self.isHTTP2xx(statusLine)
            if ok {
                // Any bytes past the response headers are early tunnel data for the client.
                let leftover = buffer.subdata(in: range.upperBound..<buffer.endIndex)
                if !leftover.isEmpty { earlyServerData = leftover }
            }
            completion(ok)
            return
        }
        if buffer.count > 64 * 1024 { completion(false); return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil { completion(false); return }
            var buf = buffer
            if let data = data { buf.append(data) }
            if (data?.isEmpty ?? true) && isComplete { completion(false); return }
            self.readHTTPConnectResponse(over: conn, buffer: buf, completion: completion)
        }
    }

    private static func isHTTP2xx(_ statusLine: String) -> Bool {
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return false }
        return (200...299).contains(code)
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
        if !earlyServerData.isEmpty {
            let early = earlyServerData
            earlyServerData = Data()
            client.send(content: early, completion: .contentProcessed { [weak self] err in
                guard let self = self else { return }
                if err != nil { self.close(); return }
                self.pipe(from: self.client, to: server)
                self.pipe(from: server, to: self.client)
            })
        } else {
            pipe(from: client, to: server)
            pipe(from: server, to: client)
        }
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
