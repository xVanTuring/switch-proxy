import Foundation

/// The proxy ignore list: hosts and address ranges that skip the upstream proxy and
/// connect directly. The same entries are written to the system proxy's bypass list
/// and checked by the relay, so apps that talk to the relay directly (SOCKS clients,
/// `http_proxy` env vars) also go direct for them.
///
/// Supported entry forms: exact host (`localhost`), wildcard suffix (`*.local`,
/// `.local`), IP address, and CIDR range (`192.168.0.0/16`, macOS shorthand
/// `169.254/16`, IPv6 `fe80::/10`). Hostnames are never resolved, so a name that
/// resolves to a LAN address only matches if the name itself is listed.
struct ProxyBypass {

    /// Common LAN / loopback / link-local ranges plus Tailscale device addresses.
    static let defaults: [String] = [
        "localhost",
        "*.local",
        "127.0.0.0/8",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "169.254.0.0/16",
        "100.64.0.0/10",        // Tailscale (CGNAT range)
        "*.ts.net",             // Tailscale MagicDNS
        "::1",
        "fe80::/10",
        "fd7a:115c:a1e0::/48",  // Tailscale IPv6
    ]

    private enum Rule {
        case host(String)              // exact match
        case suffix(String)            // "*.local" → ".local"
        case cidr([UInt8], Int)        // network bytes (4 or 16) + prefix length
    }

    private let rules: [Rule]

    init(_ entries: [String]) {
        rules = entries.compactMap(Self.rule(from:))
    }

    /// Whether a target host (name or IP literal, as sent by the client) skips the upstream.
    func matches(_ rawHost: String) -> Bool {
        let host = Self.normalize(rawHost)
        guard !host.isEmpty else { return false }
        let ip = Self.ipBytes(host)
        for rule in rules {
            switch rule {
            case .host(let h):
                if host == h { return true }
            case .suffix(let s):
                if host.hasSuffix(s) { return true }
            case .cidr(let net, let bits):
                if let ip = ip, Self.inPrefix(ip, net, bits) { return true }
            }
        }
        return false
    }

    /// Split user input (one entry per line; commas/spaces also accepted) into
    /// trimmed, de-duplicated entries.
    static func parseEntries(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet(charactersIn: ",").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Entries that cannot be understood (e.g. a malformed CIDR range).
    static func invalidEntries(_ entries: [String]) -> [String] {
        entries.filter { rule(from: $0) == nil }
    }

    // MARK: Parsing

    private static func rule(from entry: String) -> Rule? {
        let e = normalize(entry)
        if e.hasPrefix("*.") { return e.count > 2 ? .suffix(String(e.dropFirst())) : nil }
        if e.hasPrefix(".") { return e.count > 1 ? .suffix(e) : nil }

        if let slash = e.firstIndex(of: "/") {
            var addr = String(e[..<slash])
            guard let bits = Int(e[e.index(after: slash)...]) else { return nil }
            // macOS shorthand "169.254/16" == "169.254.0.0/16".
            if !addr.contains(":") {
                let octets = addr.split(separator: ".", omittingEmptySubsequences: false)
                if (1...3).contains(octets.count) {
                    addr += String(repeating: ".0", count: 4 - octets.count)
                }
            }
            guard let net = ipBytes(addr), (0...net.count * 8).contains(bits) else { return nil }
            return .cidr(net, bits)
        }

        if let ip = ipBytes(e) { return .cidr(ip, ip.count * 8) }
        guard !e.isEmpty, !e.contains("*") else { return nil }
        return .host(e)
    }

    /// Lowercase, drop IPv6 brackets / zone id and a trailing root dot.
    private static func normalize(_ s: String) -> String {
        var h = s.trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
        if h.hasSuffix(".") { h.removeLast() }
        return h
    }

    /// Network-order bytes of a strict IPv4 / IPv6 literal.
    private static func ipBytes(_ s: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }

    private static func inPrefix(_ addr: [UInt8], _ net: [UInt8], _ bits: Int) -> Bool {
        guard addr.count == net.count else { return false }
        var remaining = bits
        for i in addr.indices where remaining > 0 {
            let take = min(8, remaining)
            let mask: UInt8 = ~(UInt8(0xFF) >> take)
            if addr[i] & mask != net[i] & mask { return false }
            remaining -= take
        }
        return true
    }
}
