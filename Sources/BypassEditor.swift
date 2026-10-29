import Cocoa

/// Modal form (NSAlert + text view) for editing the proxy ignore list.
enum BypassEditor {

    /// Returns the new list, or nil if cancelled.
    static func present(current: [String]) -> [String]? {
        let alert = NSAlert()
        alert.messageText = "代理忽略列表"
        alert.informativeText = """
            命中的地址不走上游代理，直接连接。同时作用于系统代理的「忽略这些主机与域的代理设置」和本地中转。
            每行一条，支持：域名（nas.home）、通配后缀（*.local）、IP 或网段（192.168.0.0/16、fd7a:115c:a1e0::/48）。
            """
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 32, width: 360, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let textView = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.string = current.joined(separator: "\n")
        scroll.documentView = textView

        let reset = ResetTarget(textView)
        let resetButton = NSButton(title: "恢复默认", target: reset, action: #selector(ResetTarget.reset))
        resetButton.bezelStyle = .rounded
        resetButton.sizeToFit()
        resetButton.setFrameOrigin(.zero)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 252))
        container.addSubview(scroll)
        container.addSubview(resetButton)
        alert.accessoryView = container
        alert.window.initialFirstResponder = textView

        let response = withExtendedLifetime(reset) { alert.runModal() }
        guard response == .alertFirstButtonReturn else { return nil }

        let entries = ProxyBypass.parseEntries(textView.string)
        let invalid = ProxyBypass.invalidEntries(entries)
        guard invalid.isEmpty else {
            let e = NSAlert()
            e.messageText = "无法识别的条目"
            e.informativeText = "请检查以下条目（网段前缀长度需在有效范围内）：\n" + invalid.joined(separator: "\n")
            e.runModal()
            return present(current: entries) // reopen with the user's input so it can be fixed
        }
        return entries
    }

    /// Target for the in-dialog "恢复默认" button (NSAlert buttons would close the dialog).
    private final class ResetTarget: NSObject {
        private let textView: NSTextView
        init(_ textView: NSTextView) { self.textView = textView }

        @objc func reset() {
            textView.string = ProxyBypass.defaults.joined(separator: "\n")
        }
    }
}
