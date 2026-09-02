import AppKit
import SuperBarKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private unowned let app: AppDelegate
    private var item: NSStatusItem?

    init(app: AppDelegate) {
        self.app = app
        super.init()
    }

    var isVisible: Bool = false {
        didSet {
            if isVisible { install() } else { remove() }
        }
    }

    private func install() {
        guard item == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "filemenu.and.selection", accessibilityDescription: "SuperBar")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "SuperBar — \(app.preferences.hotKey.display)"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        item = statusItem
    }

    private func remove() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = NSMenuItem(title: "Open SuperBar", action: #selector(openPalette), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        if !app.menuSource.isTrusted {
            let grant = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(grantAccess), keyEquivalent: "")
            grant.target = self
            grant.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(grant)
        }
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let help = NSMenuItem(title: "Help", action: #selector(openHelp), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit SuperBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func openPalette() { app.palette.show() }
    @objc private func openSettings() { app.showSettings() }
    @objc private func grantAccess() { app.showPermissionWindow() }
    @objc private func openHelp() { NSWorkspace.shared.open(URL(string: "https://github.com/manuader/super-bar#readme")!) }
}
