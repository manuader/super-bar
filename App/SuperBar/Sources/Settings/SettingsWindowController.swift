import AppKit
import SwiftUI
import SuperBarKit

enum SettingsTab: Int, CaseIterable {
    case general, appearance, rules, scripts, about

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .rules: return "Rules"
        case .scripts: return "Scripts"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .rules: return "line.3.horizontal.decrease.circle"
        case .scripts: return "curlybraces"
        case .about: return "info.circle"
        }
    }
}

/// System Settings–style window: toolbar tabs hosting SwiftUI forms.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private unowned let app: AppDelegate
    private let tabs = NSTabViewController()

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "General"
        window.toolbarStyle = .preference
        super.init(window: window)
        window.delegate = self
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        for tab in SettingsTab.allCases {
            let host = NSHostingController(rootView: AnyView(pane(for: tab)))
            host.title = tab.title
            host.preferredContentSize = NSSize(width: 560, height: heightFor(tab))
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        window.center()
        updateLevel()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func heightFor(_ tab: SettingsTab) -> CGFloat {
        switch tab {
        case .general: return 720
        case .appearance: return 600
        case .rules: return 420
        case .scripts: return 440
        case .about: return 360
        }
    }

    @ViewBuilder
    private func pane(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView(app: app).environmentObject(app.preferences)
        case .appearance: AppearanceSettingsView().environmentObject(app.preferences)
        case .rules: RulesSettingsView(app: app).environmentObject(app.preferences)
        case .scripts: ScriptsSettingsView(app: app).environmentObject(app.preferences)
        case .about: AboutSettingsView()
        }
    }

    func show(tab: SettingsTab? = nil) {
        if let tab { tabs.selectedTabViewItemIndex = tab.rawValue }
        window?.title = SettingsTab(rawValue: tabs.selectedTabViewItemIndex)?.title ?? "Settings"
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateLevel() {
        window?.level = app.preferences.settingsWindowFloats ? .floating : .normal
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.title = SettingsTab(rawValue: tabs.selectedTabViewItemIndex)?.title ?? "Settings"
    }
}
