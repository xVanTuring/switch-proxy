import Cocoa

/// "Check Egress" window: runs `EgressChecker` against the local relay and shows
/// the public IP / location plus per-site reachability and latency.
final class EgressCheckWindowController: NSWindowController, NSWindowDelegate {
    private let store: ConfigStore
    private let relay: ProxyRelay

    private var textView: NSTextView!
    private var statusLabel: NSTextField!
    private var runButton: NSButton!
    private var spinner: NSProgressIndicator!

    private var checker: EgressChecker?
    /// Increments per run so late callbacks from an older run are ignored.
    private var runID = 0
    private var pending = 0

    // Collected state for the current run (main thread only).
    private var upstreamLine = ""
    private var proxiedIP: Result<EgressChecker.IPInfo, Error>?
    private var directIP: Result<EgressChecker.IPInfo, Error>?
    private var proxiedIPv6: Result<String, Error>?
    private var directIPv6: Result<String, Error>?
    private var checkDirect = false
    /// False when the run could not start (relay down); placeholders show "-".
    private var started = false
    private var siteResults: [String: EgressChecker.SiteResult] = [:]

    init(store: ConfigStore, relay: ProxyRelay) {
        self.store = store
        self.relay = relay
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("Egress Check")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 300)
        super.init(window: window)
        window.delegate = self
        window.center()
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        textView = scroll.documentView as? NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        content.addSubview(scroll)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        runButton = NSButton(title: L("Check Again"), target: self, action: #selector(runCheck))
        runButton.bezelStyle = .rounded
        runButton.keyEquivalent = "\r"

        let row = NSStackView(views: [spinner, statusLabel, NSView(), runButton])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: row.topAnchor, constant: -12),

            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    // MARK: Run

    /// What to check: the live egress (main relay + active upstream), or one
    /// specific config through a temporary relay (the active proxy is not touched).
    enum Target {
        case current
        case config(ProxyConfig)
    }

    private var target: Target = .current
    /// Temporary relay used when checking a specific config.
    private var tempRelay: ProxyRelay?

    /// Start a check for the given target.
    func check(_ target: Target) {
        self.target = target
        runCheck()
    }

    @objc func runCheck() {
        runID += 1
        let id = runID
        stopTempRelay()
        proxiedIP = nil
        directIP = nil
        proxiedIPv6 = nil
        directIPv6 = nil
        siteResults = [:]
        checkDirect = false
        started = false

        switch target {
        case .current:
            window?.title = L("Egress Check")
            let port = store.listenPort
            if let up = store.activeConfig {
                upstreamLine = LF("Upstream: %@ (%@ %@:%ld)", up.name, up.kind.display, up.host, up.port)
            } else {
                upstreamLine = L("Upstream: Direct (no proxy)")
            }
            upstreamLine += "\n" + LF("Via local relay 127.0.0.1:%ld", port)
            guard relay.running else {
                render()
                statusLabel.stringValue = L("Local relay is not running, cannot check.")
                return
            }
            startChecks(id: id, port: port, compareDirect: store.activeConfig != nil)

        case .config(let config):
            window?.title = LF("Egress Check — %@", config.name)
            upstreamLine = LF("Checking proxy: %@ (%@ %@:%ld)", config.name, config.kind.display,
                              config.host, config.port)
            upstreamLine += "\n" + L("Via a temporary relay; the active proxy is not changed")
            render()
            beginBusy()

            let temp = ProxyRelay()
            temp.activeConfigProvider = { config }
            temp.bypassProvider = { [weak self] in self?.store.activeBypass ?? ProxyBypass([]) }
            var handled = false
            temp.onReady = { [weak self] port in
                guard let self = self, self.runID == id, !handled else { return }
                handled = true
                guard let port = port else {
                    self.endBusy(L("Temporary relay failed to start, cannot check."))
                    self.stopTempRelay()
                    return
                }
                self.upstreamLine = LF("Checking proxy: %@ (%@ %@:%ld)", config.name, config.kind.display,
                                       config.host, config.port)
                    + "\n" + LF("Via temporary relay 127.0.0.1:%ld; the active proxy is not changed", Int(port))
                self.startChecks(id: id, port: Int(port), compareDirect: true)
            }
            tempRelay = temp
            do {
                try temp.start(port: 0) // 0 = let the system pick a free port
            } catch {
                handled = true
                endBusy(L("Temporary relay failed to start, cannot check."))
                stopTempRelay()
            }
        }
    }

