import Foundation
import Network

/// Checks whether the current egress (local relay -> active upstream) actually works:
/// reachability + latency of well-known sites, and the public IP / location seen
/// by the outside world. All requests go through the local relay, so the result
/// reflects exactly the path the system proxy uses.
final class EgressChecker {
    struct Site {
        let name: String
        let url: URL
    }

    struct SiteResult {
        let site: Site
        /// HTTP status, nil when no HTTP response was received.
        let status: Int?
        let latencyMs: Int?
        let error: String?
        /// Any HTTP answer counts, except 5xx (usually the upstream proxy failing).
        var reachable: Bool {
            guard let s = status else { return false }
            return s < 500
        }
    }

    struct IPInfo {
        let ip: String
        let country: String?
        let region: String?
        let city: String?
        let org: String?
        let source: String

        var location: String {
            [city, region, country]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .reduce(into: [String]()) { acc, s in if !acc.contains(s) { acc.append(s) } }
                .joined(separator: ", ")
        }
    }

    static let sites: [Site] = [
        Site(name: "Google", url: URL(string: "https://www.google.com/generate_204")!),
        Site(name: "YouTube", url: URL(string: "https://www.youtube.com/generate_204")!),
        Site(name: "GitHub", url: URL(string: "https://github.com")!),
        Site(name: "Cloudflare", url: URL(string: "https://cp.cloudflare.com/generate_204")!),
        Site(name: "Baidu", url: URL(string: "https://www.baidu.com")!),
    ]

    /// IP lookup services, tried in order until one answers.
    private static let ipServices: [(name: String, url: URL)] = [
        ("ipinfo.io", URL(string: "https://ipinfo.io/json")!),
        ("ip.sb", URL(string: "https://api.ip.sb/geoip")!),
    ]

    /// IPv6-only endpoints (AAAA records only) that answer with the caller's IP as
    /// plain text. Reaching any of them proves the path has working IPv6.
    private static let ipv6Services: [URL] = [
        URL(string: "https://api6.ipify.org")!,
        URL(string: "https://ipv6.icanhazip.com")!,
        URL(string: "https://v6.ident.me")!,
    ]

    private let proxied: URLSession
    private let direct: URLSession

    /// - Parameter relayPort: the local relay port (127.0.0.1:<port>, HTTP proxy side).
    init(relayPort: Int, timeout: TimeInterval = 10) {
        let p = URLSessionConfiguration.ephemeral
        p.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: relayPort,
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: relayPort,
        ]
        EgressChecker.tune(p, timeout: timeout)
        proxied = URLSession(configuration: p)

