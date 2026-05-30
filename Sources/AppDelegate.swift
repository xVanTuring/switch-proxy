import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ConfigStore()
    private let relay = ProxyRelay()
    private let monitor = NetworkMonitor()
    private var menuController: MenuController!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Relay forwards to whatever config is active right now.
        relay.activeConfigProvider = { [weak self] in self?.store.activeUpstream }
        do {
            try relay.start(port: UInt16(store.listenPort))
        } catch {
            NSLog("SwitchProxy: relay failed to start on port \(store.listenPort): \(error)")
        }

        // Auto-switch on network changes.
        monitor.onChange = { [weak self] _ in self?.applyAuto() }
        monitor.start()

        setupStatusItem()
        applyAuto()

        // A second launch asks the running instance (via this notification) to show
        // its manager window.
        let name = Notification.Name("\(Bundle.main.bundleIdentifier ?? "tech.xvanturing.SwitchProxy").showManager")
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleShowManager), name: name, object: nil)
    }

    /// Re-show the manager window when the app is reopened (Finder/Dock/`open`).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        menuController?.presentManager()
        return true
    }

    @objc private func handleShowManager() {
        NSApp.activate(ignoringOtherApps: true)
        menuController?.presentManager()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Avoid leaving the system without internet: if the system proxy still points
        // at our relay, turn it off before we exit.
        if SystemProxy.isEnabled(port: store.listenPort) {
            _ = SystemProxy.disable()
        }
        relay.stop()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "arrow.left.arrow.right.circle",
                                accessibilityDescription: "Switch Proxy")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menuController = MenuController(store: store, relay: relay, monitor: monitor)
        menuController.onApplyAuto = { [weak self] in self?.applyAuto() }
        menu.delegate = menuController
        statusItem.menu = menu
    }

    /// If auto-switch is on, activate the config bound to the current network.
    private func applyAuto() {
        guard store.autoSwitch else { return }
        let networkID = monitor.refreshID()
        if let match = store.config(matching: networkID), store.activeID != match.id {
            store.setActive(match.id)
        }
    }
}