    private func startChecks(id: Int, port: Int, compareDirect: Bool) {
        let checker = EgressChecker(relayPort: port)
        self.checker = checker
        // Compare with the no-proxy IP only when an upstream is in use.
        checkDirect = compareDirect
        started = true
        // IP + IPv6 through the relay, and the same two direct when comparing.
        pending = EgressChecker.sites.count + 2 + (checkDirect ? 2 : 0)

        beginBusy()
        render()

        checker.lookupProxiedIP { [weak self] r in
            guard let self = self, self.runID == id else { return }
            self.proxiedIP = r
            self.stepDone()
        }
        checker.lookupProxiedIPv6 { [weak self] r in
            guard let self = self, self.runID == id else { return }
            self.proxiedIPv6 = r
            self.stepDone()
        }
        if checkDirect {
            checker.lookupDirectIP { [weak self] r in
                guard let self = self, self.runID == id else { return }
                self.directIP = r
                self.stepDone()
            }
            checker.lookupDirectIPv6 { [weak self] r in
                guard let self = self, self.runID == id else { return }
                self.directIPv6 = r
                self.stepDone()
            }
        }
        for site in EgressChecker.sites {
            checker.probe(site) { [weak self] r in
                guard let self = self, self.runID == id else { return }
                self.siteResults[site.name] = r
                self.stepDone()
            }
        }
    }

    private func stepDone() {
        pending -= 1
        render()
        guard pending <= 0 else { return }
        stopTempRelay()
        let ok = siteResults.values.filter { $0.reachable }.count
        endBusy(LF("Done: %ld of %ld sites reachable", ok, EgressChecker.sites.count))
    }

    private func beginBusy() {
        runButton.isEnabled = false
        spinner.startAnimation(nil)
        statusLabel.stringValue = L("Checking…")
    }

    private func endBusy(_ message: String) {
        spinner.stopAnimation(nil)
        runButton.isEnabled = true
        statusLabel.stringValue = message
    }

    private func stopTempRelay() {
        tempRelay?.onReady = nil
        tempRelay?.stop()
        tempRelay = nil
    }

    func windowWillClose(_ notification: Notification) {
        runID += 1 // drop late callbacks
        stopTempRelay()
        endBusy("")
    }

    // MARK: Rendering

    private func render() {
        var lines: [String] = [upstreamLine, ""]

        lines.append("── " + L("Egress IP") + " ──")
        switch proxiedIP {
        case nil:
            lines.append(started ? L("Querying…") : "-")
        case .failure(let e)?:
            lines.append("❌ " + LF("Lookup failed: %@", EgressChecker.describe(e)))
        case .success(let info)?:
            lines.append(pad(L("IP")) + info.ip)
            if !info.location.isEmpty { lines.append(pad(L("Location")) + info.location) }
            if let org = info.org { lines.append(pad(L("Network")) + org) }
            lines.append(pad(L("Source")) + info.source)
        }

        if checkDirect {
            lines.append("")
            switch directIP {
            case nil:
                lines.append(pad(L("Direct IP")) + L("Querying…"))
            case .failure?:
                lines.append(pad(L("Direct IP")) + L("Unavailable"))
            case .success(let d)?:
                lines.append(pad(L("Direct IP")) + d.ip)
                if case .success(let p)? = proxiedIP {
                    lines.append(p.ip == d.ip
                        ? "⚠️ " + L("Egress IP equals direct IP: the proxy may not be in effect.")
                        : "✅ " + L("Egress IP differs from direct IP: the proxy is in effect."))
                }
            }
        }

        lines.append("")
        lines.append("── " + L("IPv6") + " ──")
        switch proxiedIPv6 {
        case nil:
            lines.append(pad(L("Egress IPv6")) + (started ? L("Querying…") : "-"))
        case .failure(let e)?:
            lines.append("❌ " + pad(L("Egress IPv6")) + L("Not supported")
                         + " (" + EgressChecker.describe(e) + ")")
        case .success(let ip)?:
            lines.append("✅ " + pad(L("Egress IPv6")) + ip)
        }
        if checkDirect {
            switch directIPv6 {
            case nil:
                lines.append(pad(L("Direct IPv6")) + L("Querying…"))
            case .failure?:
                lines.append(pad(L("Direct IPv6")) + L("Not supported"))
            case .success(let ip)?:
                lines.append(pad(L("Direct IPv6")) + ip)
            }
        }

        lines.append("")
        lines.append("── " + L("Site Reachability") + " ──")
        for site in EgressChecker.sites {
            let name = site.name.padding(toLength: 12, withPad: " ", startingAt: 0)
            guard let r = siteResults[site.name] else {
                lines.append("…  " + name + (started ? L("Checking…") : "-"))
                continue
            }
            if r.reachable, let status = r.status, let ms = r.latencyMs {
                lines.append("✅ " + name + String(format: "%-5ld", status) + LF("%ld ms", ms))
            } else if let status = r.status {
                lines.append("❌ " + name + LF("HTTP %ld", status))
            } else {
                lines.append("❌ " + name + (r.error ?? L("No response")))
            }
        }

        textView.string = lines.joined(separator: "\n")
    }

    private func pad(_ label: String) -> String {
        label + L(": ")
    }
}
