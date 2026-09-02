import SwiftUI
import ServiceManagement
import SuperBarKit

struct GeneralSettingsView: View {
    @ObservedObject var app: AppDelegate
    @EnvironmentObject var prefs: Preferences
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var isTrusted = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                LabeledContent("Global shortcut") {
                    HStack {
                        ShortcutRecorder(hotKey: Binding(get: { prefs.hotKey }, set: { prefs.hotKey = $0 }), onRecordingChanged: { app.suspendHotKey($0) })
                        Toggle("Enabled", isOn: Binding(get: { prefs.hotKeyEnabled }, set: { prefs.hotKeyEnabled = $0 }))
                            .toggleStyle(.checkbox)
                    }
                }
                if let error = app.hotKeyRegistrationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                ExcludedAppsEditor()
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Click the field and press a key combination. The shortcut is ignored while one of the listed apps is in front.")
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in toggleLaunchAtLogin(on) }
                if let launchError { Text(launchError).font(.callout).foregroundStyle(.red) }
                Toggle("Show menu bar extra", isOn: Binding(get: { prefs.showMenuBarExtra }, set: { prefs.showMenuBarExtra = $0 }))
            }

            Section {
                Picker("Show on", selection: Binding(get: { prefs.preferredScreen }, set: { prefs.preferredScreen = $0 })) {
                    Text("Screen with the mouse").tag(PreferredScreen.withMouse)
                    Text("Screen with keyboard focus").tag(PreferredScreen.withKeyboardFocus)
                    Text("Main display").tag(PreferredScreen.main)
                }
                Toggle("Clear search state immediately", isOn: Binding(get: { prefs.clearSearchStateImmediately }, set: { prefs.clearSearchStateImmediately = $0 }))
                Toggle("Settings window floats above other windows", isOn: Binding(get: { prefs.settingsWindowFloats }, set: { prefs.settingsWindowFloats = $0 }))
            } header: {
                Text("Window")
            } footer: {
                Text("When search state is kept, SuperBar remembers your query, scope and expanded menus until you switch to another app.")
            }

            Section("Permissions") {
                LabeledContent("Accessibility") {
                    HStack {
                        Label(isTrusted ? "Granted" : "Not granted", systemImage: isTrusted ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(isTrusted ? Color.green : Color.red)
                        if !isTrusted {
                            Button("Open System Settings") {
                                _ = AXMenuSource.requestTrust()
                                NSWorkspace.shared.open(AXMenuSource.accessibilitySettingsURL)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { isTrusted = app.menuSource.isTrusted }
        .onReceive(timer) { _ in isTrusted = app.menuSource.isTrusted }
    }

    private func toggleLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Bundle identifiers where the global shortcut is disabled.
struct ExcludedAppsEditor: View {
    @EnvironmentObject var prefs: Preferences
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Disable the shortcut in:")
            List(selection: $selection) {
                ForEach(prefs.globalShortcutExcludedApps, id: \.self) { id in
                    HStack(spacing: 8) {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                            Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                        } else {
                            Image(systemName: "app.dashed").frame(width: 18, height: 18)
                            Text(id)
                        }
                    }
                    .tag(id)
                }
            }
            .frame(height: 110)
            .overlay {
                if prefs.globalShortcutExcludedApps.isEmpty {
                    Text("No apps").foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 0) {
                Button { addApp() } label: { Image(systemName: "plus") }
                Button { remove() } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        var ids = prefs.globalShortcutExcludedApps
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !ids.contains(id) { ids.append(id) }
        }
        prefs.globalShortcutExcludedApps = ids
    }

    private func remove() {
        guard let selection else { return }
        prefs.globalShortcutExcludedApps.removeAll { $0 == selection }
        self.selection = nil
    }
}
