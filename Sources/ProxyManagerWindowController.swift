import Cocoa

/// The "管理代理" window: lists all configs and provides add / edit / delete and
/// "bind current network" actions in one place.
final class ProxyManagerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: ConfigStore
    private let monitor: NetworkMonitor
    private let onChange: () -> Void
    /// Returns true if the port change was applied (relay restarted).
    private let onApplyPort: (Int) -> Bool

    private var tableView: NSTableView!
    private var networkLabel: NSTextField!
    private var portField: NSTextField!
    private var topConstraint: NSLayoutConstraint!

    init(store: ConfigStore,
         monitor: NetworkMonitor,
         onChange: @escaping () -> Void,
         onApplyPort: @escaping (Int) -> Bool) {
        self.store = store
        self.monitor = monitor
        self.onChange = onChange
        self.onApplyPort = onApplyPort

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "管理代理"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 260)
        super.init(window: window)
        window.center()
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let portTitle = NSTextField(labelWithString: "本地监听端口：")
        portField = NSTextField()
        portField.translatesAutoresizingMaskIntoConstraints = false
        portField.placeholderString = "1087"
        portField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let applyPortButton = makeButton("应用", #selector(applyPort))
        let portRow = NSStackView(views: [portTitle, portField, applyPortButton, NSView()])
        portRow.spacing = 8
        portRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(portRow)

        networkLabel = NSTextField(labelWithString: "")
        networkLabel.translatesAutoresizingMaskIntoConstraints = false
        networkLabel.textColor = .secondaryLabelColor
        content.addSubview(networkLabel)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 22
        tableView.doubleAction = #selector(editSelected)
        tableView.target = self

        for (id, title, width) in [("name", "名称", 110), ("kind", "类型", 70),
                                    ("addr", "地址", 170), ("net", "绑定网络", 170)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            column.minWidth = 40
            tableView.addTableColumn(column)
        }
        scroll.documentView = tableView
        content.addSubview(scroll)

        let addButton = makeButton("添加", #selector(addConfig))
        let editButton = makeButton("编辑", #selector(editSelected))
        let deleteButton = makeButton("删除", #selector(deleteSelected))
        let bindButton = makeButton("把当前网络绑定到所选", #selector(bindSelected))

        let leftStack = NSStackView(views: [addButton, editButton, deleteButton])
        leftStack.spacing = 8
        let row = NSStackView(views: [leftStack, NSView(), bindButton])
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)

        topConstraint = portRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 14)

        NSLayoutConstraint.activate([
            portRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            portRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            topConstraint,

            networkLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            networkLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            networkLabel.topAnchor.constraint(equalTo: portRow.bottomAnchor, constant: 10),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: networkLabel.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: row.topAnchor, constant: -12),

            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])

        applyTitleBarHidden(store.hideTitleBar)
    }

    /// Toggle the window's title bar. When hidden, the content fills under the
    /// transparent titlebar and is nudged down so it clears the traffic-light buttons
    /// (which stay visible so the window remains movable/closable).
    func applyTitleBarHidden(_ hidden: Bool) {
        guard let window = window else { return }
        if hidden {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            topConstraint?.constant = 36
        } else {
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.styleMask.remove(.fullSizeContentView)
            topConstraint?.constant = 14
        }
    }

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    /// Refresh table + network label + port field (call before showing).
    func refresh() {
        let id = monitor.refreshID()
        networkLabel.stringValue = "当前网络：\(prettyNetwork(id))"
        portField?.stringValue = String(store.listenPort)
        tableView?.reloadData()
    }

    private func selectedConfig() -> ProxyConfig? {
        let row = tableView.selectedRow
        guard row >= 0, row < store.configs.count else { return nil }
        return store.configs[row]
    }

    private func reloadAndNotify() {
        tableView.reloadData()
        onChange()
    }

    // MARK: Actions

    @objc private func applyPort() {
        let text = portField.stringValue.trimmingCharacters(in: .whitespaces)
        guard let port = Int(text), (1...65535).contains(port) else {
            let alert = NSAlert()
            alert.messageText = "端口无效"
            alert.informativeText = "请输入 1–65535 之间的端口。"
            alert.runModal()
            return
        }
        if port == store.listenPort { return }
        if onApplyPort(port) {
            let alert = NSAlert()
            alert.messageText = "已切换到端口 \(port)"
            alert.informativeText = "本地中转已在新端口重启。如已设为系统代理，将自动重新指向新端口。"
            alert.runModal()
        }
        refresh()
    }

    @objc private func addConfig() {
        if let config = ConfigEditor.present(existing: nil) {
            store.add(config)
            reloadAndNotify()
            tableView.selectRowIndexes(IndexSet(integer: store.configs.count - 1), byExtendingSelection: false)
        }
    }

    @objc private func editSelected() {
        guard let existing = selectedConfig() else { return }
        if let updated = ConfigEditor.present(existing: existing) {
            store.update(updated)
            reloadAndNotify()
        }
    }

    @objc private func deleteSelected() {
        guard let config = selectedConfig() else { return }
        let alert = NSAlert()
        alert.messageText = "删除配置“\(config.name)”？"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            store.remove(id: config.id)
            reloadAndNotify()
        }
    }

    @objc private func bindSelected() {
        guard let config = selectedConfig() else {
            beepNoSelection()
            return
        }
        let id = monitor.refreshID()
        guard !["offline", "unknown"].contains(id) else {
            let alert = NSAlert()
            alert.messageText = "当前网络不可识别"
            alert.informativeText = "未联网或无法获取网络标识，暂时无法绑定。"
            alert.runModal()
            return
        }
        store.bindNetwork(id, to: config.id)
        refresh()
        onChange()
    }

    private func beepNoSelection() {
        NSSound.beep()
    }

    // MARK: Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.configs.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < store.configs.count else { return nil }
        let config = store.configs[row]
        let text: String
        switch column.identifier.rawValue {
        case "name": text = config.name
        case "kind": text = config.kind.display
        case "addr":
            let auth = (config.username?.isEmpty == false) ? " 🔐" : ""
            text = "\(config.host):\(config.port)\(auth)"
        case "net":
            text = config.matchNetworks.map(prettyNetwork).joined(separator: ", ")
        default: text = ""
        }

        let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = column.identifier
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = text
        return cell
    }
}