        // Empty proxy dictionary == no proxy at all (ignores the system proxy).
        let d = URLSessionConfiguration.ephemeral
        d.connectionProxyDictionary = [:]
        EgressChecker.tune(d, timeout: timeout)
        direct = URLSession(configuration: d)
    }

    deinit {
        proxied.invalidateAndCancel()
        direct.invalidateAndCancel()
    }

    private static func tune(_ c: URLSessionConfiguration, timeout: TimeInterval) {
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
    }

    // MARK: Sites

    /// Probe one site through the relay. Completion runs on the main queue.
    func probe(_ site: Site, completion: @escaping (SiteResult) -> Void) {
        var req = URLRequest(url: site.url)
        req.httpMethod = "GET"
        req.setValue("SwitchProxy-EgressCheck", forHTTPHeaderField: "User-Agent")
        let start = Date()
        proxied.dataTask(with: req) { _, response, error in
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let result: SiteResult
            if let http = response as? HTTPURLResponse {
                result = SiteResult(site: site, status: http.statusCode, latencyMs: ms, error: nil)
            } else {
                result = SiteResult(site: site, status: nil, latencyMs: nil,
                                    error: EgressChecker.describe(error))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    // MARK: IP info

    /// Public IP as seen through the relay. Completion runs on the main queue.
    func lookupProxiedIP(completion: @escaping (Result<IPInfo, Error>) -> Void) {
        lookupIP(session: proxied, index: 0, lastError: nil, completion: completion)
    }

    /// Public IP when bypassing every proxy (for comparison). Main-queue completion.
    func lookupDirectIP(completion: @escaping (Result<IPInfo, Error>) -> Void) {
        lookupIP(session: direct, index: 0, lastError: nil, completion: completion)
    }

    // MARK: IPv6

    /// IPv6 egress address through the relay (failure == no IPv6). Main-queue completion.
    func lookupProxiedIPv6(completion: @escaping (Result<String, Error>) -> Void) {
        lookupIPv6(session: proxied, index: 0, lastError: nil, completion: completion)
    }

    /// IPv6 address of the local network, bypassing every proxy. Main-queue completion.
    func lookupDirectIPv6(completion: @escaping (Result<String, Error>) -> Void) {
        lookupIPv6(session: direct, index: 0, lastError: nil, completion: completion)
    }

    private func lookupIPv6(session: URLSession, index: Int, lastError: Error?,
                            completion: @escaping (Result<String, Error>) -> Void) {
        guard index < Self.ipv6Services.count else {
            let err = lastError ?? URLError(.cannotLoadFromNetwork)
            DispatchQueue.main.async { completion(.failure(err)) }
            return
        }
        var req = URLRequest(url: Self.ipv6Services[index])
        req.setValue("SwitchProxy-EgressCheck", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req) { [weak self] data, response, error in
            if let data = data,
               (response as? HTTPURLResponse)?.statusCode == 200,
               let text = String(data: data, encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               IPv6Address(text) != nil {
                DispatchQueue.main.async { completion(.success(text)) }
                return
            }
            let err = error ?? URLError(.badServerResponse)
            self?.lookupIPv6(session: session, index: index + 1, lastError: err, completion: completion)
        }.resume()
    }

    private func lookupIP(session: URLSession, index: Int, lastError: Error?,
                          completion: @escaping (Result<IPInfo, Error>) -> Void) {
        guard index < Self.ipServices.count else {
            let err = lastError ?? URLError(.cannotLoadFromNetwork)
            DispatchQueue.main.async { completion(.failure(err)) }
            return
        }
        let service = Self.ipServices[index]
        var req = URLRequest(url: service.url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("SwitchProxy-EgressCheck", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req) { [weak self] data, response, error in
            if let data = data,
               (response as? HTTPURLResponse)?.statusCode == 200,
               let info = Self.parseIP(data, source: service.name) {
                DispatchQueue.main.async { completion(.success(info)) }
                return
            }
            let err = error ?? URLError(.badServerResponse)
            self?.lookupIP(session: session, index: index + 1, lastError: err, completion: completion)
        }.resume()
    }

    /// Understands both ipinfo.io and api.ip.sb JSON shapes.
    private static func parseIP(_ data: Data, source: String) -> IPInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = obj["ip"] as? String, !ip.isEmpty else { return nil }
        func str(_ keys: String...) -> String? {
            for k in keys {
                if let v = obj[k] as? String, !v.isEmpty { return v }
            }
            return nil
        }
        var org = str("org", "organization", "isp")
        if org == nil, let asn = obj["asn"] {
            org = "AS\(asn)"
        }
        return IPInfo(ip: ip,
                      country: str("country", "country_code"),
                      region: str("region"),
                      city: str("city"),
                      org: org,
                      source: source)
    }

    // MARK: Errors

    static func describe(_ error: Error?) -> String {
        guard let error = error else { return L("No response") }
        if let e = error as? URLError {
            switch e.code {
            case .timedOut: return L("Timed out")
            case .cannotConnectToHost: return L("Cannot connect")
            case .cannotFindHost, .dnsLookupFailed: return L("DNS lookup failed")
            case .networkConnectionLost: return L("Connection lost")
            case .notConnectedToInternet: return L("No network")
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot:
                return L("TLS handshake failed")
            default: break
            }
        }
        return error.localizedDescription
    }
}
