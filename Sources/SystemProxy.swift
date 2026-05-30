import Foundation

/// Configures the macOS system HTTP/HTTPS proxy to point at our local relay.
/// Writing proxy settings requires admin rights, so changes run through one
/// `osascript ... with administrator privileges` prompt.
enum SystemProxy {

    /// Network services that are enabled (the system proxy is applied to all of them
    /// so the relay stays active regardless of which interface a location uses).
    static func enabledServices() -> [String] {
        let out = Shell.run("/usr/sbin/networksetup", ["-listallnetworkservices"]).output
        var result: [String] = []
        for (i, raw) in out.components(separatedBy: "\n").enumerated() {
            if i == 0 { continue } // first line is an explanatory header
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("*") { continue } // "*" == disabled
            result.append(line)
        }
        return result
    }

    /// The network service backing the current default route (e.g. "Wi-Fi").
    static func primaryService() -> String? {
        let route = Shell.run("/sbin/route", ["-n", "get", "default"]).output
        var device: String?
        for raw in route.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("interface:") {
                device = line.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        guard let dev = device else { return nil }

        let order = Shell.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"]).output
        var lastName: String?
        for raw in order.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let r = line.range(of: #"^\(\d+\)\s+"#, options: .regularExpression) {
                var name = String(line[r.upperBound...])
                if name.hasPrefix("* ") { name = String(name.dropFirst(2)) }
                lastName = name
            } else if line.contains("Device: \(dev))") || line.contains("Device: \(dev),") {
                return lastName
            }
        }
        return nil
    }

    /// Whether the system proxy is currently pointed at 127.0.0.1:<port>.
    static func isEnabled(port: Int) -> Bool {
        guard let service = primaryService() else { return false }
        let out = Shell.run("/usr/sbin/networksetup", ["-getwebproxy", service]).output
        return out.contains("Enabled: Yes")
            && out.contains("127.0.0.1")
            && out.contains("Port: \(port)")
    }

    @discardableResult
    static func enable(port: Int) -> Bool {
        let services = targetServices()
        guard !services.isEmpty else { return false }
        var cmds: [String] = []
        for s in services {
            cmds.append("/usr/sbin/networksetup -setwebproxy \"\(s)\" 127.0.0.1 \(port)")
            cmds.append("/usr/sbin/networksetup -setsecurewebproxy \"\(s)\" 127.0.0.1 \(port)")
            cmds.append("/usr/sbin/networksetup -setwebproxystate \"\(s)\" on")
            cmds.append("/usr/sbin/networksetup -setsecurewebproxystate \"\(s)\" on")
        }
        return runAdmin(cmds.joined(separator: " ; "))
    }

    @discardableResult
    static func disable() -> Bool {
        let services = targetServices()
        guard !services.isEmpty else { return false }
        var cmds: [String] = []
        for s in services {
            cmds.append("/usr/sbin/networksetup -setwebproxystate \"\(s)\" off")
            cmds.append("/usr/sbin/networksetup -setsecurewebproxystate \"\(s)\" off")
        }
        return runAdmin(cmds.joined(separator: " ; "))
    }

    private static func targetServices() -> [String] {
        var services = enabledServices()
        if services.isEmpty, let primary = primaryService() {
            services = [primary]
        }
        return services
    }

    /// Runs a shell command line with administrator privileges (single GUI auth prompt).
    private static func runAdmin(_ shellCommand: String) -> Bool {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return Shell.run("/usr/bin/osascript", ["-e", script]).status == 0
    }
}
