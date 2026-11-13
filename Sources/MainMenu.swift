import Cocoa

/// A menu-bar-only (accessory) app shows no main menu, but AppKit still routes
/// key equivalents like ⌘C / ⌘V / ⌘W through `NSApp.mainMenu`. Without one,
/// those shortcuts do nothing in our windows and dialogs, so install a standard
/// (never visible) main menu whose items target the first responder.
enum MainMenu {
    static func install() {
        let main = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(item(L("Hide Switch Proxy"), "hide:", "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(item(L("Quit Switch Proxy"), "terminate:", "q"))
        main.addItem(submenu(appMenu, title: "Switch Proxy"))

        // File menu
        let fileMenu = NSMenu(title: L("File"))
        fileMenu.addItem(item(L("Close Window"), "performClose:", "w"))
        main.addItem(submenu(fileMenu, title: L("File")))

        // Edit menu
        let editMenu = NSMenu(title: L("Edit"))
        editMenu.addItem(item(L("Undo"), "undo:", "z"))
        editMenu.addItem(item(L("Redo"), "redo:", "z", [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(item(L("Cut"), "cut:", "x"))
        editMenu.addItem(item(L("Copy"), "copy:", "c"))
        editMenu.addItem(item(L("Paste"), "paste:", "v"))
        editMenu.addItem(item(L("Paste and Match Style"), "pasteAsPlainText:", "v", [.command, .option, .shift]))
        editMenu.addItem(item(L("Delete"), "delete:", ""))
        editMenu.addItem(item(L("Select All"), "selectAll:", "a"))
        main.addItem(submenu(editMenu, title: L("Edit")))

        // Window menu
        let windowMenu = NSMenu(title: L("Window"))
        windowMenu.addItem(item(L("Minimize"), "performMiniaturize:", "m"))
        windowMenu.addItem(item(L("Zoom"), "performZoom:", ""))
        main.addItem(submenu(windowMenu, title: L("Window")))

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    /// Item with a nil target, so the action goes to the first responder chain.
    private static func item(_ title: String, _ action: String, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
        mi.keyEquivalentModifierMask = modifiers
        return mi
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.submenu = menu
        return mi
    }
}
