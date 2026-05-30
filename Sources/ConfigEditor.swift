import Cocoa

/// Modal form (NSAlert + grid) for adding or editing a proxy config.
enum ConfigEditor {

    static func present(existing: ProxyConfig?) -> ProxyConfig? {
        let alert = NSAlert()
        alert.messageText = existing == nil ? "添加代理配置" : "编辑代理配置"
        alert.informativeText = "上游代理服务器信息。用户名/密码留空表示无需认证。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let nameField = textField(existing?.name ?? "", placeholder: "例如：家里 / 公司")
        let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        kindPopup.addItems(withTitles: ["HTTP", "SOCKS5"])
        kindPopup.selectItem(withTitle: (existing?.kind ?? .http).display)
        let hostField = textField(existing?.host ?? "", placeholder: "127.0.0.1")
        let portField = textField(existing.map { String($0.port) } ?? "", placeholder: "7890")
        let userField = textField(existing?.username ?? "", placeholder: "可选")
        let passField = secureField(existing?.password ?? "")

        let grid = NSGridView(views: [
            [label("名称"), nameField],
            [label("类型"), kindPopup],
            [label("地址"), hostField],
            [label("端口"), portField],
            [label("用户名"), userField],
            [label("密码"), passField],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = true
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        for field in [nameField, hostField, portField, userField, passField] {
            field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }
        kindPopup.translatesAutoresizingMaskIntoConstraints = false
        kindPopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        grid.layoutSubtreeIfNeeded()
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        alert.accessoryView = grid

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let portText = portField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !host.isEmpty, let port = Int(portText), (1...65535).contains(port) else {
            let e = NSAlert()
            e.messageText = "信息不完整"
            e.informativeText = "请填写名称、地址，以及 1–65535 之间的端口。"
            e.runModal()
            return nil
        }

        let kind: ProxyKind = (kindPopup.titleOfSelectedItem == "SOCKS5") ? .socks5 : .http
        let user = userField.stringValue.isEmpty ? nil : userField.stringValue
        let pass = passField.stringValue.isEmpty ? nil : passField.stringValue

        var config = existing ?? ProxyConfig(name: name, kind: kind, host: host, port: port)
        config.name = name
        config.kind = kind
        config.host = host
        config.port = port
        config.username = user
        config.password = pass
        return config
    }

    private static func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private static func textField(_ value: String, placeholder: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private static func secureField(_ value: String) -> NSSecureTextField {
        let field = NSSecureTextField(string: value)
        field.placeholderString = "可选"
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
}
