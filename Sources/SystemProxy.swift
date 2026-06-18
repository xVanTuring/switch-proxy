import Foundation

/// Configures the macOS system HTTP/HTTPS proxy to point at our local relay.
/// Writing proxy settings requires root. To avoid a password prompt on every
/// toggle (including launch/quit), we install a narrowly-scoped passwordless
/// sudo rule once (one admin prompt) and then run `networksetup` via `sudo -n`.
enum SystemProxy {

    private static let networksetup = "/usr/sbin/networksetup"
    private static let sudoersPath = "/etc/sudoers.d/switchproxy"

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
    static func enable(port: Int) -> Bool { setSystemProxy(on: true, port: port) }

    @discardableResult
    static func disable() -> Bool { setSystemProxy(on: false, port: 0) }

    /// Point the system web/secure-web proxy at 127.0.0.1:port (on) or turn it off.
    /// Runs silently via passwordless sudo when the rule is installed; otherwise falls
    /// back to a single admin prompt that also installs the rule for next time.
    private static func setSystemProxy(on: Bool, port: Int) -> Bool {
        let services = targetServices()
        guard !services.isEmpty else { return false }

        var cmds: [[String]] = []
        for s in services {
            if on {
                cmds.append(["-setwebproxy", s, "127.0.0.1", String(port)])
                cmds.append(["-setsecurewebproxy", s, "127.0.0.1", String(port)])
                cmds.append(["-setwebproxystate", s, "on"])
                cmds.append(["-setsecurewebproxystate", s, "on"])
            } else {
                cmds.append(["-setwebproxystate", s, "off"])
                cmds.append(["-setsecurewebproxystate", s, "off"])
            }
        }

        if hasPasswordlessSudo() {
            var ok = true
            for args in cmds where Shell.run("/usr/bin/sudo", ["-n", networksetup] + args).status != 0 {
                ok = false
            }
            return ok
        }
        return runAdminInstallAndApply(cmds)
    }

    // MARK: Passwordless sudo

    /// True when the sudoers rule lets us toggle the proxy without a password.
    static func hasPasswordlessSudo() -> Bool {
        // -n never prompts; -l checks the policy. Exits 0 only if allowed NOPASSWD.
        Shell.run("/usr/bin/sudo",
                  ["-n", "-l", networksetup, "-setwebproxystate", "Wi-Fi", "off"]).status == 0
    }

    /// One admin prompt: validate + install the sudoers rule, then apply the proxy
    /// commands. Installing is best-effort — the proxy still applies if it fails.
    private static func runAdminInstallAndApply(_ cmds: [[String]]) -> Bool {
        let user = NSUserName()
        let rule = "\(user) ALL=(root) NOPASSWD: "
            + ["-setwebproxy", "-setsecurewebproxy", "-setwebproxystate", "-setsecurewebproxystate"]
                .map { "\(networksetup) \($0) *" }
                .joined(separator: ", ")
        let body = "# SwitchProxy: toggle the system web proxy without a password.\n\(rule)\n"

        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("switchproxy.sudoers")
        guard (try? body.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else {
            return false
        }
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let install = "/usr/sbin/visudo -cf '\(tmp)' && "
            + "/usr/bin/install -m 0440 -o root -g wheel '\(tmp)' '\(sudoersPath)'"
        let apply = cmds.map { shellQuoted([networksetup] + $0) }.joined(separator: " ; ")
        return runAdmin("(\(install)) ; \(apply)")
    }

    /// Quote an argv into a single-quoted shell command (preserves spaces in service names).
    private static func shellQuoted(_ argv: [String]) -> String {
        argv.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
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
