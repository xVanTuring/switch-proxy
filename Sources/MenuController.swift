import Cocoa

/// Builds the status-bar menu and handles its actions. The menu is rebuilt every
/// time it opens so it always reflects live state (network, active proxy, system proxy).
final class MenuController: NSObject, NSMenuDelegate {
    private let store: ConfigStore
    private let relay: ProxyRelay
    private let monitor: NetworkMonitor

    /// Re-apply auto-switch after store/network changes.
    var onApplyAuto: (() -> Void)?

    private var managerWindowController: ProxyManagerWindowController?

    init(store: ConfigStore, relay: ProxyRelay, monitor: NetworkMonitor) {
        self.store = store
        self.relay = relay
        self.monitor = monitor
        super.init()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let networkID = monitor.refreshID()

        addInfo(menu, relay.running ? "● 运行中 · 127.0.0.1:\(store.listenPort)" : "○ 中转未启动")
        addInfo(menu, "当前网络：\(prettyNetwork(networkID))")
        addInfo(menu, "当前代理：\(store.activeConfig?.name ?? "直连")")

        menu.addItem(.separator())

        let auto = item("自动按网络切换", #selector(toggleAuto))
        auto.state = store.autoSwitch ? .on : .off
        menu.addItem(auto)

        menu.addItem(.separator())

        let direct = item("直连（不走代理）", #selector(selectConfig(_:)))
        direct.representedObject = "direct"
        direct.state = (store.activeID == nil) ? .on : .off
        menu.addItem(direct)

        for config in store.configs {
            let title = "\(config.name)   (\(config.kind.display) \(config.host):\(config.port))"
            let mi = item(title, #selector(selectConfig(_:)))
            mi.representedObject = config.id.uuidString
            mi.state = (store.activeID == config.id) ? .on : .off
            menu.addItem(mi)
        }

        menu.addItem(.separator())

        menu.addItem(item("管理代理…", #selector(openManager)))

        menu.addItem(.separator())

        let sysOn = SystemProxy.isEnabled(port: store.listenPort)
        let sysItem = item(sysOn ? "取消系统代理" : "设为系统代理", #selector(toggleSystemProxy))
        sysItem.state = sysOn ? .on : .off
        menu.addItem(sysItem)

        let loginOn = LaunchAtLogin.isEnabled
        let loginItem = item("开机自启", #selector(toggleLaunchAtLogin))
        loginItem.state = loginOn ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(quit), key: "q"))
    }

    // MARK: Builders

    private func addInfo(_ menu: NSMenu, _ text: String) {
        let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        menu.addItem(mi)
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    private func configID(from sender: NSMenuItem) -> UUID? {
        guard let s = sender.representedObject as? String else { return nil }
        return UUID(uuidString: s)
    }

    // MARK: Actions

    @objc private func toggleAuto() {
        store.autoSwitch.toggle()
        store.save()
        if store.autoSwitch { onApplyAuto?() }
    }

    @objc private func selectConfig(_ sender: NSMenuItem) {
        store.autoSwitch = false // explicit manual choice disables auto
        if (sender.representedObject as? String) == "direct" {
            store.setActive(nil)
        } else if let id = configID(from: sender) {
            store.setActive(id)
        }
        store.save()
    }

    @objc private func openManager() {
        if managerWindowController == nil {
            managerWindowController = ProxyManagerWindowController(
                store: store,
                monitor: monitor,
                onChange: { [weak self] in self?.onApplyAuto?() },
                onApplyPort: { [weak self] port in self?.applyListenPort(port) ?? false }
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        managerWindowController?.refresh()
        managerWindowController?.showWindow(nil)
        managerWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Change the local listen port: restart the relay and re-point the system proxy
    /// if it was already enabled (so we don't strand it on the old port).
    private func applyListenPort(_ port: Int) -> Bool {
        guard (1...65535).contains(port), port != store.listenPort else { return false }
        let wasSystemProxy = SystemProxy.isEnabled(port: store.listenPort)
        store.listenPort = port
        store.save()
        relay.restart(port: UInt16(port))
        if wasSystemProxy {
            _ = SystemProxy.enable(port: port)
        }
        return true
    }

    @objc private func toggleSystemProxy() {
        if SystemProxy.isEnabled(port: store.listenPort) {
            _ = SystemProxy.disable()
        } else {
            _ = SystemProxy.enable(port: store.listenPort)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let target = !LaunchAtLogin.isEnabled
        if LaunchAtLogin.set(target), target, LaunchAtLogin.requiresApproval {
            let alert = NSAlert()
            alert.messageText = "需要在系统设置中允许"
            alert.informativeText = "请在「系统设置 → 通用 → 登录项」中允许 SwitchProxy 开机启动。"
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
