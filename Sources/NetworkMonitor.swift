import Foundation
import Network
import CoreWLAN

/// Watches for network changes and computes a stable identifier for the current
/// network so configs can be auto-selected.
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "switchproxy.netmonitor")

    /// Called on the main thread whenever the active network identifier changes.
    var onChange: ((String) -> Void)?

    private(set) var currentID: String = "unknown"

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let id = self.computeID(path)
            let changed = (id != self.currentID)
            self.currentID = id
            if changed {
                DispatchQueue.main.async { self.onChange?(id) }
            }
        }
        monitor.start(queue: queue)
    }

    /// Recompute and return the identifier on demand (e.g. when opening the menu).
    @discardableResult
    func refreshID() -> String {
        let id = computeID(monitor.currentPath)
        currentID = id
        return id
    }

    private func computeID(_ path: NWPath) -> String {
        guard path.status == .satisfied else { return "offline" }
        if let ssid = currentSSID(), !ssid.isEmpty {
            return "wifi:\(ssid)"
        }
        if let gateway = defaultGateway() {
            return "gw:\(gateway)"
        }
        return "net:up"
    }

    private func currentSSID() -> String? {
        // May return nil without Location permission on recent macOS; we fall back to the gateway.
        CWWiFiClient.shared().interface()?.ssid()
    }

    private func defaultGateway() -> String? {
        let out = Shell.run("/sbin/route", ["-n", "get", "default"]).output
        for raw in out.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("gateway:") {
                let value = line.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}

/// Human-friendly label for a network identifier.
func prettyNetwork(_ id: String) -> String {
    if id == "offline" { return "未联网" }
    if id == "unknown" { return "未知" }
    if id == "net:up" { return "已联网" }
    if id.hasPrefix("wifi:") { return "Wi-Fi " + String(id.dropFirst(5)) }
    if id.hasPrefix("gw:") { return "网关 " + String(id.dropFirst(3)) }
    return id
}
