import Foundation

/// Upstream proxy protocol.
enum ProxyKind: String, Codable, CaseIterable {
    case http
    case socks5

    var display: String { self == .http ? "HTTP" : "SOCKS5" }
}

/// A single configured upstream proxy.
struct ProxyConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var kind: ProxyKind
    var host: String
    var port: Int
    var username: String? = nil
    var password: String? = nil
    /// Network identifiers (e.g. "wifi:Home", "gw:192.168.1.1") that auto-activate this config.
    var matchNetworks: [String] = []
}

/// Loads/saves configs and the current selection. Thread-safe snapshot for the relay.
final class ConfigStore {
    private let defaults = UserDefaults.standard
    private let storageKey = "switchproxy.state.v1"

    private(set) var configs: [ProxyConfig] = []
    var activeID: UUID?
    var autoSwitch: Bool = true
    var listenPort: Int = 1087
    var hideTitleBar: Bool = false
    /// Remembered intent: re-apply the system proxy on launch, clear it on quit.
    var systemProxyEnabled: Bool = false

    private let lock = NSLock()
    private var snapshot: ProxyConfig?

    init() {
        load()
        refreshSnapshot()
    }

    /// The config currently selected (nil == direct / no proxy).
    var activeConfig: ProxyConfig? {
        guard let id = activeID else { return nil }
        return configs.first { $0.id == id }
    }

    /// Thread-safe read used by the relay from background queues.
    var activeUpstream: ProxyConfig? {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    // MARK: Mutations (call on main thread)

    func add(_ config: ProxyConfig) {
        configs.append(config)
        save()
    }

    func update(_ config: ProxyConfig) {
        if let idx = configs.firstIndex(where: { $0.id == config.id }) {
            configs[idx] = config
            save()
        }
    }

    func remove(id: UUID) {
        configs.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
        save()
    }

    func setActive(_ id: UUID?) {
        activeID = id
        save()
    }

    /// Bind a network identifier to a single config (removing it from any others).
    func bindNetwork(_ networkID: String, to configID: UUID) {
        for i in configs.indices {
            configs[i].matchNetworks.removeAll { $0 == networkID }
        }
        if let idx = configs.firstIndex(where: { $0.id == configID }) {
            configs[idx].matchNetworks.append(networkID)
        }
        save()
    }

    /// Config whose match rules include the given network identifier.
    func config(matching networkID: String) -> ProxyConfig? {
        configs.first { $0.matchNetworks.contains(networkID) }
    }

    // MARK: Persistence

    private struct Persisted: Codable {
        var configs: [ProxyConfig]
        var activeID: UUID?
        var autoSwitch: Bool
        var listenPort: Int
        var hideTitleBar: Bool?          // optional for backward compatibility with older data
        var systemProxyEnabled: Bool?    // optional for backward compatibility with older data
    }

    func save() {
        let p = Persisted(configs: configs, activeID: activeID, autoSwitch: autoSwitch,
                          listenPort: listenPort, hideTitleBar: hideTitleBar,
                          systemProxyEnabled: systemProxyEnabled)
        if let data = try? JSONEncoder().encode(p) {
            defaults.set(data, forKey: storageKey)
        }
        refreshSnapshot()
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        configs = p.configs
        activeID = p.activeID
        autoSwitch = p.autoSwitch
        listenPort = p.listenPort
        hideTitleBar = p.hideTitleBar ?? false
        systemProxyEnabled = p.systemProxyEnabled ?? false
    }

    private func refreshSnapshot() {
        lock.lock()
        snapshot = activeConfig
        lock.unlock()
    }
}
